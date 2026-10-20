import AppKit
import Combine
import Foundation
import ServiceManagement

/// Polls the registry, hook markers and transcripts off the main thread.
final class Worker: @unchecked Sendable {
    struct Snapshot {
        let agents: [Agent]
        let messages: [AgentMessage]
        let fromHistory: Bool
    }

    private let queue = DispatchQueue(label: "maitre-d-agent.poll", qos: .utility)
    private let repos = RepoResolver()
    private let transcripts = Transcripts()
    private var timer: DispatchSourceTimer?

    func start(deliver: @escaping (Snapshot) -> Void) {
        queue.async { [self] in
            let history = transcripts.loadHistory()
            deliver(poll(extra: history, fromHistory: true))
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [self] in deliver(poll(extra: [], fromHistory: false)) }
            timer.resume()
            self.timer = timer
        }
    }

    /// One synchronous snapshot including history, for `--dump`.
    func snapshotOnce() -> Snapshot {
        poll(extra: transcripts.loadHistory(), fromHistory: true)
    }

    private func poll(extra: [RawMessage], fromHistory: Bool) -> Snapshot {
        let entries = Registry.read()
        let markers = Markers.readAll()
        let liveIds = Set(entries.map(\.sessionId))

        // Drop markers left behind by sessions that ended without a SessionEnd hook.
        for (sessionId, marker) in markers where !liveIds.contains(sessionId) && Date().timeIntervalSince(marker.since) > 300 {
            Markers.remove(sessionId)
        }

        var usedKeys = Set<String>()
        var agents: [Agent] = []
        for entry in entries {
            let root = repos.root(for: entry.cwd)
            let name = entry.name ?? URL(fileURLWithPath: entry.cwd).lastPathComponent
            var key = "\(root)|\(name)"
            if !usedKeys.insert(key).inserted {
                key += "#\(entry.sessionId.prefix(8))"
                usedKeys.insert(key)
            }
            let status: AgentStatus
            var waitReason: WaitReason?
            var since = entry.statusUpdatedAt
            if let marker = markers[entry.sessionId] {
                status = .needsMe
                waitReason = marker.waitReason
                since = marker.since
            } else {
                switch entry.status {
                case "waiting": status = .needsMe; waitReason = .other(entry.waitingFor ?? "input needed")
                case "busy", "shell": status = .working
                default: status = .idle
                }
            }
            agents.append(Agent(
                sessionId: entry.sessionId, pid: entry.pid, key: key, name: name, cwd: entry.cwd,
                repoRoot: root, entrypoint: entry.entrypoint, status: status, waitReason: waitReason,
                reportedSince: since
            ))
        }

        let raw = extra + transcripts.poll(sessionIds: entries.map(\.sessionId))
        let liveNames = Dictionary(entries.map { ($0.sessionId, $0.name) }, uniquingKeysWith: { a, _ in a })
        let messages = raw.map { m in
            AgentMessage(
                id: m.id,
                fromSession: m.sessionId,
                fromName: liveNames[m.sessionId].flatMap { $0 } ?? transcripts.agentNames[m.sessionId] ?? "unknown",
                toName: Self.recipientName(m.to),
                summary: m.summary,
                text: m.text,
                date: m.date
            )
        }
        return Snapshot(agents: agents, messages: messages, fromHistory: fromHistory)
    }

    /// SendMessage targets look like "name" or "name [ref]".
    static func recipientName(_ to: String) -> String {
        let trimmed = to.trimmingCharacters(in: .whitespaces)
        if let bracket = trimmed.range(of: " [") { return String(trimmed[..<bracket.lowerBound]) }
        return trimmed
    }
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var agents: [Agent] = []
    @Published private(set) var messages: [AgentMessage] = [] // newest first
    @Published private(set) var sentCounts: [String: Int] = [:]
    @Published private(set) var receivedCounts: [String: Int] = [:]
    /// Agent name -> time of its last live SendMessage, drives the row pulse.
    @Published private(set) var pulses: [String: Date] = [:]
    @Published private(set) var now = Date()
    @Published private(set) var hooksInstalled = HookInstaller.isInstalled()
    @Published private(set) var lastError: String?
    @Published var editingGroupId: String?
    @Published var config: Config {
        didSet { if persists && config != oldValue { config.save() } }
    }

    var copy: Copy { config.pretentious ? .pretentious : .normal }

    var onNeedsMe: ((Agent) -> Void)?
    var onNoLongerNeedsMe: ((Agent) -> Void)?

    private let worker = Worker()
    private let persists: Bool
    private var loaded = false

    /// `persists: false` keeps the config in memory only (demo snapshots).
    init(config: Config = Config.load(), persists: Bool = true) {
        self.config = config
        self.persists = persists
    }
    private var clock: AnyCancellable?

    func start() {
        worker.start { snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.apply(snapshot) }
            }
        }
        clock = Timer.publish(every: 20, on: .main, in: .common).autoconnect().sink { [weak self] date in
            self?.now = date
        }
    }

    private func apply(_ snapshot: Worker.Snapshot) {
        let previous = Dictionary(agents.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        let next: [Agent] = snapshot.agents.map { agent in
            var agent = agent
            if let old = previous[agent.sessionId], old.status == agent.status {
                agent.since = old.since
            } else if previous[agent.sessionId] == nil {
                agent.since = agent.reportedSince ?? Date()
            } else {
                agent.since = Date()
            }
            return agent
        }

        if loaded {
            for agent in next {
                let old = previous[agent.sessionId]?.status
                if agent.status == .needsMe && old != .needsMe { onNeedsMe?(agent) }
                if old == .needsMe && agent.status != .needsMe { onNoLongerNeedsMe?(agent) }
            }
        }
        if next != agents { agents = next }

        if !snapshot.messages.isEmpty {
            let cutoff = Date().addingTimeInterval(-Transcripts.window)
            let known = Set(messages.map(\.id))
            let fresh = snapshot.messages.filter { !known.contains($0.id) }
            messages = (messages + fresh)
                .filter { $0.date >= cutoff }
                .sorted { $0.date > $1.date }
                .prefix(500)
                .map { $0 }
            recount()
            if !snapshot.fromHistory {
                for message in fresh { pulses[message.fromName] = Date() }
            }
        }
        if Date().timeIntervalSince(now) > 20 { now = Date() }
        loaded = true
    }

    private func recount() {
        var sent: [String: Int] = [:]
        var received: [String: Int] = [:]
        for message in messages {
            sent[message.fromName, default: 0] += 1
            received[message.toName, default: 0] += 1
        }
        sentCounts = sent
        receivedCounts = received
    }

    // MARK: - Derived

    var needsCount: Int { agents.filter { $0.status == .needsMe }.count }
    var workingCount: Int { agents.filter { $0.status == .working }.count }

    func isLead(_ agent: Agent) -> Bool { config.leads.contains(agent.key) }

    func groupTitle(_ id: String) -> String {
        groups.first { $0.id == id }?.title ?? id
    }

    var groups: [AgentGroup] {
        let config = self.config
        let customIds = Set(config.customGroups.map(\.id))
        var repoTitles: [String: String] = [:]
        for agent in agents {
            repoTitles["repo:\(agent.repoRoot)"] = URL(fileURLWithPath: agent.repoRoot).lastPathComponent
        }

        var buckets: [String: [Agent]] = [:]
        for agent in agents {
            var groupId = "repo:\(agent.repoRoot)"
            if let assigned = config.assignments[agent.key], customIds.contains(assigned) || repoTitles[assigned] != nil {
                groupId = assigned
            }
            buckets[groupId, default: []].append(agent)
        }

        func title(_ id: String) -> String {
            if let custom = config.customGroups.first(where: { $0.id == id }) { return custom.name }
            return config.groupNames[id] ?? repoTitles[id] ?? id
        }

        let groupIndex = Dictionary(config.groupOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = Set(buckets.keys).union(customIds).sorted { a, b in
            switch (groupIndex[a], groupIndex[b]) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return title(a).localizedStandardCompare(title(b)) == .orderedAscending
            }
        }

        let agentIndex = Dictionary(config.agentOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.map { id in
            let members = (buckets[id] ?? []).sorted { a, b in
                let leadA = config.leads.contains(a.key), leadB = config.leads.contains(b.key)
                if leadA != leadB { return leadA }
                switch (agentIndex[a.key], agentIndex[b.key]) {
                case let (x?, y?): return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            return AgentGroup(
                id: id,
                title: title(id),
                isCustom: customIds.contains(id),
                agents: members,
                hasLead: members.contains { config.leads.contains($0.key) }
            )
        }
    }

    // MARK: - Mutations

    func toggleLead(_ agent: Agent) {
        if config.leads.contains(agent.key) {
            config.leads.remove(agent.key)
        } else {
            config.leads.insert(agent.key)
        }
    }

    func toggleCollapsed(_ groupId: String) {
        if config.collapsed.contains(groupId) {
            config.collapsed.remove(groupId)
        } else {
            config.collapsed.insert(groupId)
        }
    }

    /// Handles a drop of "agent:<key>" or "group:<id>" payloads onto a row or group header.
    func handleDrop(_ items: [String], group: AgentGroup, before agent: Agent?) -> Bool {
        var handled = false
        for item in items {
            if item.hasPrefix("agent:") {
                let key = String(item.dropFirst(6))
                if key != agent?.key { moveAgent(key: key, to: group.id, before: agent?.key) }
                handled = true
            } else if item.hasPrefix("group:") {
                moveGroup(String(item.dropFirst(6)), before: group.id)
                handled = true
            }
        }
        return handled
    }

    func moveAgent(key: String, to groupId: String, before beforeKey: String?) {
        guard let agent = agents.first(where: { $0.key == key }) else { return }
        let current = groups
        let liveKeys = Set(agents.map(\.key))
        var order = current.flatMap { $0.agents.map(\.key) } + config.agentOrder.filter { !liveKeys.contains($0) }
        order.removeAll { $0 == key }

        if let beforeKey, let index = order.firstIndex(of: beforeKey) {
            order.insert(key, at: index)
        } else if let last = current.first(where: { $0.id == groupId })?.agents.last(where: { $0.key != key }),
                  let index = order.firstIndex(of: last.key) {
            order.insert(key, at: index + 1)
        } else {
            order.append(key)
        }

        var updated = config
        updated.agentOrder = order
        updated.assignments[key] = groupId == "repo:\(agent.repoRoot)" ? nil : groupId
        config = updated
    }

    func moveGroup(_ id: String, before targetId: String?) {
        guard id != targetId else { return }
        let currentIds = groups.map(\.id)
        var order = currentIds + config.groupOrder.filter { !currentIds.contains($0) }
        order.removeAll { $0 == id }
        if let targetId, let index = order.firstIndex(of: targetId) {
            order.insert(id, at: index)
        } else {
            order.append(id)
        }
        config.groupOrder = order
    }

    func shiftGroup(_ id: String, by delta: Int) {
        let ids = groups.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        var order = ids
        order.swapAt(index, target)
        config.groupOrder = order + config.groupOrder.filter { !ids.contains($0) }
    }

    func createGroup(with agent: Agent? = nil) {
        let id = "custom:\(UUID().uuidString)"
        var updated = config
        updated.customGroups.append(CustomGroup(id: id, name: copy.newGroupName))
        updated.groupOrder = groups.map(\.id) + [id]
        config = updated
        if let agent { moveAgent(key: agent.key, to: id, before: nil) }
        editingGroupId = id
    }

    func renameGroup(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = config.customGroups.firstIndex(where: { $0.id == id }) {
            if !trimmed.isEmpty { config.customGroups[index].name = trimmed }
        } else {
            config.groupNames[id] = trimmed.isEmpty ? nil : trimmed
        }
    }

    func deleteGroup(_ id: String) {
        var updated = config
        updated.customGroups.removeAll { $0.id == id }
        updated.assignments = updated.assignments.filter { $0.value != id }
        updated.groupOrder.removeAll { $0 == id }
        updated.collapsed.remove(id)
        config = updated
    }

    // MARK: - Actions

    func focus(_ agent: Agent) {
        VSCode.focus(agent, deepLink: config.deepLink)
    }

    func focus(sessionId: String) {
        if let agent = agents.first(where: { $0.sessionId == sessionId }) { focus(agent) }
    }

    func installHooks() {
        do {
            try HookInstaller.install()
            lastError = nil
        } catch {
            lastError = "Hook install failed: \(error.localizedDescription)"
        }
        hooksInstalled = HookInstaller.isInstalled()
    }

    func uninstallHooks() {
        do {
            try HookInstaller.uninstall()
            lastError = nil
        } catch {
            lastError = "Hook removal failed: \(error.localizedDescription)"
        }
        hooksInstalled = HookInstaller.isInstalled()
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                lastError = nil
            } catch {
                lastError = "Launch at login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}

// MARK: - Demo data for README screenshots (`--snapshot <file> --demo`)

extension Store {
    func loadDemo(pretentious: Bool) {
        func agent(_ repo: String, _ name: String, _ status: AgentStatus, _ minutes: Double, _ reason: WaitReason? = nil) -> Agent {
            var agent = Agent(
                sessionId: UUID().uuidString, pid: 0, key: "/demo/\(repo)|\(name)", name: name, cwd: "/demo/\(repo)",
                repoRoot: "/demo/\(repo)", entrypoint: "claude-vscode", status: status, waitReason: reason, reportedSince: nil
            )
            agent.since = Date().addingTimeInterval(-minutes * 60)
            return agent
        }
        agents = [
            agent("webshop", "shop-lead", .working, 1),
            agent("webshop", "checkout", .working, 4),
            agent("webshop", "search", .needsMe, 2, .permission(tool: "Bash")),
            agent("webshop", "design-system", .working, 0),
            agent("webshop", "payments", .idle, 38),
            agent("infra", "terraform", .working, 12),
            agent("infra", "ci-fixer", .idle, 95),
            agent("blog", "blog", .idle, 300),
            agent("dotfiles", "dotfiles", .working, 2),
        ]

        func message(_ minutes: Double, _ from: String, _ to: String, _ summary: String, _ text: String = "") -> AgentMessage {
            AgentMessage(id: UUID().uuidString, fromSession: "", fromName: from, toName: to, summary: summary,
                         text: text, date: Date().addingTimeInterval(-minutes * 60))
        }
        messages = [
            message(1, "checkout", "shop-lead", "Cart totals fixed, tests green"),
            message(3, "shop-lead", "search", "Please reindex after the schema change"),
            message(6, "design-system", "checkout", "New button tokens are in, pull main"),
            message(9, "shop-lead", "design-system", "Dark mode for the checkout flow?"),
            message(14, "terraform", "ci-fixer", "Staging is back, rerun the pipeline"),
            message(21, "shop-lead", "checkout", "Rounding bug in cart totals"),
        ]
        recount()
        hooksInstalled = true

        var config = Config()
        config.pretentious = pretentious
        config.feedExpanded = true
        config.leads = ["/demo/webshop|shop-lead"]
        config.customGroups = [CustomGroup(id: "custom:side", name: pretentious ? "Terrace" : "Side projects")]
        config.assignments = ["/demo/blog|blog": "custom:side", "/demo/dotfiles|dotfiles": "custom:side"]
        config.agentOrder = ["/demo/webshop|checkout", "/demo/webshop|search", "/demo/webshop|design-system"]
        config.groupOrder = ["repo:/demo/webshop", "repo:/demo/infra", "custom:side"]
        self.config = config
    }
}

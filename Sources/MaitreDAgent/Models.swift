import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let claude = home.appendingPathComponent(".claude")
    static let sessions = claude.appendingPathComponent("sessions")
    static let projects = claude.appendingPathComponent("projects")
    static let settings = claude.appendingPathComponent("settings.json")
    static let appDir = home.appendingPathComponent(".maitre-d-agent")
    static let state = appDir.appendingPathComponent("state")
    static let config = appDir.appendingPathComponent("config.json")
    static let hook = appDir.appendingPathComponent("hook.sh")
    static let flags = appDir.appendingPathComponent("flags")
    static let cli = appDir.appendingPathComponent("bin/maitre-d")
    static let skill = claude.appendingPathComponent("skills/maitre-d")
}

enum AgentStatus: Int, Comparable {
    case idle, working, needsMe

    static func < (lhs: AgentStatus, rhs: AgentStatus) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Why an agent is blocked on you.
enum WaitReason: Equatable {
    case permission(tool: String)
    case question
    case plan
    /// Free text from the session registry's `waitingFor`.
    case other(String)
}

struct Agent: Identifiable, Equatable {
    let sessionId: String
    let pid: Int32
    /// Stable identity across restarts: repo root + session name.
    let key: String
    let name: String
    let cwd: String
    let repoRoot: String
    let entrypoint: String?
    let status: AgentStatus
    let waitReason: WaitReason?
    /// Registry timestamp of the last status change, if known.
    let reportedSince: Date?
    let context: ContextUsage?
    /// Flags raised by this agent (for itself or for another agent), oldest first.
    let flags: [Flag]
    /// Remote Control is on, so the session can be followed from another device.
    var remoteControl = false
    /// Idle, but a background shell it started (a dev server, say) is still running.
    var backgroundShell = false
    var since: Date = .distantPast

    var id: String { key }
}

/// An agent asking for the human's attention via `maitre-d flag`.
/// Shown on the row of the agent that raised it; `subject` is who it's about.
struct Flag: Codable, Identifiable, Equatable {
    let id: String
    let raisedBySession: String
    let raisedByName: String
    let subjectSession: String
    let subjectName: String
    let message: String
    let createdAt: Date

    var isSelf: Bool { subjectSession == raisedBySession }
}

/// How full a session's context window is, from its latest API response.
struct ContextUsage: Equatable {
    let tokens: Int
    let window: Int

    var fraction: Double { min(1, Double(tokens) / Double(window)) }
    var percent: Int { Int((fraction * 100).rounded()) }

    /// Claude Code doesn't record the window size in the transcript, so infer it:
    /// a `[1m]` model, a model family known to default to 1M, or usage already past 200k.
    static func window(model: String, peakTokens: Int) -> Int {
        let model = model.lowercased()
        let oneMillion = ["claude-opus-5", "claude-fable-5", "claude-sonnet-5", "claude-mythos", "claude-opus-4-7", "claude-opus-4-8"]
        if model.contains("[1m]") || oneMillion.contains(where: model.hasPrefix) || peakTokens > 200_000 {
            return 1_000_000
        }
        return 200_000
    }
}

func shortTokens(_ tokens: Int) -> String {
    if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
    if tokens >= 1000 { return "\(tokens / 1000)k" }
    return "\(tokens)"
}

struct AgentMessage: Identifiable, Equatable {
    let id: String
    let fromSession: String
    let fromName: String
    let toName: String
    let summary: String
    let text: String
    let date: Date
}

struct AgentGroup: Identifiable {
    let id: String
    let title: String
    let isCustom: Bool
    let agents: [Agent]
    let hasLead: Bool

    var needsCount: Int { agents.filter { $0.status == .needsMe }.count }
    var workingCount: Int { agents.filter { $0.status == .working }.count }
}

struct CustomGroup: Codable, Identifiable, Equatable {
    var id: String
    var name: String
}

struct Config: Codable, Equatable {
    var leads: Set<String> = []
    var agentOrder: [String] = []
    var groupOrder: [String] = []
    /// agent key -> group id, only when it differs from the agent's repo group.
    var assignments: [String: String] = [:]
    var customGroups: [CustomGroup] = []
    /// Display names for repo groups.
    var groupNames: [String: String] = [:]
    var collapsed: Set<String> = []
    var notifications = true
    var deepLink = true
    var pinned = false
    var pinnedFrame: String?
    var feedExpanded = false
    var pretentious = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        leads = try c.decodeIfPresent(Set<String>.self, forKey: .leads) ?? d.leads
        agentOrder = try c.decodeIfPresent([String].self, forKey: .agentOrder) ?? d.agentOrder
        groupOrder = try c.decodeIfPresent([String].self, forKey: .groupOrder) ?? d.groupOrder
        assignments = try c.decodeIfPresent([String: String].self, forKey: .assignments) ?? d.assignments
        customGroups = try c.decodeIfPresent([CustomGroup].self, forKey: .customGroups) ?? d.customGroups
        groupNames = try c.decodeIfPresent([String: String].self, forKey: .groupNames) ?? d.groupNames
        collapsed = try c.decodeIfPresent(Set<String>.self, forKey: .collapsed) ?? d.collapsed
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? d.notifications
        deepLink = try c.decodeIfPresent(Bool.self, forKey: .deepLink) ?? d.deepLink
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? d.pinned
        pinnedFrame = try c.decodeIfPresent(String.self, forKey: .pinnedFrame)
        feedExpanded = try c.decodeIfPresent(Bool.self, forKey: .feedExpanded) ?? d.feedExpanded
        pretentious = try c.decodeIfPresent(Bool.self, forKey: .pretentious) ?? d.pretentious
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.config),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return config
    }

    func save() {
        try? FileManager.default.createDirectory(at: Paths.appDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Paths.config, options: .atomic)
    }
}

/// "just now" or "5m ago".
func ago(_ date: Date) -> String {
    let duration = shortDuration(Date().timeIntervalSince(date))
    return duration == "now" ? "just now" : "\(duration) ago"
}

func shortDuration(_ interval: TimeInterval) -> String {
    let s = max(0, Int(interval))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

import Foundation

/// Every user-facing string, in plain and pretentious wording.
/// Pretentious mode: a French maître d' watching over a restaurant where every patron is named Claude.
struct Copy {
    let pretentious: Bool

    static let normal = Copy(pretentious: false)
    static let pretentious = Copy(pretentious: true)

    static let appName = "Maître d'Agént"

    // MARK: Status

    func status(_ status: AgentStatus) -> String {
        switch (status, pretentious) {
        case (.needsMe, false): return "needs you"
        case (.working, false): return "working"
        case (.idle, false): return "idle"
        case (.needsMe, true): return "waving"
        case (.working, true): return "dining"
        case (.idle, true): return "digesting"
        }
    }

    func reason(_ reason: WaitReason) -> String {
        switch reason {
        case .permission(let tool):
            if pretentious { return tool.isEmpty ? "would like to order" : "would like to order \(tool)" }
            return tool.isEmpty ? "permission" : "permission: \(tool)"
        case .question:
            return pretentious ? "has a question for the chef" : "question"
        case .plan:
            return pretentious ? "requests approval of the menu" : "plan approval"
        case .other(let text):
            return text
        }
    }

    // MARK: Panel

    var panelTitle: String { pretentious ? "Ce soir" : "Agents" }
    var emptyState: String { pretentious ? "The restaurant is empty. No Claudes tonight." : "No Claude sessions running" }
    func needsCountHelp(_ count: Int) -> String { pretentious ? "\(count) waving" : "\(count) need you" }
    func workingCountHelp(_ count: Int) -> String { pretentious ? "\(count) dining" : "\(count) working" }
    var hooksMissing: String {
        pretentious
            ? "The maître d' cannot see anyone waving. Install hooks."
            : "Claude hooks not installed, so permission prompts won't show as “needs you”."
    }

    // MARK: Groups and agents

    var newGroupName: String { pretentious ? "New table" : "New group" }
    var newGroup: String { pretentious ? "New Table" : "New Group" }
    var newGroupEllipsis: String { newGroup + "…" }
    var deleteGroup: String { pretentious ? "Clear Table" : "Delete Group" }
    var dropHere: String { pretentious ? "Seat Claudes here" : "Drag agents here" }
    func leadToggle(isLead: Bool) -> String {
        switch (isLead, pretentious) {
        case (false, false): return "Mark as Lead"
        case (true, false): return "Unmark as Lead"
        case (false, true): return "Seat at Head of Table"
        case (true, true): return "Leave Head of Table"
        }
    }
    var moveToGroup: String { pretentious ? "Move to Table" : "Move to Group" }

    // MARK: Context window

    func contextHelp(_ usage: ContextUsage) -> String {
        let amounts = "\(shortTokens(usage.tokens)) of \(shortTokens(usage.window)) tokens"
        return pretentious ? "\(usage.percent)% full. \(amounts)" : "Context: \(usage.percent)% · \(amounts)"
    }

    // MARK: Messages

    var messagesTitle: String { pretentious ? "Notes between tables" : "Messages" }
    var messagesWindow: String { pretentious ? "tonight" : "last 24h" }
    var noMessages: String { pretentious ? "No notes passed yet" : "No agent-to-agent messages yet" }
    func badgeHelp(sent: Int, received: Int) -> String {
        pretentious
            ? "Notes tonight: \(sent) sent, \(received) received"
            : "Messages in the last 24h: \(sent) sent, \(received) received"
    }

    // MARK: Menu bar, notifications, quit

    func menuBarHelp(needs: Int, working: Int, total: Int) -> String {
        pretentious
            ? "\(needs) Claudes waving · \(working) dining · \(total) seated"
            : "\(needs) need you · \(working) working · \(total) agents"
    }

    func notificationTitle(agent: String, group: String) -> String {
        pretentious ? "Claude at table \(group) is waving" : "\(agent) needs you"
    }

    func notificationBody(agent: String, reason: WaitReason?, group: String) -> String {
        if pretentious {
            return reason.map { "\(agent) \(self.reason($0))" } ?? "\(agent) would like your attention"
        }
        return [reason.map { self.reason($0) }, group].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var quit: String { pretentious ? "Close the Restaurant" : "Quit \(Copy.appName)" }
}

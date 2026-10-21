import AppKit
import UserNotifications

/// Brings the window (and tab, where possible) of a session to the front.
enum SessionFocus {
    enum Host: Equatable {
        case vsCodeExtension
        case terminal(tty: String)
        case app(NSRunningApplication)
        case unknown
    }

    static func focus(_ agent: Agent, deepLink: Bool) {
        switch host(of: agent) {
        case .vsCodeExtension, .unknown:
            VSCode.focus(agent, deepLink: deepLink)
        case .terminal(let tty):
            if !Terminal.focusTab(tty: tty) { Terminal.activate() }
        case .app(let app):
            if app.bundleIdentifier?.hasPrefix(VSCode.bundleId) == true {
                // Claude running in VS Code's integrated terminal: the window, not the tab.
                VSCode.focus(agent, deepLink: false)
            } else {
                app.activate()
            }
        }
    }

    /// The nearest ancestor that's a regular app tells where the session runs.
    static func host(of agent: Agent) -> Host {
        if agent.entrypoint == "claude-vscode" { return .vsCodeExtension }
        for pid in Processes.ancestry(of: agent.pid).dropFirst() {
            guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil else { continue }
            if app.bundleIdentifier == Terminal.bundleId, let tty = Processes.tty(of: agent.pid) {
                return .terminal(tty: tty)
            }
            return .app(app)
        }
        return .unknown
    }

    static func describe(_ agent: Agent) -> String {
        switch host(of: agent) {
        case .vsCodeExtension: return "vscode"
        case .terminal(let tty): return "Terminal \(tty)"
        case .app(let app): return app.localizedName ?? app.bundleIdentifier ?? "app"
        case .unknown: return "unknown"
        }
    }
}

enum Terminal {
    static let bundleId = "com.apple.Terminal"

    /// Selects the Terminal tab whose tty matches and raises its window. Needs Automation permission,
    /// which macOS asks for on first use. Returns false if no tab matched or the script failed.
    static func focusTab(tty: String) -> Bool {
        guard tty.range(of: #"^/dev/ttys\d+$"#, options: .regularExpression) != nil else { return false }
        let source = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set miniaturized of w to false
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
            return false
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }

    static func activate() {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate()
    }
}

enum VSCode {
    static let bundleId = "com.microsoft.VSCode"
    private static let storage = Paths.home
        .appendingPathComponent("Library/Application Support/Code/User/globalStorage/storage.json")

    /// Brings the VS Code window for the agent's folder to the front and, when that
    /// folder is already open, asks the Claude extension to reveal the session's tab.
    static func focus(_ agent: Agent, deepLink: Bool) {
        let folder = URL(fileURLWithPath: agent.cwd)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            return
        }
        // Only deep link into a window that already has this folder open; otherwise the
        // extension would start a second copy of the session in whichever window is active.
        let canDeepLink = deepLink && agent.entrypoint == "claude-vscode" && openFolders().contains(folder.standardizedFileURL.path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration) { _, _ in
            guard canDeepLink else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                var components = URLComponents()
                components.scheme = "vscode"
                components.host = "anthropic.claude-code"
                components.path = "/open"
                components.queryItems = [URLQueryItem(name: "session", value: agent.sessionId)]
                if let url = components.url { NSWorkspace.shared.open(url) }
            }
        }
    }

    /// Folders of currently open VS Code windows, from VS Code's window state.
    static func openFolders() -> Set<String> {
        guard let data = try? Data(contentsOf: storage),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = obj["windowsState"] as? [String: Any] else { return [] }
        var windows = state["openedWindows"] as? [[String: Any]] ?? []
        if let last = state["lastActiveWindow"] as? [String: Any] { windows.append(last) }
        return Set(windows.compactMap { ($0["folder"] as? String).flatMap(URL.init(string:))?.standardizedFileURL.path })
    }
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onClick: ((String) -> Void)?

    /// UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setup() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ agent: Agent, group: String, copy: Copy) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = copy.notificationTitle(agent: agent.name, group: group)
        content.body = copy.notificationBody(agent: agent.name, reason: agent.waitReason, group: group)
        content.sound = .default
        content.userInfo = ["sessionId": agent.sessionId]
        center.add(UNNotificationRequest(identifier: identifier(agent), content: content, trigger: nil))
    }

    func post(id: String, title: String, body: String, sessionId: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func clear(_ agent: Agent) {
        clear(id: identifier(agent))
    }

    func clear(id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [id])
    }

    private func identifier(_ agent: Agent) -> String { "needs-\(agent.sessionId)" }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let sessionId { self.onClick?(sessionId) }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

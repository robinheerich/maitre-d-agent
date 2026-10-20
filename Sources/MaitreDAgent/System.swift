import AppKit
import UserNotifications

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

    func clear(_ agent: Agent) {
        center?.removeDeliveredNotifications(withIdentifiers: [identifier(agent)])
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

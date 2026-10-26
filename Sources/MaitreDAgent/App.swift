import AppKit
import Combine
import SwiftUI

@main
enum Main {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count > 1, CLI.commands.contains(arguments[1]) {
            exit(CLI.run(arguments))
        }
        if arguments.contains("--install-hooks") || arguments.contains("--uninstall-hooks") {
            do {
                if arguments.contains("--install-hooks") {
                    try HookInstaller.install()
                    print("Maître d'Agént hooks installed in \(Paths.settings.path)")
                } else {
                    try HookInstaller.uninstall()
                    print("Maître d'Agént hooks removed from \(Paths.settings.path)")
                }
                exit(0)
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if arguments.contains("--dump") {
            let snapshot = Worker().snapshotOnce()
            for agent in snapshot.agents {
                print("\(Copy.normal.status(agent.status).padding(toLength: 10, withPad: " ", startingAt: 0)) \(agent.name)  [\(agent.repoRoot)]\(agent.waitReason.map { "  (\(Copy.normal.reason($0)))" } ?? "")\(agent.context.map { "  ctx \($0.percent)% \(shortTokens($0.tokens))/\(shortTokens($0.window))" } ?? "")\(agent.flags.map { "  flag: \(Copy.normal.flagLine($0))" }.joined())  host: \(SessionFocus.describe(agent))\(agent.remoteControl ? "  remote-control" : "")")
            }
            print("\(snapshot.messages.count) messages in the last 24h")
            for message in snapshot.messages.sorted(by: { $0.date > $1.date }).prefix(10) {
                print("  \(message.date)  \(message.fromName) -> \(message.toName): \(message.summary)")
            }
            exit(0)
        }

        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            renderSnapshot(
                to: URL(fileURLWithPath: arguments[index + 1]),
                dark: arguments.contains("--dark"),
                demo: arguments.contains("--demo"),
                pretentious: arguments.contains("--pretentious")
            )
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Debug aid: renders the panel offscreen to a PNG once live data has loaded.
@MainActor
private func renderSnapshot(to url: URL, dark: Bool, demo: Bool, pretentious: Bool) {
    _ = NSApplication.shared
    let store: Store
    if demo {
        store = Store(config: Config(), persists: false)
        store.loadDemo(pretentious: pretentious)
    } else {
        store = Store()
        store.start()
    }
    let window = NSWindow(contentRect: NSRect(x: -2000, y: 0, width: 360, height: demo ? 690 : 680), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = NSHostingView(rootView: PanelView().environmentObject(store))
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let notifier = Notifier()
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        HookInstaller.writeScript()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.grid.2x2", accessibilityDescription: Copy.appName)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePanel)
        }
        panel = PanelController(store: store, statusItem: statusItem)

        store.$agents
            .combineLatest(store.$config.map(\.pretentious).removeDuplicates())
            .sink { [weak self] agents, _ in self?.updateStatusItem(agents) }
            .store(in: &subscriptions)

        notifier.setup()
        notifier.onClick = { [weak self] sessionId in self?.store.focus(sessionId: sessionId) }
        store.onNeedsMe = { [weak self] agent in
            guard let self, self.store.config.notifications else { return }
            let group = self.store.groups.first { $0.agents.contains { $0.key == agent.key } }?.title ?? ""
            self.notifier.post(agent, group: group, copy: self.store.copy)
        }
        store.onNoLongerNeedsMe = { [weak self] agent in self?.notifier.clear(agent) }
        store.onFlag = { [weak self] flag, agent in
            guard let self, self.store.config.notifications else { return }
            let group = self.store.groups.first { $0.agents.contains { $0.key == agent.key } }?.title ?? ""
            self.notifier.post(
                id: "flag-\(flag.id)",
                title: self.store.copy.flagNotificationTitle(flag, group: group),
                body: self.store.copy.flagNotificationBody(flag),
                sessionId: agent.sessionId
            )
        }
        store.onFlagCleared = { [weak self] flag in self?.notifier.clear(id: "flag-\(flag.id)") }

        store.start()
        panel.showPinnedIfNeeded()
    }

    @objc private func togglePanel() {
        panel.toggle()
    }

    private func updateStatusItem(_ agents: [Agent]) {
        let needs = agents.filter { $0.status == .needsMe }.count
        let working = agents.filter { $0.status == .working }.count
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let title = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor) {
            title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        if needs > 0 { add(" \(needs)", .systemOrange) }
        if working > 0 { add(needs > 0 ? "  ◐ \(working)" : " ◐ \(working)", .labelColor) }
        statusItem.button?.attributedTitle = title
        statusItem.button?.toolTip = store.copy.menuBarHelp(needs: needs, working: working, total: agents.count)
        statusItem.button?.image = NSImage(
            systemSymbolName: needs > 0 ? "exclamationmark.circle.fill" : "circle.grid.2x2",
            accessibilityDescription: Copy.appName
        )
    }
}

final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The agent list: a drop-down under the menu bar icon, or a pinned panel floating on top.
/// The pinned panel stays on the desktop (Space) it was pinned on. On every other desktop the
/// menu bar icon opens the drop-down there, so it never switches you to another desktop.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let dropDown: FloatingPanel
    private let pinnedPanel: FloatingPanel
    private let store: Store
    private weak var statusItem: NSStatusItem?
    private var lastHidden = Date.distantPast
    private var subscriptions = Set<AnyCancellable>()

    init(store: Store, statusItem: NSStatusItem) {
        self.store = store
        self.statusItem = statusItem
        dropDown = Self.makePanel(store: store, behavior: [.canJoinAllSpaces, .fullScreenAuxiliary])
        pinnedPanel = Self.makePanel(store: store, behavior: [.fullScreenAuxiliary])
        super.init()

        for panel in [dropDown, pinnedPanel] { panel.delegate = self }
        dropDown.onCancel = { [weak self] in self?.hideDropDown() }

        store.$config
            .map(\.pinned)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] pinned in self?.pinnedChanged(pinned) }
            .store(in: &subscriptions)
    }

    private static func makePanel(store: Store, behavior: NSWindow.CollectionBehavior) -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.titled, .fullSizeContentView, .resizable, .closable],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = behavior
        panel.minSize = NSSize(width: 280, height: 220)
        panel.contentView = NSHostingView(rootView: PanelView().environmentObject(store))
        return panel
    }

    /// Menu bar icon click.
    func toggle() {
        if store.config.pinned, !pinnedPanel.isVisible || pinnedPanel.isOnActiveSpace {
            // The pinned panel is hidden or on this desktop: show or hide it.
            pinnedPanel.isVisible ? pinnedPanel.orderOut(nil) : showPinned()
        } else if dropDown.isVisible {
            hideDropDown()
        } else if Date().timeIntervalSince(lastHidden) > 0.3 {
            // The click on the status item already hid the drop-down via resignKey.
            showDropDown()
        }
    }

    /// At launch: the pinned panel opens on the current desktop.
    func showPinnedIfNeeded() {
        if store.config.pinned { showPinned() }
    }

    private func showPinned() {
        if let saved = store.config.pinnedFrame {
            pinnedPanel.setFrame(NSRectFromString(saved), display: false)
        }
        bringForward(pinnedPanel)
    }

    private func showDropDown() {
        positionBelowStatusItem()
        bringForward(dropDown)
    }

    private func bringForward(_ panel: NSPanel) {
        // Order in before activating, so activation finds a window on this desktop and doesn't switch.
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    private func hideDropDown() {
        dropDown.orderOut(nil)
        lastHidden = Date()
    }

    private func positionBelowStatusItem() {
        guard let buttonWindow = statusItem?.button?.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.frame
        let size = dropDown.frame.size
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        dropDown.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.minY - 6))
    }

    private func pinnedChanged(_ pinned: Bool) {
        if pinned {
            // Pinned from the drop-down: the pinned panel takes its place, on this desktop.
            pinnedPanel.setFrame(dropDown.frame, display: false)
            store.config.pinnedFrame = NSStringFromRect(dropDown.frame)
            dropDown.orderOut(nil)
            bringForward(pinnedPanel)
        } else {
            let wasHere = pinnedPanel.isVisible && pinnedPanel.isOnActiveSpace
            pinnedPanel.orderOut(nil)
            if wasHere { showDropDown() }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === dropDown, dropDown.attachedSheet == nil else { return }
        hideDropDown()
    }

    func windowDidMove(_ notification: Notification) { savePinnedFrame(notification) }
    func windowDidEndLiveResize(_ notification: Notification) { savePinnedFrame(notification) }

    private func savePinnedFrame(_ notification: Notification) {
        guard notification.object as? NSWindow === pinnedPanel, store.config.pinned, pinnedPanel.isVisible else { return }
        store.config.pinnedFrame = NSStringFromRect(pinnedPanel.frame)
    }
}

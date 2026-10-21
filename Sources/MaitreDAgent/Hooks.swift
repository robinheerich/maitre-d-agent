import Foundation

/// Installs a small shell hook into ~/.claude/settings.json that records when a
/// session is blocked on the user (permission prompt, question, plan approval).
enum HookInstaller {
    static let script = #"""
    #!/bin/sh
    # Maitre d'Agent hook: records whether a Claude session is blocked on you.
    # Writes/clears ~/.maitre-d-agent/state/<session_id>.json. Installed by Maitre d'Agent.
    dir="$HOME/.maitre-d-agent/state"
    # Fast path for PostToolUse ("post"): nothing to clear when no session is blocked.
    if [ "$1" = "post" ] && ! ls "$dir"/*.json >/dev/null 2>&1; then cat >/dev/null; exit 0; fi
    input=$(cat | tr -d '\n\r')
    field() {
      printf '%s' "$input" | grep -o "\"$1\" *: *\"[^\"]*\"" | head -n 1 | sed 's/^.*: *"//; s/"$//'
    }
    sid=$(field session_id)
    case "$sid" in ''|*[!A-Za-z0-9_-]*) exit 0 ;; esac
    marker="$dir/$sid.json"
    event=$(field hook_event_name)
    tool=$(field tool_name)

    set_marker() {
      [ -f "$marker" ] && return
      mkdir -p "$dir"
      printf '{"reason":"%s","tool":"%s","since":%s}\n' "$1" "$2" "$(date +%s)" > "$marker.tmp" && mv -f "$marker.tmp" "$marker"
    }

    case "$event" in
      PermissionRequest) set_marker permission "$tool" ;;
      Notification)
        case "$(field notification_type)" in
          elicitation_dialog) set_marker question "" ;;
        esac ;;
      PreToolUse)
        case "$tool" in
          AskUserQuestion) set_marker question "$tool" ;;
          ExitPlanMode) set_marker plan "$tool" ;;
        esac ;;
      PostToolUse|PostToolUseFailure)
        if [ -f "$marker" ]; then
          waiting_on=$(sed -n 's/.*"tool":"\([^"]*\)".*/\1/p' "$marker")
          if [ -z "$waiting_on" ] || [ "$waiting_on" = "$tool" ]; then rm -f "$marker"; fi
        fi ;;
      UserPromptSubmit|Stop|SessionEnd) rm -f "$marker" ;;
    esac
    exit 0
    """#

    /// Teaches Claude sessions when and how to flag the human. Installed as a user-level skill.
    static let skill = #"""
    ---
    name: maitre-d
    description: Flag the human in the Maître d'Agént menu-bar app when you need their decision, approval or input, or (as a lead) when another agent does. Use when you are blocked on the human or need a human call; not for progress updates.
    ---

    # Flag the human (Maître d'Agént)

    The human watches all their Claude Code sessions in the Maître d'Agént menu-bar app. A flag turns your row orange with your message and sends them a notification, even when they aren't looking at your session.

    ```sh
    ~/.maitre-d-agent/bin/maitre-d flag "<what you need, in one line>"
    ~/.maitre-d-agent/bin/maitre-d flag --agent <session-name> "<what that agent needs>"
    ~/.maitre-d-agent/bin/maitre-d unflag [--agent <session-name>]
    ~/.maitre-d-agent/bin/maitre-d flags
    ```

    ## When to flag

    - A decision only the human can make, and work is waiting on it.
    - Approval before something irreversible or outward-facing (deleting data, deploying, sending things to people).
    - You're blocked on human input and they may not be watching your session.
    - As a lead: another agent needs the human's approval or decision. Use `--agent` with its session name (the same names SendMessage uses). The flag shows on **your** row, so the human comes to you, the lead.

    ## When not to

    - Routine progress or "done" reports. Put those in your reply.
    - Questions for other agents. Use SendMessage.
    - Permission prompts and questions you ask the human directly already show in the app on their own.

    ## Writing the message

    One line, at most about 120 characters, starting with what you need:
    `Approve: drop the legacy orders table` or `Decide: ship the feed schema as v1 or wait for review?`
    Put details in your conversation, not in the flag.

    The flag clears when the human next prompts you or the agent it's about, when they dismiss it in the app, or when you run `unflag`. Run `unflag` yourself if the need goes away. If the command fails (not inside a Claude Code session, app not installed), tell the human in your reply instead.
    """#

    /// (event, matcher); nil matcher for events that don't take one.
    private static let events: [(String, String?)] = [
        ("PermissionRequest", ""),
        ("Notification", ""),
        ("PreToolUse", "AskUserQuestion|ExitPlanMode"),
        ("PostToolUse", ""),
        ("PostToolUseFailure", ""),
        ("UserPromptSubmit", nil),
        ("Stop", nil),
        ("SessionEnd", nil),
    ]

    private static let marker = ".maitre-d-agent/hook.sh"

    static var command: String { "/bin/sh \"\(Paths.hook.path)\"" }

    /// Lets agents run the flag command without a permission prompt.
    private static var permissionRules: [String] {
        ["Bash(~/.maitre-d-agent/bin/maitre-d *)", "Bash(\(Paths.cli.path) *)"]
    }

    static func writeScript() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.state, withIntermediateDirectories: true)
        try? script.write(to: Paths.hook, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.hook.path)
        writeCLI()
    }

    /// ~/.maitre-d-agent/bin/maitre-d forwards to the installed app's executable.
    /// Only written from an app bundle, so a debug build never points it at .build/.
    private static func writeCLI() {
        guard Bundle.main.bundlePath.hasSuffix(".app"), let executable = Bundle.main.executablePath else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wrapper = "#!/bin/sh\n# Maitre d'Agent flag command; see `maitre-d help`.\nexec \"\(executable)\" \"$@\"\n"
        try? wrapper.write(to: Paths.cli, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.cli.path)
    }

    static func isInstalled() -> Bool {
        guard let text = try? String(contentsOf: Paths.settings, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    static func install() throws {
        writeScript()
        var settings = try loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        hooks = strip(hooks) { $0.contains(marker) }
        for (event, matcher) in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let isPost = event.hasPrefix("PostToolUse")
            var group: [String: Any] = ["hooks": [["type": "command", "command": isPost ? "\(command) post" : command, "timeout": 5]]]
            if let matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = (permissions["allow"] as? [String] ?? []).filter { !permissionRules.contains($0) }
        allow += permissionRules
        permissions["allow"] = allow
        settings["permissions"] = permissions
        try saveSettings(settings)

        let fm = FileManager.default
        try fm.createDirectory(at: Paths.skill, withIntermediateDirectories: true)
        try skill.write(to: Paths.skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    static func uninstall() throws {
        var settings = try loadSettings()
        let hooks = strip(settings["hooks"] as? [String: Any] ?? [:]) { $0.contains(marker) }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        if var permissions = settings["permissions"] as? [String: Any] {
            let allow = (permissions["allow"] as? [String] ?? []).filter { !permissionRules.contains($0) }
            permissions["allow"] = allow.isEmpty ? nil : allow
            settings["permissions"] = permissions.isEmpty ? nil : permissions
        }
        try saveSettings(settings)
        try? FileManager.default.removeItem(at: Paths.skill)
    }

    private static func strip(_ hooks: [String: Any], where matches: (String) -> Bool) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { result[event] = value; continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = entries.filter { !matches($0["command"] as? String ?? "") }
                if remaining.isEmpty { return nil }
                var copy = group
                copy["hooks"] = remaining
                return copy
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: Paths.settings.path) else { return [:] }
        let data = try Data(contentsOf: Paths.settings)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "MaitreDAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "settings.json is not a JSON object"])
        }
        return obj
    }

    private static func saveSettings(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: Paths.settings.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = Paths.claude.appendingPathComponent("settings.json.maitre-d-agent-backup-\(stamp)")
            try fm.copyItem(at: Paths.settings, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: Paths.settings, options: .atomic)
    }
}

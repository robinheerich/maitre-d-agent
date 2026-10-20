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

    static func writeScript() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.state, withIntermediateDirectories: true)
        try? script.write(to: Paths.hook, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.hook.path)
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
        try saveSettings(settings)
    }

    static func uninstall() throws {
        var settings = try loadSettings()
        let hooks = strip(settings["hooks"] as? [String: Any] ?? [:]) { $0.contains(marker) }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try saveSettings(settings)
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

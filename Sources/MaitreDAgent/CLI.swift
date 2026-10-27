import Darwin
import Foundation

/// `maitre-d flag | unflag | flags`: lets a Claude session ask for the human's attention.
/// Run by agents through ~/.maitre-d-agent/bin/maitre-d; prints its result for the agent to read.
/// Other tools can integrate through `--ref`, `unflag --id/--ref` and the flag files (see README).
enum CLI {
    static let commands: Set<String> = ["flag", "unflag", "flags", "help", "--help", "-h"]
    private static let maxMessage = 300

    static let usage = """
    Usage:
      maitre-d flag [--agent <name>] [--ref <ref>] <message>
          Ask the human for attention. With --agent, the flag is about another agent (by session
          name) but shows on your row. --ref attaches an opaque reference for other tools; a flag
          with a ref stays open after its sessions end.
      maitre-d unflag [--agent <name>]     Clear flags you raised or that are about you.
      maitre-d unflag --id <id> | --ref <ref>
          Clear flags by ID or ref. Works outside a Claude session; --id can repeat.
      maitre-d flags [--json]              List open flags.
    Flags also clear when the human prompts the raising or flagged agent, or dismisses them in the app.
    """

    private struct Options {
        var agent: String?
        var ref: String?
        var ids: [String] = []
        var json = false
        var words: [String] = []
    }

    static func run(_ arguments: [String]) -> Int32 {
        var args = Array(arguments.dropFirst())
        let command = args.isEmpty ? "help" : args.removeFirst()
        var options = Options()
        var index = 0
        while index < args.count {
            let arg = args[index]
            if ["--agent", "--ref", "--id"].contains(arg) {
                guard index + 1 < args.count else { return fail("\(arg) needs a value") }
                let value = args[index + 1]
                switch arg {
                case "--agent": options.agent = value
                case "--ref": options.ref = value
                default: options.ids.append(value)
                }
                index += 2
                continue
            }
            if arg == "--json" { options.json = true } else { options.words.append(arg) }
            index += 1
        }

        switch command {
        case "flag": return flag(message: options.words.joined(separator: " "), options: options)
        case "unflag": return unflag(options)
        case "flags": return list(json: options.json)
        case "help", "--help", "-h":
            print(usage)
            return 0
        default:
            return fail("unknown command \"\(command)\"\n\n\(usage)")
        }
    }

    private static func flag(message raw: String, options: Options) -> Int32 {
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return fail("missing message\n\n\(usage)") }
        guard let me = currentSession() else {
            return fail("not running inside a Claude Code session, so there's no agent to flag. Tell the human directly instead.")
        }
        var subject = me
        if let agentName = options.agent {
            switch resolve(agentName, near: me) {
            case .success(let entry): subject = entry
            case .failure(let error): return fail(error.message)
            }
        }
        let flag = Flag(
            id: UUID().uuidString,
            raisedBySession: me.sessionId,
            raisedByName: displayName(me),
            subjectSession: subject.sessionId,
            subjectName: displayName(subject),
            message: message.count > maxMessage ? String(message.prefix(maxMessage - 1)) + "…" : message,
            createdAt: Date(),
            ref: options.ref
        )
        do {
            try Flags.write(flag)
        } catch {
            return fail("could not write the flag: \(error.localizedDescription)")
        }
        let about = flag.isSelf ? "" : " (about \(flag.subjectName))"
        print("Flagged for the human on \(flag.raisedByName)'s row\(about): \(flag.message)")
        print("Flag ID: \(flag.id)")
        print("It clears when the human prompts \(flag.isSelf ? "you" : "you or \(flag.subjectName)"), dismisses it, or you run `maitre-d unflag`.")
        if !appRunning() {
            print("Note: the Maître d'Agént app isn't running right now; the human sees the flag once it starts.")
        }
        return 0
    }

    private static func unflag(_ options: Options) -> Int32 {
        let all = Flags.readAll()
        let matching: [Flag]
        if !options.ids.isEmpty || options.ref != nil {
            // By ID or ref: no session needed, so other tools can clear flags.
            matching = all.filter { options.ids.contains($0.id) || (options.ref != nil && $0.ref == options.ref) }
        } else {
            guard let me = currentSession() else {
                return fail("not running inside a Claude Code session; use --id or --ref to clear specific flags")
            }
            matching = all.filter { flag in
                (flag.raisedBySession == me.sessionId || flag.subjectSession == me.sessionId)
                    && (options.agent == nil || flag.subjectName == options.agent)
            }
        }
        matching.forEach { Flags.remove($0.id) }
        print(matching.isEmpty ? "No open flags to clear." : "Cleared \(matching.count) flag\(matching.count == 1 ? "" : "s").")
        return 0
    }

    private static func list(json: Bool) -> Int32 {
        let flags = Flags.readAll()
        if json {
            print(String(decoding: (try? Flags.encode(flags)) ?? Data("[]".utf8), as: UTF8.self))
            return 0
        }
        if flags.isEmpty { print("No open flags.") }
        for flag in flags {
            let about = flag.isSelf ? "" : " → \(flag.subjectName)"
            let ref = flag.ref.map { "  [\($0)]" } ?? ""
            print("\(flag.raisedByName)\(about): \(flag.message)  (\(ago(flag.createdAt)))\(ref)  id: \(flag.id)")
        }
        return 0
    }

    // MARK: - Sessions

    /// The Claude session this command runs in: the nearest ancestor process with a registry entry.
    static func currentSession() -> RegistryEntry? {
        let entries = Dictionary(Registry.read().map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        return Processes.ancestry(of: getppid()).lazy.compactMap { entries[$0] }.first
    }

    private struct ResolveError: Error { let message: String }

    /// Finds a live session by name, preferring one in the same repo as the caller.
    private static func resolve(_ name: String, near me: RegistryEntry) -> Result<RegistryEntry, ResolveError> {
        let target = Worker.recipientName(name)
        let entries = Registry.read()
        let matches = entries.filter { displayName($0) == target }
        if matches.count == 1 { return .success(matches[0]) }
        if matches.isEmpty {
            let names = entries.map(displayName).sorted().joined(separator: ", ")
            return .failure(ResolveError(message: "no running agent named \"\(target)\". Running agents: \(names)"))
        }
        let repos = RepoResolver()
        let myRepo = repos.root(for: me.cwd)
        let sameRepo = matches.filter { repos.root(for: $0.cwd) == myRepo }
        if sameRepo.count == 1 { return .success(sameRepo[0]) }
        return .failure(ResolveError(message: "several agents are named \"\(target)\"; rename one so flags can tell them apart"))
    }

    private static func displayName(_ entry: RegistryEntry) -> String {
        entry.name ?? URL(fileURLWithPath: entry.cwd).lastPathComponent
    }

    /// Whether the menu-bar app is running (other than this command, which is the same executable).
    private static func appRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "MaitreDAgent"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return true }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").contains { Int32($0) != getpid() }
    }

    private static func fail(_ message: String) -> Int32 {
        fputs("maitre-d: \(message)\n", stderr)
        return 1
    }
}

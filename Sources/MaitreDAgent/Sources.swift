import Darwin
import Foundation

// MARK: - Session registry (~/.claude/sessions/<pid>.json)
//
// Undocumented Claude Code internals: every running session keeps a JSON file
// with its pid, session id, cwd, name and status (busy | shell | idle | waiting).
// All parsing of that format lives here.

struct RegistryEntry {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String?
    let status: String?
    let waitingFor: String?
    let entrypoint: String?
    let statusUpdatedAt: Date?
}

enum Registry {
    static func read() -> [RegistryEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Paths.sessions.path) else { return [] }
        var seen = Set<String>()
        var entries: [RegistryEntry] = []
        for file in files where file.hasSuffix(".json") {
            guard let pid = Int32(file.dropLast(5)), isClaudeProcess(pid),
                  let data = fm.contents(atPath: Paths.sessions.appendingPathComponent(file).path),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sessionId = obj["sessionId"] as? String,
                  let cwd = obj["cwd"] as? String,
                  seen.insert(sessionId).inserted else { continue }
            let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            entries.append(RegistryEntry(
                pid: pid,
                sessionId: sessionId,
                cwd: cwd,
                name: name,
                status: obj["status"] as? String,
                waitingFor: obj["waitingFor"] as? String,
                entrypoint: obj["entrypoint"] as? String,
                statusUpdatedAt: (obj["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            ))
        }
        return entries
    }

    /// The pid is alive and (as far as we can tell) still a Claude process, not a reused pid.
    static func isClaudeProcess(_ pid: Int32) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return true }
        let name = String(cString: buffer).lowercased()
        return name.contains("claude") || name == "node"
    }
}

// MARK: - Process tree

enum Processes {
    static func parent(of pid: pid_t) -> pid_t? {
        kinfo(pid).map { $0.kp_eproc.e_ppid }
    }

    /// Controlling terminal of a process, e.g. "/dev/ttys003".
    static func tty(of pid: pid_t) -> String? {
        guard let info = kinfo(pid), info.kp_eproc.e_tdev != -1,
              let name = devname(info.kp_eproc.e_tdev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// The process and its ancestors, nearest first.
    static func ancestry(of pid: pid_t) -> [pid_t] {
        var chain = [pid]
        var current = pid
        while chain.count < 64, let parent = parent(of: current), parent > 1, parent != current {
            chain.append(parent)
            current = parent
        }
        return chain
    }

    /// sysctl rather than proc_pidinfo: it can also read root-owned processes like `login`,
    /// which sits between Terminal and the shell.
    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}

// MARK: - "Needs me" markers written by hook.sh

struct Marker {
    let reason: String
    let tool: String
    let since: Date

    var waitReason: WaitReason {
        switch reason {
        case "permission": return .permission(tool: tool)
        case "question": return .question
        case "plan": return .plan
        default: return .other(reason)
        }
    }
}

enum Markers {
    static func readAll() -> [String: Marker] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Paths.state.path) else { return [:] }
        var markers: [String: Marker] = [:]
        for file in files where file.hasSuffix(".json") {
            guard let data = fm.contents(atPath: Paths.state.appendingPathComponent(file).path),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            markers[String(file.dropLast(5))] = Marker(
                reason: obj["reason"] as? String ?? "waiting",
                tool: obj["tool"] as? String ?? "",
                since: Date(timeIntervalSince1970: obj["since"] as? Double ?? 0)
            )
        }
        return markers
    }

    static func remove(_ sessionId: String) {
        try? FileManager.default.removeItem(at: Paths.state.appendingPathComponent("\(sessionId).json"))
    }
}

// MARK: - Flags raised by agents (`maitre-d flag`)

enum Flags {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func readAll() -> [Flag] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Paths.flags.path) else { return [] }
        return files.filter { $0.hasSuffix(".json") }
            .compactMap { fm.contents(atPath: Paths.flags.appendingPathComponent($0).path) }
            .compactMap { try? decoder.decode(Flag.self, from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func write(_ flag: Flag) throws {
        try FileManager.default.createDirectory(at: Paths.flags, withIntermediateDirectories: true)
        try encoder.encode(flag).write(to: Paths.flags.appendingPathComponent("\(flag.id).json"), options: .atomic)
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: Paths.flags.appendingPathComponent("\(id).json"))
    }
}

// MARK: - Repo grouping

final class RepoResolver {
    private var cache: [String: String] = [:]

    /// Main repository root for a directory; worktrees resolve to their main repo.
    func root(for cwd: String) -> String {
        if let cached = cache[cwd] { return cached }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var root = cwd
        if (try? process.run()) != nil {
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               let path = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                root = url.lastPathComponent == ".git" ? url.deletingLastPathComponent().path : url.path
            }
        }
        cache[cwd] = root
        return root
    }
}

// MARK: - SendMessage calls from session transcripts

struct RawMessage {
    let id: String
    let sessionId: String
    let to: String
    let summary: String
    let text: String
    let date: Date
}

final class Transcripts {
    static let window: TimeInterval = 24 * 3600
    /// Never read more than this much of one transcript (they can be hundreds of MB).
    private static let maxScan: UInt64 = 16 << 20
    private static let sendPattern = Data(#""name":"SendMessage""#.utf8)
    private static let namePattern = Data(#""type":"agent-name""#.utf8)
    private static let usagePattern = Data(#""cache_read_input_tokens""#.utf8)
    private static let humanPattern = Data(#""kind":"human""#.utf8)
    private static let newline = UInt8(ascii: "\n")

    private struct Tail {
        let path: String
        var offset: UInt64
    }

    private var tails: [String: Tail] = [:]
    private var lastLookup: [String: Date] = [:]
    private var seen = Set<String>()
    /// Session names recorded in transcripts, for senders that are no longer running.
    private(set) var agentNames: [String: String] = [:]
    /// Context tokens of each session's latest main-thread API response, plus its model and peak.
    private(set) var contextTokens: [String: (tokens: Int, model: String, peak: Int)] = [:]
    /// When the human last prompted each session (messages from other agents don't count).
    private(set) var lastHumanPrompt: [String: Date] = [:]

    private let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    /// Messages from every transcript touched in the last 24h.
    func loadHistory() -> [RawMessage] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.window)
        var messages: [RawMessage] = []
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.projects, includingPropertiesForKeys: nil) else { return [] }
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= cutoff else { continue }
                let sessionId = file.deletingPathExtension().lastPathComponent
                let size = fileSize(file.path)
                var tail = Tail(path: file.path, offset: size > Self.maxScan ? size - Self.maxScan : 0)
                messages += read(&tail, sessionId: sessionId)
                tails[sessionId] = tail
            }
        }
        return messages.filter { $0.date >= cutoff }
    }

    /// New messages appended to the transcripts of the given sessions.
    func poll(sessionIds: [String]) -> [RawMessage] {
        var messages: [RawMessage] = []
        for sessionId in sessionIds {
            if tails[sessionId] == nil {
                if let last = lastLookup[sessionId], Date().timeIntervalSince(last) < 10 { continue }
                lastLookup[sessionId] = Date()
                guard let path = locate(sessionId) else { continue }
                let size = fileSize(path)
                tails[sessionId] = Tail(path: path, offset: size > Self.maxScan ? size - Self.maxScan : 0)
            }
            guard var tail = tails[sessionId] else { continue }
            messages += read(&tail, sessionId: sessionId)
            tails[sessionId] = tail
        }
        let cutoff = Date().addingTimeInterval(-Self.window)
        return messages.filter { $0.date >= cutoff }
    }

    private func locate(_ sessionId: String) -> String? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: Paths.projects.path) else { return nil }
        for dir in dirs {
            let path = Paths.projects.appendingPathComponent(dir).appendingPathComponent("\(sessionId).jsonl").path
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private func fileSize(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Reads complete lines from the tail's offset and advances it.
    private func read(_ tail: inout Tail, sessionId: String) -> [RawMessage] {
        let size = fileSize(tail.path)
        if size < tail.offset { tail.offset = 0 } // truncated or replaced
        guard size > tail.offset, let handle = FileHandle(forReadingAtPath: tail.path) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: tail.offset)) != nil,
              let data = try? handle.read(upToCount: Int(min(size - tail.offset, Self.maxScan))),
              let lastNewline = data.lastIndex(of: Self.newline) else { return [] }
        let complete = data[data.startIndex...lastNewline]
        tail.offset += UInt64(complete.count)
        return parse(complete, sessionId: sessionId)
    }

    private func parse(_ data: Data, sessionId: String) -> [RawMessage] {
        if let usage = latestUsage(in: data) {
            let peak = max(usage.tokens, contextTokens[sessionId]?.peak ?? 0)
            contextTokens[sessionId] = (usage.tokens, usage.model, peak)
        }
        var messages: [RawMessage] = []
        for line in lines(in: data, containing: Self.humanPattern) {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  obj["type"] as? String == "user",
                  (obj["origin"] as? [String: Any])?["kind"] as? String == "human",
                  let timestamp = obj["timestamp"] as? String,
                  let date = isoFull.date(from: timestamp) ?? isoPlain.date(from: timestamp) else { continue }
            if date > lastHumanPrompt[sessionId] ?? .distantPast { lastHumanPrompt[sessionId] = date }
        }
        for line in lines(in: data, containing: Self.namePattern) {
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
               let name = obj["agentName"] as? String {
                agentNames[obj["sessionId"] as? String ?? sessionId] = name
            }
        }
        for line in lines(in: data, containing: Self.sendPattern) {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let timestamp = obj["timestamp"] as? String ?? ""
            let date = isoFull.date(from: timestamp) ?? isoPlain.date(from: timestamp) ?? Date()
            for block in content where block["type"] as? String == "tool_use" && block["name"] as? String == "SendMessage" {
                guard let id = block["id"] as? String, seen.insert(id).inserted,
                      let input = block["input"] as? [String: Any],
                      let to = input["to"] as? String else { continue }
                let text: String
                if let string = input["message"] as? String {
                    text = string
                } else if let object = input["message"],
                          let json = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) {
                    text = String(decoding: json, as: UTF8.self)
                } else {
                    text = ""
                }
                messages.append(RawMessage(
                    id: id,
                    sessionId: obj["sessionId"] as? String ?? sessionId,
                    to: to,
                    summary: input["summary"] as? String ?? "",
                    text: text,
                    date: date
                ))
            }
        }
        return messages
    }

    /// The last main-thread assistant response with token usage in this chunk.
    private func latestUsage(in data: Data) -> (tokens: Int, model: String)? {
        var searchEnd = data.endIndex
        while searchEnd > data.startIndex,
              let match = data.range(of: Self.usagePattern, options: .backwards, in: data.startIndex..<searchEnd) {
            var start = match.lowerBound
            while start > data.startIndex && data[start - 1] != Self.newline { start -= 1 }
            let end = data[match.upperBound...].firstIndex(of: Self.newline) ?? data.endIndex
            searchEnd = start
            guard let obj = (try? JSONSerialization.jsonObject(with: data[start..<end])) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let model = message["model"] as? String ?? ""
            let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
            if tokens == 0 || model.hasPrefix("<") { continue } // synthetic messages
            return (tokens, model)
        }
        return nil
    }

    /// Whole lines that contain the pattern, without splitting every line of a large chunk.
    private func lines(in data: Data, containing pattern: Data) -> [Data] {
        var result: [Data] = []
        var searchStart = data.startIndex
        while searchStart < data.endIndex, let match = data.range(of: pattern, in: searchStart..<data.endIndex) {
            var start = match.lowerBound
            while start > data.startIndex && data[start - 1] != Self.newline { start -= 1 }
            let end = data[match.upperBound...].firstIndex(of: Self.newline) ?? data.endIndex
            let line = data[start..<end]
            // Skip API request dumps, which embed whole conversations.
            if line.prefix(64).range(of: Data("api-request".utf8)) == nil {
                result.append(Data(line))
            }
            searchStart = end
        }
        return result
    }
}

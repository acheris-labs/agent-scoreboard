import Foundation
import ScoreboardCore

// scoreboard CLI: init / hook / state / refresh / rename.
//
// Hand-rolled argument parsing rather than swift-argument-parser: this binary
// runs on every Claude hook, so it stays dependency-free and fast to start.

func usage() -> Never {
    print(
        """
        usage: scoreboard <command>

          init [--remove]              register (or unregister) Claude Code hooks
          hook                         hook entrypoint, reads JSON on stdin
          state                        print the board
          refresh                      re-link sessions to their terminal tabs
          rename <name> [--session ID] rename a session's menu row
        """)
    exit(2)
}

// MARK: - hook

// Always exits 0 and prints nothing: Claude parses hook output, and any noise
// here would disturb the session. Errors go to the log.
func cmdHook() -> Int32 {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty,
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return 0 }
    if let event = Mapping.mapHook(payload) {
        SocketClient.send(event)
    }
    return 0
}

// MARK: - init

func cmdInit(remove: Bool) -> Int32 {
    let path = Paths.claudeSettings
    do {
        if remove {
            let removed = try Settings.remove(path)
            print(removed.isEmpty
                ? "nothing to remove"
                : "removed scoreboard hooks: \(removed.joined(separator: ", "))")
            return 0
        }
        let added = try Settings.merge(path)
        let status = try Settings.scan(path)
        for event in Settings.allEvents {
            let mark = added.contains(event) ? "added" : (status[event] == true ? "✓" : "✗")
            print("  \(mark.padding(toLength: max(5, mark.count), withPad: " ", startingAt: 0)) \(event)")
        }
        if !FileManager.default.fileExists(atPath: Paths.socket) {
            print("note: Scoreboard app is not running")
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("scoreboard init: \(error)\n".utf8))
        return 1
    }
}

// MARK: - snapshot readers

struct SnapshotSession {
    let sessionID: String
    let state: String
    let title: String
    let cwd: String
    let pid: Int
    let updatedAt: Double
    let hasOrigin: Bool
}

func readSessions() -> [SnapshotSession]? {
    guard let data = FileManager.default.contents(atPath: Paths.snapshot),
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let rows = root["sessions"] as? [[String: Any]]
    else { return nil }
    return rows.map {
        SnapshotSession(
            sessionID: $0["sessionId"] as? String ?? "?",
            state: $0["state"] as? String ?? "?",
            title: $0["title"] as? String ?? "?",
            cwd: $0["cwd"] as? String ?? "",
            pid: $0["pid"] as? Int ?? 0,
            updatedAt: $0["updatedAt"] as? Double ?? 0,
            hasOrigin: $0["origin"] != nil)
    }
}

func age(_ ts: Double) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince1970 - ts))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return String(format: "%dh%02dm", seconds / 3600, (seconds % 3600) / 60)
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func cmdState() -> Int32 {
    guard let sessions = readSessions() else {
        print("no snapshot — is the Scoreboard app running?")
        return 1
    }
    if sessions.isEmpty {
        print("no Claude sessions")
        return 0
    }
    for s in sessions.sorted(by: { $0.updatedAt > $1.updatedAt }) {
        print(
            "\(pad(s.state, 8)) \(pad(s.title, 24)) pid=\(pad(String(s.pid), 7)) "
                + "age=\(pad(age(s.updatedAt), 6)) \(s.sessionID)")
    }
    return 0
}

// MARK: - refresh

func cmdRefresh() -> Int32 {
    guard let sessions = readSessions() else {
        print("no snapshot — is the Scoreboard app running?")
        return 1
    }
    let env = ProcessInfo.processInfo.environment
    if let sessionID = env["CLAUDE_CODE_SESSION_ID"], !sessionID.isEmpty {
        // Run from inside the session's tab: capture this terminal directly.
        guard let adapter = TerminalCapture.detect() else {
            print("unsupported terminal (no adapter)")
            return 1
        }
        guard let origin = adapter.captureOrigin() else {
            print("could not capture terminal (is the terminal focused?)")
            return 1
        }
        SocketClient.send([
            "v": 1, "session_id": sessionID, "origin": origin,
            "ts": Date().timeIntervalSince1970,
        ])
        print("linked session to \(origin["kind"] ?? "terminal") terminal")
        return 0
    }
    // Outside a session: match origin-less sessions to terminals by unique cwd.
    let origins = TerminalCapture.allOrigins()
    var fixed = 0
    for session in sessions where !session.hasOrigin {
        let matches = origins.filter { $0.cwd == session.cwd }
        let label = "\(session.title) (\(session.sessionID.prefix(8)))"
        if matches.count == 1 {
            SocketClient.send([
                "v": 1, "session_id": session.sessionID, "origin": matches[0].origin,
                "ts": Date().timeIntervalSince1970,
            ])
            print("linked   \(label)")
            fixed += 1
        } else {
            print("skipped  \(label): \(matches.isEmpty ? "no terminal match" : "ambiguous cwd")")
        }
    }
    if fixed == 0 && sessions.allSatisfy({ $0.hasOrigin }) {
        print("all sessions already linked")
    }
    return 0
}

// MARK: - rename

func cmdRename(name: String, prefix: String?) -> Int32 {
    guard let sessions = readSessions() else {
        print("no snapshot — is the Scoreboard app running?")
        return 1
    }
    let env = ProcessInfo.processInfo.environment
    var target: String?
    if let sessionID = env["CLAUDE_CODE_SESSION_ID"], !sessionID.isEmpty {
        // Inside a session the id is authoritative even if not on the board yet.
        target = sessionID
    } else if let prefix {
        let matches = sessions.filter { $0.sessionID.hasPrefix(prefix) }
        if matches.count == 1 {
            target = matches[0].sessionID
        } else {
            print("\(matches.isEmpty ? "no" : "ambiguous") session match for \"\(prefix)\"")
            return 1
        }
    } else {
        print("not inside a Claude session - pass --session <id-prefix>")
        return 1
    }
    SocketClient.send([
        "v": 1, "session_id": target!, "title": name, "title_pinned": true,
        "ts": Date().timeIntervalSince1970,
    ])
    print("renamed to \"\(name)\"")
    return 0
}

// MARK: - dispatch

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "hook":
    exit(cmdHook())
case "init":
    exit(cmdInit(remove: args.contains("--remove")))
case "state":
    exit(cmdState())
case "refresh":
    exit(cmdRefresh())
case "rename":
    let positional = args.dropFirst().filter { !$0.hasPrefix("--") }
    guard let name = positional.first else { usage() }
    var session: String?
    if let i = args.firstIndex(of: "--session"), i + 1 < args.count {
        session = args[i + 1]
    }
    exit(cmdRename(name: name, prefix: session))
case "-h", "--help", "help":
    usage()
default:
    usage()
}

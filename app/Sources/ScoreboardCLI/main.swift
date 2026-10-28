import Foundation
import ScoreboardCore

// scoreboard CLI: init / hook / state / rename.
//
// Hand-rolled argument parsing rather than swift-argument-parser: this binary
// runs on every Claude hook, so it stays dependency-free and fast to start.

func usage() -> Never {
    print(
        """
        usage: scoreboard <command>

          init                         register Claude Code hooks in ~/.claude
          init --remove                unregister them from every config folder
          init --restore               re-register every remembered config folder
          hook                         hook entrypoint, reads JSON on stdin
          state                        print the board
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

func report(_ outcomes: [ConfigFolders.Outcome], verb: String) -> Int32 {
    var failed = false
    for (folder, result) in outcomes {
        let label = (folder as NSString).abbreviatingWithTildeInPath
        switch result {
        case .success(let events):
            print(events.isEmpty
                ? "  \(label): nothing to do"
                : "  \(label): \(verb) \(events.joined(separator: ", "))")
        case .failure(let error):
            failed = true
            print("  \(label): \(error)")
        }
    }
    return failed ? 1 : 0
}

// `init` registers ~/.claude; the Settings window handles other folders.
// --remove strips every remembered folder (cask uninstall); --restore
// re-registers them (cask install, which is how `brew upgrade` keeps them).
func cmdInit(remove: Bool, restore: Bool) -> Int32 {
    let folders = ConfigFolders.standard
    if remove { return report(folders.removeAll(), verb: "removed") }
    if restore {
        let outcomes = folders.restore()
        if outcomes.isEmpty { print("no Claude config folders registered") }
        return report(outcomes, verb: "added")
    }
    let path = ConfigFolders.settingsPath(folders.defaultFolder)
    do {
        let added = try folders.add(folders.defaultFolder)
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
            updatedAt: $0["updatedAt"] as? Double ?? 0)
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
    exit(cmdInit(remove: args.contains("--remove"), restore: args.contains("--restore")))
case "state":
    exit(cmdState())
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

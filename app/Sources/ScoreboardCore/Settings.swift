import Foundation

// Register/remove scoreboard hooks in Claude Code's settings.json.
//
// The literal command string `scoreboard hook` is the ownership marker:
// presence is detected by exact string, and removal strips only entries whose
// command equals it. Writes are backup-then-atomic-rename. JSONSerialization
// rather than Codable: the file is arbitrary user JSON we must preserve, not
// a shape we own.
public enum Settings {
    public static let hookCommand = "scoreboard hook"
    public static let askMatcher = "AskUserQuestion"
    public static let plainEvents = [
        "Notification", "Stop", "UserPromptSubmit", "SessionStart", "SessionEnd",
        "PermissionRequest", "PostToolUse",
    ]
    public static let matchedEvents = ["PreToolUse"]
    public static var allEvents: [String] { plainEvents + matchedEvents }

    public enum SettingsError: Error, CustomStringConvertible {
        case notAnObject(String)
        public var description: String {
            switch self {
            case .notAnObject(let path): return "\(path) is not a JSON object"
            }
        }
    }

    static func isOurs(_ hook: Any) -> Bool {
        (hook as? [String: Any])?["command"] as? String == hookCommand
    }

    static func entryHasOurs(_ entry: Any) -> Bool {
        guard let entry = entry as? [String: Any],
            let hooks = entry["hooks"] as? [Any]
        else { return false }
        return hooks.contains(where: isOurs)
    }

    public static func load(_ path: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count > 0 else { return [:] }
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let object = parsed as? [String: Any] else {
            throw SettingsError.notAnObject(path)
        }
        return object
    }

    static func installed(_ settings: [String: Any], _ event: String) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let entries = hooks[event] as? [Any] ?? []
        for entry in entries where entryHasOurs(entry) {
            // A user's other PreToolUse matcher must not mask ours.
            if matchedEvents.contains(event),
                (entry as? [String: Any])?["matcher"] as? String != askMatcher
            {
                continue
            }
            return true
        }
        return false
    }

    /// Which of the hooks scoreboard needs are already registered.
    public static func scan(_ path: String) throws -> [String: Bool] {
        let settings = try load(path)
        return Dictionary(uniqueKeysWithValues: allEvents.map { ($0, installed(settings, $0)) })
    }

    /// Add missing scoreboard hooks. Returns the events added.
    @discardableResult
    public static func merge(_ path: String) throws -> [String] {
        var settings = try load(path)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var added: [String] = []
        var changed = false

        // Migration: PostToolUse used to be registered with the
        // AskUserQuestion matcher, which never fired after a granted
        // permission. Drop that entry so the matcher-less one replaces it.
        if var entries = hooks["PostToolUse"] as? [Any] {
            let kept = entries.filter { entry in
                !(entryHasOurs(entry)
                    && (entry as? [String: Any])?["matcher"] as? String == askMatcher)
            }
            if kept.count != entries.count {
                entries = kept
                changed = true
                if entries.isEmpty {
                    hooks.removeValue(forKey: "PostToolUse")
                } else {
                    hooks["PostToolUse"] = entries
                }
            }
        }
        settings["hooks"] = hooks

        for event in allEvents where !installed(settings, event) {
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": hookCommand]]
            ]
            if matchedEvents.contains(event) { entry["matcher"] = askMatcher }
            var entries = hooks[event] as? [Any] ?? []
            entries.append(entry)
            hooks[event] = entries
            settings["hooks"] = hooks
            added.append(event)
        }
        if !added.isEmpty || changed {
            settings["hooks"] = hooks
            try write(path, settings)
        }
        return added
    }

    /// Strip scoreboard hooks only. Returns the events cleaned.
    @discardableResult
    public static func remove(_ path: String) throws -> [String] {
        var settings = try load(path)
        guard var hooks = settings["hooks"] as? [String: Any] else { return [] }
        var removed: [String] = []

        for event in hooks.keys.sorted() {
            guard let entries = hooks[event] as? [Any] else { continue }
            var cleaned: [Any] = []
            var touched = false
            for entry in entries {
                guard entryHasOurs(entry) else {
                    cleaned.append(entry)
                    continue
                }
                touched = true
                var entryDict = entry as? [String: Any] ?? [:]
                let kept = (entryDict["hooks"] as? [Any] ?? []).filter { !isOurs($0) }
                if !kept.isEmpty {
                    entryDict["hooks"] = kept
                    cleaned.append(entryDict)
                }
            }
            guard touched else { continue }
            removed.append(event)
            if cleaned.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = cleaned
            }
        }
        if !removed.isEmpty {
            if hooks.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = hooks
            }
            try write(path, settings)
        }
        return removed
    }

    /// How many timestamped backups to keep. `brew upgrade` is internally an
    /// uninstall plus an install, so hooks are removed and re-added on every
    /// upgrade; without pruning these would accumulate forever.
    public static let backupsKept = 5

    /// Back up the byte-exact original, then write atomically.
    @discardableResult
    static func write(_ path: String, _ settings: [String: Any]) throws -> String? {
        let manager = FileManager.default
        var backup: String?
        if manager.fileExists(atPath: path) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            let stamp = formatter.string(from: Date())
            backup = "\(path).backup-\(stamp)"
            try? manager.removeItem(atPath: backup!)
            try manager.copyItem(atPath: path, toPath: backup!)
            pruneBackups(path)
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try manager.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let tmp = "\(path).tmp-\(ProcessInfo.processInfo.processIdentifier)"
        try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: tmp))
        _ = try manager.replaceItemAt(
            URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
        return backup
    }

    /// Keep only the newest `backupsKept` backups of this settings file. The
    /// timestamp in the name sorts lexicographically, so no stat calls.
    static func pruneBackups(_ path: String) {
        let manager = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        let prefix = (path as NSString).lastPathComponent + ".backup-"
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return }
        let backups = names.filter { $0.hasPrefix(prefix) }.sorted()
        guard backups.count > backupsKept else { return }
        for stale in backups.dropLast(backupsKept) {
            try? manager.removeItem(atPath: (directory as NSString).appendingPathComponent(stale))
        }
    }
}

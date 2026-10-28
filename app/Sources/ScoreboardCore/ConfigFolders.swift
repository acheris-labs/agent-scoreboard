import Foundation

// The Claude Code config folders (one per CLAUDE_CONFIG_DIR; ~/.claude by
// default) that scoreboard's hooks are registered in. Nothing is registered
// on install: folders are added from the Settings window or `scoreboard init`.
//
// The list outlives an uninstall on purpose. `brew upgrade` is an uninstall
// (hooks stripped everywhere) followed by an install, and the install's
// `init --restore` puts the hooks back in exactly the folders chosen.
// `brew uninstall --zap` deletes the list with the rest of the state dir.
public struct ConfigFolders {
    public typealias Outcome = (folder: String, result: Result<[String], Error>)

    public let listPath: String
    public let defaultFolder: String

    public init(listPath: String, defaultFolder: String) {
        self.listPath = listPath
        self.defaultFolder = defaultFolder
    }

    public static let standard = ConfigFolders(
        listPath: Paths.configFolders, defaultFolder: Paths.defaultClaudeFolder)

    public static func settingsPath(_ folder: String) -> String {
        (folder as NSString).appendingPathComponent("settings.json")
    }

    public static func normalize(_ folder: String) -> String {
        NSString(string: NSString(string: folder).expandingTildeInPath).standardizingPath
    }

    /// Remembered folders, in the order they were added.
    public func list() -> [String] {
        guard let text = try? String(contentsOfFile: listPath, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        return text.split(separator: "\n").map(String.init)
            .filter { seen.insert($0).inserted }
    }

    func save(_ folders: [String]) throws {
        try FileManager.default.createDirectory(
            atPath: (listPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let text = folders.map { $0 + "\n" }.joined()
        try Data(text.utf8).write(to: URL(fileURLWithPath: listPath), options: .atomic)
    }

    /// Register the hooks in a folder and remember it. Returns events added.
    @discardableResult
    public func add(_ folder: String) throws -> [String] {
        let folder = Self.normalize(folder)
        let added = try Settings.merge(Self.settingsPath(folder))
        let folders = list()
        if !folders.contains(folder) { try save(folders + [folder]) }
        return added
    }

    /// Strip the hooks from a folder and forget it. Returns events removed.
    @discardableResult
    public func remove(_ folder: String) throws -> [String] {
        let folder = Self.normalize(folder)
        let removed = try Settings.remove(Self.settingsPath(folder))
        try save(list().filter { $0 != folder })
        return removed
    }

    /// Strip the hooks from every remembered folder, plus the default one:
    /// versions before 3.1 registered it without keeping a list. The list
    /// itself is kept (see the type comment).
    public func removeAll() -> [Outcome] {
        let listed = list()
        let targets = listed.contains(defaultFolder) ? listed : listed + [defaultFolder]
        return targets.map { folder in
            (folder, Result { try Settings.remove(Self.settingsPath(folder)) })
        }
    }

    /// Re-register every remembered folder.
    public func restore() -> [Outcome] {
        migrateIfNeeded()
        return list().map { folder in
            (folder, Result { try Settings.merge(Self.settingsPath(folder)) })
        }
    }

    /// Versions before 3.1 registered ~/.claude without keeping a list. The
    /// first time a list is needed, start it with the default folder if our
    /// hooks are in it right now - the one exact signal. (A `brew upgrade`
    /// from 3.0 has already stripped them, so that folder is added again from
    /// Settings, which opens by itself while the list is empty.)
    public func migrateIfNeeded() {
        guard !FileManager.default.fileExists(atPath: listPath) else { return }
        let scan = try? Settings.scan(Self.settingsPath(defaultFolder))
        try? save(scan?.values.contains(true) == true ? [defaultFolder] : [])
    }
}

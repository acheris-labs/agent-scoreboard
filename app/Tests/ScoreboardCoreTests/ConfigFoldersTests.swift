import XCTest

@testable import ScoreboardCore

final class ConfigFoldersTests: XCTestCase {
    var root: URL!
    var folders: ConfigFolders!

    // Everything lives under one temp root: the list, the default ~/.claude
    // stand-in, and any extra config folders.
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scoreboard-folders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        folders = ConfigFolders(
            listPath: path("state/config-folders"), defaultFolder: path("dot-claude"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func path(_ name: String) -> String {
        root.appendingPathComponent(name).path
    }

    func makeFolder(_ name: String) throws -> String {
        let folder = path(name)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    func registered(_ folder: String) throws -> Bool {
        try Settings.scan(ConfigFolders.settingsPath(folder)).values.allSatisfy { $0 }
    }

    func hasAnyHook(_ folder: String) throws -> Bool {
        try Settings.scan(ConfigFolders.settingsPath(folder)).values.contains(true)
    }

    func testAddRegistersHooksAndRemembersFolder() throws {
        let work = try makeFolder("claude-work")
        try folders.add(work)
        XCTAssertTrue(try registered(work))
        XCTAssertEqual(folders.list(), [work])
    }

    func testAddTwiceListsOnce() throws {
        let work = try makeFolder("claude-work")
        try folders.add(work)
        try folders.add(work + "/")
        XCTAssertEqual(folders.list(), [work])
    }

    func testRemoveUnregistersAndForgets() throws {
        let work = try makeFolder("claude-work")
        let other = try makeFolder("claude-other")
        try folders.add(work)
        try folders.add(other)
        try folders.remove(work)
        XCTAssertFalse(try hasAnyHook(work))
        XCTAssertEqual(folders.list(), [other])
    }

    func testRemoveAllCoversListedAndDefaultButKeepsList() throws {
        let work = try makeFolder("claude-work")
        let legacy = try makeFolder("dot-claude")
        try folders.add(work)
        // Registered by an older version: hooks present, never listed.
        try Settings.merge(ConfigFolders.settingsPath(legacy))

        let results = folders.removeAll()
        XCTAssertEqual(results.map(\.folder), [work, legacy])
        XCTAssertFalse(try hasAnyHook(work))
        XCTAssertFalse(try hasAnyHook(legacy))
        // Kept so the install half of `brew upgrade` can restore it.
        XCTAssertEqual(folders.list(), [work])
    }

    func testRestoreReregistersListedFolders() throws {
        let work = try makeFolder("claude-work")
        try folders.add(work)
        _ = folders.removeAll()
        _ = folders.restore()
        XCTAssertTrue(try registered(work))
    }

    func testFreshMachineStartsWithNothing() throws {
        _ = folders.restore()
        XCTAssertEqual(folders.list(), [])
        XCTAssertFalse(try hasAnyHook(path("dot-claude")))
    }

    // A version before 3.1 registered ~/.claude and kept no list.
    func testListlessHooksInDefaultFolderAreAdopted() throws {
        let legacy = try makeFolder("dot-claude")
        try Settings.merge(ConfigFolders.settingsPath(legacy))
        folders.migrateIfNeeded()
        XCTAssertEqual(folders.list(), [legacy])
    }

    // Scoreboard was used here once, but its hooks are long gone: a new
    // install must not quietly put them back.
    func testDefaultFolderWithoutHooksIsNotAdopted() throws {
        let legacy = try makeFolder("dot-claude")
        try Settings.merge(ConfigFolders.settingsPath(legacy))
        try Settings.remove(ConfigFolders.settingsPath(legacy))
        _ = folders.restore()
        XCTAssertEqual(folders.list(), [])
        XCTAssertFalse(try hasAnyHook(legacy))
    }

    func testMigrationNeverOverridesAnExistingList() throws {
        let work = try makeFolder("claude-work")
        try folders.add(work)
        try folders.remove(work)
        _ = folders.restore()
        XCTAssertEqual(folders.list(), [])
    }

    func testNormalizeExpandsTildeAndTrailingSlash() {
        XCTAssertEqual(
            ConfigFolders.normalize("~/.claude-work/"),
            NSHomeDirectory() + "/.claude-work")
    }
}

import XCTest

@testable import ScoreboardCore

final class SettingsTests: XCTestCase {
    var dir: URL!
    var path: String!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scoreboard-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("settings.json").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func read() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: URL(fileURLWithPath: path))
    }

    func hooks(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    func commands(_ entry: [String: Any]) -> [String] {
        (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
    }

    func testMergeIntoMissingFile() throws {
        let added = try Settings.merge(path)
        XCTAssertEqual(added.sorted(), Settings.allEvents.sorted())
        let settings = try read()
        for event in Settings.plainEvents {
            let entries = hooks(settings, event)
            XCTAssertEqual(entries.count, 1, event)
            XCTAssertEqual(commands(entries[0]), ["scoreboard hook"], event)
            XCTAssertNil(entries[0]["matcher"], event)
        }
        for event in Settings.matchedEvents {
            let entries = hooks(settings, event)
            XCTAssertEqual(entries[0]["matcher"] as? String, "AskUserQuestion", event)
        }
    }

    func testMergePreservesUserHooks() throws {
        try write([
            "model": "opus",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "mytool notify"]]]]],
        ])
        try Settings.merge(path)
        let settings = try read()
        XCTAssertEqual(settings["model"] as? String, "opus")
        let entries = hooks(settings, "Stop")
        XCTAssertEqual(commands(entries[0]), ["mytool notify"])
        XCTAssertEqual(commands(entries[1]), ["scoreboard hook"])
    }

    func testDoubleMergeIsNoop() throws {
        try Settings.merge(path)
        let first = try read()
        let added = try Settings.merge(path)
        XCTAssertEqual(added, [])
        XCTAssertEqual(
            NSDictionary(dictionary: try read()), NSDictionary(dictionary: first))
    }

    func testForeignPreToolUseMatcherStillGetsOurs() throws {
        try write([
            "hooks": [
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "x"]]]]
            ]
        ])
        let added = try Settings.merge(path)
        XCTAssertTrue(added.contains("PreToolUse"))
        let entries = hooks(try read(), "PreToolUse")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1]["matcher"] as? String, "AskUserQuestion")
    }

    // PostToolUse used to be registered with the AskUserQuestion matcher,
    // which never fired after a granted permission.
    func testMigratesLegacyMatchedPostToolUse() throws {
        try write([
            "hooks": [
                "PostToolUse": [
                    [
                        "matcher": "AskUserQuestion",
                        "hooks": [["type": "command", "command": "scoreboard hook"]],
                    ]
                ]
            ]
        ])
        try Settings.merge(path)
        let entries = hooks(try read(), "PostToolUse")
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0]["matcher"])
        XCTAssertEqual(commands(entries[0]), ["scoreboard hook"])
    }

    func testScan() throws {
        XCTAssertTrue(try Settings.scan(path).values.allSatisfy { $0 == false })
        try Settings.merge(path)
        XCTAssertTrue(try Settings.scan(path).values.allSatisfy { $0 == true })
    }

    func testRemoveStripsOnlyOurs() throws {
        try write([
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "mytool notify"]]]]]
        ])
        try Settings.merge(path)
        let removed = try Settings.remove(path)
        XCTAssertEqual(removed.sorted(), Settings.allEvents.sorted())
        let settings = try read()
        XCTAssertEqual(Array((settings["hooks"] as? [String: Any] ?? [:]).keys), ["Stop"])
        XCTAssertEqual(commands(hooks(settings, "Stop")[0]), ["mytool notify"])
    }

    func testRemoveDeletesEmptyHooksKey() throws {
        try Settings.merge(path)
        try Settings.remove(path)
        XCTAssertNil(try read()["hooks"])
    }

    func testRemoveOnCleanFileIsNoop() throws {
        try write(["model": "opus"])
        XCTAssertEqual(try Settings.remove(path), [])
    }

    func testBackupCreatedWithOriginalBytes() throws {
        let original = "{\"model\":\"opus\"}"
        try original.write(toFile: path, atomically: true, encoding: .utf8)
        try Settings.merge(path)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("settings.json.backup-") }
        XCTAssertEqual(backups.count, 1)
        let restored = try String(
            contentsOfFile: dir.appendingPathComponent(backups[0]).path, encoding: .utf8)
        XCTAssertEqual(restored, original)
    }

    func testEmptyFileTreatedAsEmptyObject() throws {
        try Data().write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(try Settings.merge(path).sorted(), Settings.allEvents.sorted())
    }
}

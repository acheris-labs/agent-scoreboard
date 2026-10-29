import XCTest

@testable import ScoreboardCore

final class SettingsMigrationTests: XCTestCase {
    let old = "test.scoreboard.migration.old"
    let new = "test.scoreboard.migration.new"
    let defaults = UserDefaults.standard

    override func setUp() {
        defaults.removePersistentDomain(forName: old)
        defaults.removePersistentDomain(forName: new)
    }

    override func tearDown() { setUp() }

    func testCopiesOnceAndDropsKeys() {
        defaults.setPersistentDomain(["hideWhenIdle": true, "skip": 1], forName: old)
        XCTAssertTrue(SettingsMigration.copyDomain(from: old, to: new, dropping: ["skip"]))
        let copied = defaults.persistentDomain(forName: new)
        XCTAssertEqual(copied?["hideWhenIdle"] as? Bool, true)
        XCTAssertNil(copied?["skip"])

        // A second launch must not overwrite settings changed since.
        defaults.setPersistentDomain(["hideWhenIdle": false], forName: new)
        XCTAssertFalse(SettingsMigration.copyDomain(from: old, to: new))
        XCTAssertEqual(defaults.persistentDomain(forName: new)?["hideWhenIdle"] as? Bool, false)
    }

    func testNothingToCopy() {
        XCTAssertFalse(SettingsMigration.copyDomain(from: old, to: new))
        XCTAssertTrue(defaults.persistentDomain(forName: new)?.isEmpty ?? true)
    }
}

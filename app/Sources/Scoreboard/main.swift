import AppKit
import ScoreboardCore

MainActor.assumeIsolated {
    // Before anything reads a setting. Start at login is registered per
    // bundle id, so the old "already set up" flag stays behind and the new id
    // registers itself like a fresh install.
    SettingsMigration.copyDomain(
        from: Paths.legacyBundleID, to: Paths.bundleID,
        dropping: [LoginItemController.bootstrappedKey])
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

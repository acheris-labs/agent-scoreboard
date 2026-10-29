import Foundation

// Filesystem contract shared by the menu bar app and the CLI.
public enum Paths {
    public static let stateDir = NSString(string: "~/.local/state/scoreboard")
        .expandingTildeInPath
    public static let socket = stateDir + "/scoreboard.sock"
    public static let snapshot = stateDir + "/state.json"
    // Present only while "Quit When No Sessions" is on: tells the CLI it may
    // relaunch the app to deliver an event.
    public static let autostart = stateDir + "/autostart"
    public static let log = stateDir + "/hook.log"
    // One line per session state change, for Show Details (HistoryLog).
    public static let history = stateDir + "/history.ndjson"
    // Touched while the app runs: after a crash, its age says when we stopped.
    public static let historyAlive = stateDir + "/history.alive"
    // Config folders whose settings.json carries our hooks (ConfigFolders).
    public static let configFolders = stateDir + "/config-folders"
    // Claude Code's config folder when CLAUDE_CONFIG_DIR is unset.
    public static let defaultClaudeFolder = NSString(string: "~/.claude")
        .expandingTildeInPath
    public static let bundleID = "net.acheris.scoreboard"
    // The bundle id before 3.2.2: settings move over once (SettingsMigration),
    // and a copy still running under it is quit at launch.
    public static let legacyBundleID = "com.chrismadden.scoreboard"
}

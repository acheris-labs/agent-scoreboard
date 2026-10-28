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
    // Config folders whose settings.json carries our hooks (ConfigFolders).
    public static let configFolders = stateDir + "/config-folders"
    // Claude Code's config folder when CLAUDE_CONFIG_DIR is unset.
    public static let defaultClaudeFolder = NSString(string: "~/.claude")
        .expandingTildeInPath
    public static let bundleID = "com.chrismadden.scoreboard"
}

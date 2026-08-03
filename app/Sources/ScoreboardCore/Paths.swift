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
    public static let claudeSettings = NSString(string: "~/.claude/settings.json")
        .expandingTildeInPath
    public static let bundleID = "com.chrismadden.scoreboard"
}

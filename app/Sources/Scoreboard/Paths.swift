import Foundation

// Filesystem contract shared with the Python CLI (cli/src/scoreboard/paths.py).
enum Paths {
    static let stateDir = NSString(string: "~/.local/state/scoreboard").expandingTildeInPath
    static let socket = stateDir + "/scoreboard.sock"
    static let snapshot = stateDir + "/state.json"
}

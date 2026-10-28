import Foundation

// Which terminal app a session runs in, read from the environment the hook
// inherits. The origin only names the app ({"kind": "ghostty"}); the app-side
// adapter for that kind finds the exact tab itself, from the session's tty.
// Adding a terminal app = one case here and one adapter in the app.
public enum TerminalCapture {
    public static func origin(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String]? {
        switch environment["TERM_PROGRAM"] {
        case "ghostty": return ["kind": "ghostty"]
        default: return nil
        }
    }
}

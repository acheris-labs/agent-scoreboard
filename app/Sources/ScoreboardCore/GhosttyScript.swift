import Foundation

// Building the AppleScript that focuses a Ghostty terminal. Kept apart from
// the adapter that runs it: running needs AppKit and the main actor, while
// building is pure string handling - and it is the one place where values
// that came from disk (a working directory) or off the socket reach an
// interpreter, so it is the part worth testing.
public enum GhosttyScript {
    /// AppleScript string literals recognise only \" and \\ as escapes, so
    /// neutralising those two makes the literal impossible to close. Order
    /// matters: backslashes first, or the backslash pass would double the
    /// ones just introduced by the quote pass.
    public static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func focus(terminalID: String) -> String {
        """
        tell application "Ghostty"
            focus (first terminal whose id is "\(escape(terminalID))")
            activate
        end tell
        """
    }

    public static func focus(workingDirectory cwd: String) -> String {
        """
        tell application "Ghostty"
            focus (first terminal whose working directory is "\(escape(cwd))")
            activate
        end tell
        """
    }

    public static let activate = "tell application \"Ghostty\" to activate"
}

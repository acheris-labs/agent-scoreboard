import AppKit

// All Ghostty AppleScript lives here. Ghostty's `focus` command raises the
// terminal's window and selects its tab in one step.
@MainActor
final class GhosttyAdapter: TerminalAdapter {
    static let kind = "ghostty"

    func jump(origin: [String: String], cwd: String) -> Bool {
        if let terminalId = origin["terminal_id"], !terminalId.isEmpty,
            run(script: focusScript(byId: terminalId))
        {
            return true
        }
        // Terminal gone or origin never captured: best-effort cwd match,
        // then plain app activation so the click always does something.
        if !cwd.isEmpty, run(script: focusScript(byCwd: cwd)) {
            return true
        }
        return run(script: "tell application \"Ghostty\" to activate")
    }

    private func focusScript(byId terminalId: String) -> String {
        """
        tell application "Ghostty"
            focus (first terminal whose id is "\(escape(terminalId))")
            activate
        end tell
        """
    }

    private func focusScript(byCwd cwd: String) -> String {
        """
        tell application "Ghostty"
            focus (first terminal whose working directory is "\(escape(cwd))")
            activate
        end tell
        """
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func run(script: String) -> Bool {
        guard let apple = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        apple.executeAndReturnError(&error)
        if let error {
            NSLog("scoreboard: ghostty jump failed: \(error)")
            return false
        }
        return true
    }
}

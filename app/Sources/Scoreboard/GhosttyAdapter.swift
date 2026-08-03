import AppKit
import ScoreboardCore

// Runs the Ghostty AppleScript. The scripts themselves are built in
// ScoreboardCore.GhosttyScript, which is pure and unit-tested; this half is
// the side effect. Ghostty's `focus` command raises the terminal's window and
// selects its tab in one step.
@MainActor
final class GhosttyAdapter: TerminalAdapter {
    static let kind = "ghostty"

    func jump(origin: [String: String], cwd: String) -> Bool {
        if let terminalId = origin["terminal_id"], !terminalId.isEmpty,
            run(script: GhosttyScript.focus(terminalID: terminalId))
        {
            return true
        }
        // Terminal gone or origin never captured: best-effort cwd match,
        // then plain app activation so the click always does something.
        if !cwd.isEmpty, run(script: GhosttyScript.focus(workingDirectory: cwd)) {
            return true
        }
        return run(script: GhosttyScript.activate)
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

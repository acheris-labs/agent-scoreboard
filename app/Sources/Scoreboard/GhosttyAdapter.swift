import AppKit
import ScoreboardCore

// Runs the Ghostty AppleScript. The scripts themselves are built in
// ScoreboardCore.GhosttyScript, which is pure and unit-tested; this half is
// the side effect. Ghostty's `focus` command raises the terminal's window and
// selects its tab in one step.
@MainActor
final class GhosttyAdapter: TerminalAdapter {
    static let kind = "ghostty"

    func jump(pid: Int32, cwd: String) -> Bool {
        // The session's tty names its tab exactly (Ghostty 1.4+).
        if let tty = ProcessTTY.path(of: pid), run(script: GhosttyScript.focus(tty: tty)) {
            return true
        }
        // No tty (e.g. claude inside tmux): best-effort cwd match, then plain
        // app activation so the click always does something.
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

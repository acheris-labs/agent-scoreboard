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
        // The nearest tty in the session's process tree that Ghostty owns
        // names its tab exactly (Ghostty 1.4+).
        let tabs = tabTTYs()
        if let tty = ProcessTTY.lineage(of: pid).first(where: tabs.contains),
            run(script: GhosttyScript.focus(tty: tty)) != nil
        {
            return true
        }
        // No tty (e.g. claude inside tmux): best-effort cwd match, then plain
        // app activation so the click always does something.
        if !cwd.isEmpty, run(script: GhosttyScript.focus(workingDirectory: cwd)) != nil {
            return true
        }
        return run(script: GhosttyScript.activate) != nil
    }

    private func tabTTYs() -> Set<String> {
        guard let list = run(script: GhosttyScript.ttys), list.numberOfItems > 0 else {
            return []
        }
        // AppleScript lists are 1-based.
        return Set((1...list.numberOfItems).compactMap { list.atIndex($0)?.stringValue })
    }

    private func run(script: String) -> NSAppleEventDescriptor? {
        guard let apple = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = apple.executeAndReturnError(&error)
        if let error {
            NSLog("scoreboard: ghostty jump failed: \(error)")
            return nil
        }
        return result
    }
}

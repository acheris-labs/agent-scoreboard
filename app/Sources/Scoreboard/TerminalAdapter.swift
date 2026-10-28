import Foundation

// Terminal adapters: everything terminal-app-specific lives behind this.
// An event's `origin` names the terminal app ({"kind": ...}); the matching
// adapter finds the session's tab from its pid. Adding a terminal app = one
// new adapter file registered here, plus a case in TerminalCapture.
@MainActor
protocol TerminalAdapter {
    static var kind: String { get }
    // Focus the terminal running this pid/cwd. Returns false if it couldn't.
    func jump(pid: Int32, cwd: String) -> Bool
}

@MainActor
enum TerminalAdapters {
    private static let all: [String: any TerminalAdapter] = [
        GhosttyAdapter.kind: GhosttyAdapter()
    ]

    static func jump(origin: [String: String]?, pid: Int32, cwd: String) {
        // No origin (SessionStart was missed): try every adapter until one lands.
        guard let kind = origin?["kind"] else {
            for adapter in all.values where adapter.jump(pid: pid, cwd: cwd) {
                return
            }
            return
        }
        _ = all[kind]?.jump(pid: pid, cwd: cwd)
    }
}

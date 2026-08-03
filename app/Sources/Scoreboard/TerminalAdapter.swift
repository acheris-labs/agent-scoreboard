import Foundation

// Terminal adapters: everything terminal-app-specific lives behind this.
// An event's `origin` is an opaque dict keyed by "kind"; only the matching
// adapter interprets the rest. Adding a terminal app = one new adapter file
// registered here (mirrors cli/src/scoreboard/terminals/).
@MainActor
protocol TerminalAdapter {
    static var kind: String { get }
    // Focus the terminal for this origin/cwd. Returns false if it couldn't.
    func jump(origin: [String: String], cwd: String) -> Bool
}

@MainActor
enum TerminalAdapters {
    private static let all: [String: any TerminalAdapter] = [
        GhosttyAdapter.kind: GhosttyAdapter()
    ]

    static func jump(origin: [String: String]?, cwd: String) {
        // No origin: try every adapter's cwd fallback until one lands.
        guard let origin, let kind = origin["kind"] else {
            for adapter in all.values where adapter.jump(origin: [:], cwd: cwd) {
                return
            }
            return
        }
        _ = all[kind]?.jump(origin: origin, cwd: cwd)
    }
}

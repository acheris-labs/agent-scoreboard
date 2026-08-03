import Foundation

// Terminal adapters, CLI side: turning "which terminal is the user in" into an
// opaque origin dict that only the matching app-side adapter interprets.
// Adding a terminal app means one adapter here and one in the app.
public protocol TerminalCaptureAdapter {
    static var kind: String { get }
    static func detect(_ environment: [String: String]) -> Bool
    /// Origin of the terminal the user is typing in right now, if certain.
    func captureOrigin() -> [String: String]?
    /// Every terminal as (origin, workingDirectory), for `refresh`.
    func listOrigins() -> [(origin: [String: String], cwd: String)]
}

public enum TerminalCapture {
    public static let adapters: [any TerminalCaptureAdapter.Type] = [GhosttyCapture.self]

    public static func detect(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (any TerminalCaptureAdapter)? {
        for adapter in adapters where adapter.detect(environment) {
            return GhosttyCapture()
        }
        return nil
    }

    public static func captureOrigin() -> [String: String]? {
        detect()?.captureOrigin()
    }

    public static func allOrigins() -> [(origin: [String: String], cwd: String)] {
        adapters.flatMap { _ in GhosttyCapture().listOrigins() }
    }
}

// Ghostty (>= 1.3) gives every terminal surface a stable UUID in its
// scripting dictionary. Origin: ["kind": "ghostty", "terminal_id": <uuid>].
public struct GhosttyCapture: TerminalCaptureAdapter {
    public static let kind = "ghostty"

    public init() {}

    public static func detect(_ environment: [String: String]) -> Bool {
        environment["TERM_PROGRAM"] == "ghostty"
    }

    // The focused terminal of the front window is where the user just typed.
    // The frontmost guard means we never capture when the prompt did not come
    // from a foreground Ghostty tab - better no origin than a wrong one.
    private static let captureScript = """
        tell application "Ghostty"
            if frontmost then
                get id of focused terminal of selected tab of front window
            end if
        end tell
        """

    // Ids, a blank separator line, then working directories in the same order.
    private static let listScript = """
        tell application "Ghostty"
            set ids to id of every terminal
            set cwds to working directory of every terminal
        end tell
        set out to ""
        repeat with i in ids
            set out to out & i & linefeed
        end repeat
        set out to out & linefeed
        repeat with c in cwds
            set out to out & c & linefeed
        end repeat
        return out
        """

    public func captureOrigin() -> [String: String]? {
        guard let id = Self.osascript(Self.captureScript), !id.isEmpty else { return nil }
        return ["kind": Self.kind, "terminal_id": id]
    }

    public func listOrigins() -> [(origin: [String: String], cwd: String)] {
        guard let out = Self.osascript(Self.listScript) else { return [] }
        let parts = out.components(separatedBy: "\n\n")
        guard parts.count >= 2 else { return [] }
        let ids = parts[0].split(separator: "\n").map(String.init)
        let cwds = parts[1].split(separator: "\n").map(String.init)
        guard ids.count == cwds.count else { return [] }
        return zip(ids, cwds).map {
            (["kind": Self.kind, "terminal_id": $0.0], $0.1)
        }
    }

    // Runs osascript out of process: NSAppleScript would drag AppKit and a
    // main-thread requirement into a CLI that must stay fast and headless.
    static func osascript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

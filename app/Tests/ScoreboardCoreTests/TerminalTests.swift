import Foundation
import XCTest

@testable import ScoreboardCore

final class TerminalCaptureTests: XCTestCase {
    func testGhosttyDetectedFromEnvironment() {
        XCTAssertEqual(TerminalCapture.origin(["TERM_PROGRAM": "ghostty"]), ["kind": "ghostty"])
    }

    func testUnknownTerminalHasNoOrigin() {
        XCTAssertNil(TerminalCapture.origin(["TERM_PROGRAM": "tmux"]))
        XCTAssertNil(TerminalCapture.origin([:]))
    }
}

final class ProcessTTYTests: XCTestCase {
    func testNoTTYForMissingProcess() {
        XCTAssertNil(ProcessTTY.path(of: 0))
        XCTAssertNil(ProcessTTY.path(of: -1))
        XCTAssertNil(ProcessTTY.path(of: Int32.max))
    }

    // `ps` is the reference: whatever tty it reports, or none ("??").
    // Checks this process and its parent so that, run from a terminal, at
    // least one of them has a real tty.
    func testMatchesPs() throws {
        for pid in [getpid(), getppid()] {
            XCTAssertEqual(ProcessTTY.path(of: pid), try psTTY(pid), "pid \(pid)")
        }
    }

    private func psTTY(_ pid: Int32) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let name = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "??" ? nil : "/dev/" + name
    }
}

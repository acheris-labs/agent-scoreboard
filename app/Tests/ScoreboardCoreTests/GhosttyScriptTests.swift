import XCTest

@testable import ScoreboardCore

// A session's working directory comes from a directory name on disk, which can
// come from a repo you cloned, and it is interpolated into a script that gets
// executed. Escaping is what keeps that inert, so pin its behaviour.
final class GhosttyScriptTests: XCTestCase {
    func testEscapesQuotes() {
        XCTAssertEqual(GhosttyScript.escape("a\"b"), "a\\\"b")
    }

    func testEscapesBackslashes() {
        XCTAssertEqual(GhosttyScript.escape("a\\b"), "a\\\\b")
    }

    // Backslashes must be escaped before quotes. The other order turns a lone
    // quote into \\" - a closed escape followed by a live quote - which ends
    // the literal and is exactly the bug this test exists to catch.
    func testBackslashBeforeQuoteOrdering() {
        XCTAssertEqual(GhosttyScript.escape("\\\""), "\\\\\\\"")
    }

    func testLeavesOrdinaryPathsAlone() {
        let path = "/Users/chris/src/agent-scoreboard"
        XCTAssertEqual(GhosttyScript.escape(path), path)
    }

    // A hostile value must not add any quote that delimits a literal.
    // Compared against a benign value rather than a fixed number, so the
    // assertion holds even if the script template gains a quoted word.
    private func assertContributesNoQuotes(
        _ value: String, _ build: (String) -> String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let baseline = unescapedQuoteCount(in: build("benign"))
        XCTAssertEqual(
            unescapedQuoteCount(in: build(value)), baseline,
            "value introduced a literal-delimiting quote", file: file, line: line)
    }

    // The payload that would run a shell command if the literal could be
    // closed.
    func testInjectionPayloadCannotCloseTheLiteral() {
        let payload = "x\" & (do shell script \"touch /tmp/PWNED\") & \""
        assertContributesNoQuotes(payload) { GhosttyScript.focus(terminalID: $0) }
        // The command survives only as inert text, never as live syntax.
        XCTAssertFalse(GhosttyScript.focus(terminalID: payload).contains("do shell script \""))
    }

    func testInjectionViaWorkingDirectoryCannotCloseTheLiteral() {
        let payload = "/tmp/evil\" & (do shell script \"touch /tmp/PWNED\") & \""
        assertContributesNoQuotes(payload) { GhosttyScript.focus(workingDirectory: $0) }
    }

    // A trailing backslash is the classic escape-the-escape attack: if it were
    // not doubled it would consume the template's own closing quote.
    func testTrailingBackslashCannotEscapeTheClosingQuote() {
        assertContributesNoQuotes("abc\\") { GhosttyScript.focus(terminalID: $0) }
    }

    // Filenames may contain newlines. That yields no match rather than a
    // second statement, so the value must stay within the one literal.
    func testNewlineStaysInsideTheLiteral() {
        assertContributesNoQuotes("/tmp/a\nb") { GhosttyScript.focus(workingDirectory: $0) }
    }

    /// Quotes that actually delimit a literal: a quote preceded by an even
    /// number of backslashes.
    private func unescapedQuoteCount(in script: String) -> Int {
        var count = 0
        var backslashes = 0
        for character in script {
            if character == "\\" {
                backslashes += 1
            } else {
                if character == "\"", backslashes % 2 == 0 { count += 1 }
                backslashes = 0
            }
        }
        return count
    }
}

import XCTest

@testable import ScoreboardCore

final class HistoryReportTests: XCTestCase {
    let now = 1_000_000.0

    func entry(_ ago: Double, _ session: String, _ state: String) -> HistoryEntry {
        HistoryEntry(ts: now - ago, session: session, state: state)
    }

    // The example from the design: 12:00-12:10 and 12:05-12:15 is 20 minutes.
    func testOverlappingSessionsSum() {
        let entries = [
            entry(900, "a", "running"), entry(300, "a", "ended"),
            entry(600, "b", "running"), entry(0, "b", "ended"),
        ]
        let report = HistoryReport(entries: entries, range: .hour, now: now)
        XCTAssertEqual(report.running, 1200, accuracy: 0.001)
        XCTAssertEqual(report.peakSessions, 2)
        // Wall clock: 15 minutes running, measured from the first line.
        XCTAssertEqual(report.active!, 1.0, accuracy: 0.001)
    }

    func testBucketsAreAgentsWorth() {
        // Two sessions running through the whole last minute.
        let entries = [entry(120, "a", "running"), entry(120, "b", "running")]
        let report = HistoryReport(entries: entries, range: .hour, now: now)
        XCTAssertEqual(report.buckets.count, 60)
        XCTAssertEqual(report.buckets.last!.running, 2, accuracy: 0.001)
        XCTAssertEqual(report.buckets.last!.sessions, 2, accuracy: 0.001)
        XCTAssertEqual(report.buckets.first!.running, 0)
    }

    func testIdleIsNotCountedButKeepsSessionOpen() {
        let entries = [entry(600, "a", "running"), entry(300, "a", "idle")]
        let report = HistoryReport(entries: entries, range: .hour, now: now)
        XCTAssertEqual(report.running, 300, accuracy: 0.001)
        XCTAssertEqual(report.waiting, 0)
        XCTAssertEqual(report.buckets.last!.sessions, 1, accuracy: 0.001)
        XCTAssertEqual(report.buckets.last!.running, 0)
    }

    func testStatesSplitAcrossBuckets() {
        // Waiting 30s into one minute bucket and 30s into the next.
        let entries = [entry(90, "a", "waiting"), entry(30, "a", "error")]
        let report = HistoryReport(entries: entries, range: .hour, now: now)
        let n = report.buckets.count
        XCTAssertEqual(report.buckets[n - 2].waiting, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.buckets[n - 1].waiting, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.buckets[n - 1].error, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.waiting, 60, accuracy: 0.001)
        XCTAssertEqual(report.error, 30, accuracy: 0.001)
    }

    func testClipsToRange() {
        // Started two hours ago and still running: only the last hour counts.
        let report = HistoryReport(
            entries: [entry(7200, "a", "running")], range: .hour, now: now)
        XCTAssertEqual(report.running, 3600, accuracy: 0.001)
        XCTAssertEqual(report.peakSessions, 1)
        XCTAssertEqual(report.active!, 1, accuracy: 0.001)
    }

    func testActiveCountsFromFirstLine() {
        // Logging began 10 minutes ago; 5 of them had something running.
        let entries = [entry(600, "a", "waiting"), entry(300, "a", "running")]
        let report = HistoryReport(entries: entries, range: .month, now: now)
        XCTAssertEqual(report.active!, 0.5, accuracy: 0.001)
    }

    func testNoHistory() {
        let report = HistoryReport(entries: [], range: .week, now: now)
        XCTAssertNil(report.active)
        XCTAssertEqual(report.peakSessions, 0)
        XCTAssertEqual(report.buckets.count, 168)
    }

    func testHandOffIsNotAnOverlap() {
        let entries = [
            entry(600, "a", "running"), entry(300, "a", "ended"),
            entry(300, "b", "running"),
        ]
        XCTAssertEqual(HistoryReport(entries: entries, range: .hour, now: now).peakSessions, 1)
    }

    func testBucketCounts() {
        let counts = HistoryRange.allCases.map {
            HistoryReport(entries: [], range: $0, now: now).buckets.count
        }
        XCTAssertEqual(counts, [60, 96, 168, 120])
    }
}

final class HistoryLogTests: XCTestCase {
    var root: URL!
    var log: HistoryLog!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scoreboard-history-\(UUID().uuidString)")
        log = HistoryLog(
            path: root.appendingPathComponent("state/history.ndjson").path,
            alivePath: root.appendingPathComponent("state/history.alive").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAppendReadSkipsBadLines() throws {
        log.append([HistoryEntry(ts: 1, session: "a", state: "running")])
        let handle = FileHandle(forWritingAtPath: log.path)!
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{torn\n".utf8))
        try handle.close()
        log.append([HistoryEntry(ts: 2, session: "a", state: "ended")])
        XCTAssertEqual(log.read().map(\.ts), [1, 2])
    }

    func testPrune() {
        log.append([
            HistoryEntry(ts: 1, session: "a", state: "running"),
            HistoryEntry(ts: 5, session: "a", state: "ended"),
        ])
        log.prune(olderThan: 3)
        XCTAssertEqual(log.read().map(\.ts), [5])
        log.prune(olderThan: 10)
        XCTAssertEqual(log.read(), [])
    }

    func testRecorderSkipsRepeats() {
        let recorder = HistoryRecorder(log: log)
        recorder.record(session: "a", state: "running", at: 1)
        recorder.record(session: "a", state: "running", at: 2)
        recorder.record(session: "a", state: "waiting", at: 3)
        recorder.record(session: "b", state: "ended", at: 4)  // never opened
        XCTAssertEqual(log.read().map(\.ts), [1, 3])
    }

    func testCloseAllThenReopen() {
        let recorder = HistoryRecorder(log: log)
        recorder.record(session: "a", state: "running", at: 1)
        recorder.record(session: "b", state: "idle", at: 2)
        recorder.closeAll(at: 10)
        recorder.record(session: "a", state: "running", at: 20)
        XCTAssertEqual(
            log.read().map { "\($0.session) \($0.state) \(Int($0.ts))" },
            ["a running 1", "b idle 2", "a ended 10", "b ended 10", "a running 20"])
    }

    // After a crash the log's open sessions end at the last sign of life,
    // or at their own last line if that came later.
    func testRecoverClosesDanglingSessions() throws {
        log.append([
            HistoryEntry(ts: 100, session: "a", state: "running"),
            HistoryEntry(ts: 200, session: "b", state: "running"),
            HistoryEntry(ts: 210, session: "b", state: "ended"),
            HistoryEntry(ts: 400, session: "c", state: "waiting"),
        ])
        log.touchAlive()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: log.alivePath)
        HistoryRecorder(log: log).recover()
        let ended = log.read().suffix(2).map { "\($0.session) \($0.state) \(Int($0.ts))" }
        XCTAssertEqual(ended, ["a ended 300", "c ended 400"])
    }
}

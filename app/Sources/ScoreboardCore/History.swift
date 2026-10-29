import Foundation

// The time-in-state history behind Show Details: an append-only log of
// session state changes, and the bucketing that turns it into a chart.

public struct HistoryEntry: Codable, Equatable {
    public let ts: Double  // epoch seconds
    public let session: String
    public let state: String  // running, waiting, error, idle or ended

    public init(ts: Double, session: String, state: String) {
        self.ts = ts
        self.session = session
        self.state = state
    }
}

public struct HistoryLog {
    public let path: String
    public let alivePath: String

    public init(path: String, alivePath: String) {
        self.path = path
        self.alivePath = alivePath
    }

    public static let standard = HistoryLog(path: Paths.history, alivePath: Paths.historyAlive)

    // Lines that don't parse are skipped: a torn write must not hide the rest.
    public func read() -> [HistoryEntry] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(HistoryEntry.self, from: Data($0.utf8))
        }
    }

    public func append(_ entries: [HistoryEntry]) {
        guard !entries.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        do {
            try ensureDirectory()
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: URL(fileURLWithPath: path))
            }
        } catch {
            NSLog("scoreboard: history append failed: \(error)")
        }
    }

    // Rewrites the file without entries older than `cutoff`, via a temp file
    // and rename so a crash mid-prune never truncates the history.
    public func prune(olderThan cutoff: Double) {
        let entries = read()
        let kept = entries.filter { $0.ts >= cutoff }
        guard kept.count < entries.count else { return }
        let tmp = path + ".tmp"
        try? FileManager.default.removeItem(atPath: tmp)
        HistoryLog(path: tmp, alivePath: alivePath).append(kept)
        if kept.isEmpty { FileManager.default.createFile(atPath: tmp, contents: Data()) }
        do {
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
        } catch {
            NSLog("scoreboard: history prune failed: \(error)")
        }
    }

    public func touchAlive() {
        try? ensureDirectory()
        FileManager.default.createFile(atPath: alivePath, contents: Data())
    }

    public func aliveTime() -> Double? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: alivePath)
        return (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
    }
}

// Writes a line only when a session's state actually changes: hooks repeat
// the current state constantly (running on every tool call).
public final class HistoryRecorder {
    public let log: HistoryLog
    // Last state logged per open session; ended sessions are dropped.
    private var last: [String: String] = [:]

    public init(log: HistoryLog) {
        self.log = log
    }

    // Call once at launch, before anything is recorded. A crash or kill skips
    // the clean close, so sessions the log still has open are ended at the
    // last sign of life: never later, or the downtime would be counted.
    public func recover() {
        var open: [String: Double] = [:]
        for entry in log.read() {
            if entry.state == "ended" {
                open.removeValue(forKey: entry.session)
            } else {
                open[entry.session] = max(open[entry.session] ?? 0, entry.ts)
            }
        }
        let alive = log.aliveTime() ?? 0
        log.append(open.sorted { $0.key < $1.key }.map { session, lastTs in
            HistoryEntry(ts: max(alive, lastTs), session: session, state: "ended")
        })
        last = [:]
    }

    public func record(session: String, state: String, at ts: Double) {
        guard (last[session] ?? "ended") != state else { return }
        if state == "ended" {
            last.removeValue(forKey: session)
        } else {
            last[session] = state
        }
        log.append([HistoryEntry(ts: ts, session: session, state: state)])
    }

    // For quit and sleep: time we can't see must not be counted.
    public func closeAll(at ts: Double) {
        for session in last.keys.sorted() {
            record(session: session, state: "ended", at: ts)
        }
    }
}

public enum HistoryRange: Int, CaseIterable {
    case hour, workday, day, week, month

    public var span: Double {
        switch self {
        case .hour: return 3600
        case .workday: return 12 * 3600
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        }
    }

    public var bucket: Double {
        switch self {
        case .hour: return 60
        case .workday: return 5 * 60
        case .day: return 15 * 60
        case .week: return 3600
        case .month: return 6 * 3600
        }
    }

    public var title: String {
        switch self {
        case .hour: return "Last hour"
        case .workday: return "Last 12 hours"
        case .day: return "Last 24 hours"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        }
    }

    public static let retention = HistoryRange.month.span
}

public struct HistoryBucket: Equatable {
    public let start: Double
    // Agents' worth in each state over the bucket: seconds / bucket length,
    // summed across sessions, so two sessions running flat out read 2.
    public var running = 0.0
    public var waiting = 0.0
    public var error = 0.0
    public var sessions = 0.0  // open sessions, idle included
}

public struct HistoryReport {
    public let range: HistoryRange
    public let start: Double
    public let end: Double
    public let buckets: [HistoryBucket]
    // Seconds, summed across sessions.
    public let running: Double
    public let waiting: Double
    public let error: Double
    public let idle: Double  // open with the lamp off
    // Most sessions open at once (idle included), and most not idle.
    public let peakSessions: Int
    public let peakActive: Int
    // Wall-clock share of the range with at least one session running,
    // counted from when logging began. nil before there is any history.
    public let active: Double?

    public init(entries: [HistoryEntry], range: HistoryRange, now: Double) {
        self.range = range
        let start = now - range.span
        end = now
        self.start = start
        let count = Int((range.span / range.bucket).rounded())
        var buckets = (0..<count).map { HistoryBucket(start: start + Double($0) * range.bucket) }

        var totals = ["running": 0.0, "waiting": 0.0, "error": 0.0, "idle": 0.0]
        var openEdges: [(Double, Int)] = []  // +1 / -1 as sessions open and close
        var activeEdges: [(Double, Int)] = []  // the same, for stretches not idle
        var runningSpans: [(Double, Double)] = []

        let bySession = Dictionary(grouping: entries, by: \.session)
        for (_, list) in bySession {
            let list = list.sorted { $0.ts < $1.ts }
            var openSince: Double?
            for (i, entry) in list.enumerated() {
                let until = i + 1 < list.count ? list[i + 1].ts : now
                if entry.state == "ended" {
                    if let since = openSince { openEdges += [(since, 1), (entry.ts, -1)] }
                    openSince = nil
                    continue
                }
                if openSince == nil { openSince = entry.ts }
                if entry.state != "idle" { activeEdges += [(entry.ts, 1), (until, -1)] }
                let lo = max(entry.ts, start)
                let hi = min(until, now)
                guard hi > lo else { continue }
                Self.spread(lo, hi, range: range, start: start, into: &buckets) { bucket, seconds in
                    bucket.sessions += seconds
                    switch entry.state {
                    case "running": bucket.running += seconds
                    case "waiting": bucket.waiting += seconds
                    case "error": bucket.error += seconds
                    default: break
                    }
                }
                if totals[entry.state] != nil { totals[entry.state]! += hi - lo }
                if entry.state == "running" { runningSpans.append((lo, hi)) }
            }
            if let since = openSince { openEdges += [(since, 1), (now, -1)] }
        }

        for i in buckets.indices {
            buckets[i].running /= range.bucket
            buckets[i].waiting /= range.bucket
            buckets[i].error /= range.bucket
            buckets[i].sessions /= range.bucket
        }
        self.buckets = buckets
        running = totals["running"]!
        waiting = totals["waiting"]!
        error = totals["error"]!
        idle = totals["idle"]!
        peakSessions = Self.peak(openEdges, from: start, to: now)
        peakActive = Self.peak(activeEdges, from: start, to: now)

        if let first = entries.map(\.ts).min(), first < now {
            let from = max(start, first)
            active = Self.unionLength(runningSpans, from: from, to: now) / (now - from)
        } else {
            active = nil
        }
    }

    // Adds each bucket's share of [lo, hi) via `add`.
    private static func spread(
        _ lo: Double, _ hi: Double, range: HistoryRange, start: Double,
        into buckets: inout [HistoryBucket], add: (inout HistoryBucket, Double) -> Void
    ) {
        guard !buckets.isEmpty else { return }
        var i = max(0, min(buckets.count - 1, Int((lo - start) / range.bucket)))
        while i < buckets.count {
            let bLo = buckets[i].start
            let bHi = bLo + range.bucket
            if bLo >= hi { break }
            let overlap = min(hi, bHi) - max(lo, bLo)
            if overlap > 0 { add(&buckets[i], overlap) }
            i += 1
        }
    }

    // Most sessions open at once within [from, to]. Closes sort before opens
    // at the same instant, so a hand-off isn't counted as an overlap.
    private static func peak(_ edges: [(Double, Int)], from: Double, to: Double) -> Int {
        var current = 0
        var best: Int?  // nil until the range starts; then seeded with whoever is open
        for (ts, delta) in edges.sorted(by: { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }) {
            if ts > to { break }
            if ts >= from, best == nil { best = current }
            current += delta
            if ts >= from { best = max(best!, current) }
        }
        return max(best ?? current, 0)
    }

    private static func unionLength(_ spans: [(Double, Double)], from: Double, to: Double)
        -> Double
    {
        var total = 0.0
        var cursor = from
        for (lo, hi) in spans.sorted(by: { $0.0 < $1.0 }) {
            let a = max(lo, cursor)
            let b = min(hi, to)
            if b > a {
                total += b - a
                cursor = b
            }
        }
        return total
    }
}

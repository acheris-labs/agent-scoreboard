import AppKit
import ScoreboardCore

// Show Details: how much agent time went to running (you waiting on them),
// waiting (them waiting on you) and error, summed across sessions like CPU
// time across cores. The look follows ../tracker's chart window.

// MARK: - Chart

final class DetailsChartView: NSView {
    var report: HistoryReport? {
        didSet { needsDisplay = true }
    }

    // Tracker's band styling.
    private static let bandAlphaTop: CGFloat = 0.80
    private static let bandAlphaBottom: CGFloat = 0.30
    private static let bandLift: CGFloat = 0.15
    private static let bandEdgeWidth: CGFloat = 1.25

    private static let axisFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    override var isFlipped: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let light = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
        let card = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor.textBackgroundColor.setFill()
        card.fill()
        NSColor.separatorColor.setStroke()
        card.lineWidth = 1
        card.stroke()

        guard let report else { return }
        let plot = NSRect(
            x: bounds.minX + 40, y: bounds.minY + 24,
            width: bounds.width - 40 - 16, height: bounds.height - 24 - 14)
        guard plot.width > 20, plot.height > 20 else { return }

        let buckets = report.buckets
        let stackMax = buckets.map { $0.running + $0.waiting + $0.error }.max() ?? 0
        let sessionMax = buckets.map(\.sessions).max() ?? 0
        let yMax = max(1, ceil(max(stackMax, sessionMax) * 1.05))
        let y = { (v: Double) in plot.minY + CGFloat(v / yMax) * plot.height }

        drawGrid(plot: plot, yMax: yMax, y: y)
        drawTimeAxis(plot: plot, report: report)

        guard report.active != nil else {
            drawEmpty(in: plot)
            return
        }

        let colW = plot.width / CGFloat(buckets.count)
        let x = { (i: Int) in plot.minX + (CGFloat(i) + 0.5) * colW }
        var tops = [[NSPoint]](repeating: [], count: 4)
        for (i, b) in buckets.enumerated() {
            let levels = [0, b.running, b.running + b.waiting, b.running + b.waiting + b.error]
            for k in 0..<4 { tops[k].append(NSPoint(x: x(i), y: y(levels[k]))) }
        }

        NSGraphicsContext.current?.cgContext.saveGState()
        // Clip at the floor (splines overshoot below zero) but not the top.
        NSBezierPath(rect: NSRect(x: plot.minX, y: plot.minY, width: plot.width, height: plot.height + 4)).addClip()
        let bands: [(StatusLevel, (HistoryBucket) -> Double)] = [
            (.running, \.running), (.waiting, \.waiting), (.error, \.error),
        ]
        for (k, (level, value)) in bands.enumerated() where buckets.contains(where: { value($0) > 0 }) {
            // Alpha pulls a fill toward the background, so compensate away
            // from it: lift toward white on dark, darken on light.
            let base = light ? Self.legibleOnLight(level.color) : level.color
            let c = light ? Self.darkened(base, by: Self.bandLift) : Self.lifted(base, by: Self.bandLift)
            Self.fillVertical(
                Self.ribbon(upper: tops[k + 1], lower: tops[k]),
                top: c.withAlphaComponent(Self.bandAlphaTop),
                bottom: c.withAlphaComponent(Self.bandAlphaBottom))
            // Stroke the top edge only where the band has thickness: a
            // zero-height band would otherwise paint its colour along the
            // floor, or over the top of the bands beneath it.
            c.setStroke()
            for run in Self.runs(where: { value(buckets[$0]) > 0.001 }, count: buckets.count) {
                let edge = Self.smoothPath(Array(tops[k + 1][run]))
                edge.lineWidth = Self.bandEdgeWidth
                edge.lineJoinStyle = .round
                edge.stroke()
            }
        }

        // Sessions: one line per run of buckets with any session open, rising
        // from the floor and falling back to it, with gaps between runs
        // rather than a line along the floor.
        let lineColor = light ? NSColor(white: 0.25, alpha: 0.9) : NSColor(white: 0.95, alpha: 0.9)
        lineColor.setStroke()
        let sessionPoints = buckets.enumerated().map { NSPoint(x: x($0), y: y($1.sessions)) }
        for run in Self.runs(where: { buckets[$0].sessions > 0.001 }, count: buckets.count) {
            let path = Self.smoothPath(Array(sessionPoints[run]))
            path.lineWidth = 2
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
        }
        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    private func drawGrid(plot: NSRect, yMax: Double, y: (Double) -> CGFloat) {
        let step = yMax <= 6 ? 1.0 : ceil(yMax / 5)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.axisFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        var v = 0.0
        while v <= yMax + 0.001 {
            let yy = y(v)
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: yy))
            line.line(to: NSPoint(x: plot.maxX, y: yy))
            line.lineWidth = 0.5
            line.stroke()
            let label = NSAttributedString(string: "\(Int(v))", attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: plot.minX - 8 - size.width, y: yy - size.height / 2))
            v += step
        }
    }

    private func drawTimeAxis(plot: NSRect, report: HistoryReport) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.axisFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let span = report.end - report.start
        for (time, text) in Self.ticks(for: report.range, from: report.start, to: report.end) {
            let x = plot.minX + CGFloat((time - report.start) / span) * plot.width
            let label = NSAttributedString(string: text, attributes: attributes)
            let size = label.size()
            let lx = min(max(x - size.width / 2, plot.minX), plot.maxX - size.width)
            label.draw(at: NSPoint(x: lx, y: plot.minY - 6 - size.height))
            NSColor.separatorColor.withAlphaComponent(0.25).setStroke()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: x, y: plot.minY))
            tick.line(to: NSPoint(x: x, y: plot.maxY))
            tick.lineWidth = 0.5
            tick.stroke()
        }
    }

    // Tick marks on local-calendar boundaries: every 10 minutes, every 3
    // hours, every midnight, every 5th day.
    private static func ticks(for range: HistoryRange, from: Double, to: Double)
        -> [(Double, String)]
    {
        let calendar = Calendar.current
        let start = Date(timeIntervalSince1970: from)
        let formatter = DateFormatter()
        var component: Calendar.Component
        var step: Int
        var first: Date
        switch range {
        case .hour:
            component = .minute
            step = 10
            formatter.dateFormat = "HH:mm"
            let c = calendar.dateComponents([.year, .month, .day, .hour], from: start)
            first = calendar.date(from: c)!
        case .day:
            component = .hour
            step = 3
            formatter.dateFormat = "HH:mm"
            first = calendar.startOfDay(for: start)
        case .week:
            component = .day
            step = 1
            formatter.dateFormat = "EEE"
            first = calendar.startOfDay(for: start)
        case .month:
            component = .day
            step = 5
            formatter.dateFormat = "MMM d"
            first = calendar.startOfDay(for: start)
        }
        var ticks: [(Double, String)] = []
        var date = first
        while date.timeIntervalSince1970 <= to {
            let t = date.timeIntervalSince1970
            if t >= from { ticks.append((t, formatter.string(from: date))) }
            guard let next = calendar.date(byAdding: component, value: step, to: date) else { break }
            date = next
        }
        return ticks
    }

    private func drawEmpty(in plot: NSRect) {
        let text = NSAttributedString(
            string: "No history yet. Scoreboard records from now on.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
            ])
        let size = text.size()
        text.draw(at: NSPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2))
    }

    // Index ranges where `test` holds, widened by one on each side so a run's
    // curve rises from, and falls back to, its neighbours.
    private static func runs(where test: (Int) -> Bool, count: Int) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        var i = 0
        while i < count {
            guard test(i) else {
                i += 1
                continue
            }
            var j = i
            while j + 1 < count, test(j + 1) { j += 1 }
            result.append(max(0, i - 1)...min(count - 1, j + 1))
            i = j + 1
        }
        return result
    }

    // MARK: Drawing helpers, from Tracker's HistoryRenderer

    private static func lifted(_ color: NSColor, by amount: CGFloat) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        func f(_ v: CGFloat) -> CGFloat { min(1, v + (1 - v) * amount) }
        return NSColor(
            srgbRed: f(c.redComponent), green: f(c.greenComponent), blue: f(c.blueComponent),
            alpha: c.alphaComponent)
    }

    private static func darkened(_ color: NSColor, by amount: CGFloat) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        func f(_ v: CGFloat) -> CGFloat { max(0, v * (1 - amount)) }
        return NSColor(
            srgbRed: f(c.redComponent), green: f(c.greenComponent), blue: f(c.blueComponent),
            alpha: c.alphaComponent)
    }

    // The lamp colours are tuned for dark; cap brightness so green and amber
    // still read on white.
    private static func legibleOnLight(_ color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * 1.15), brightness: min(b, 0.78), alpha: a)
    }

    // One closed subpath between two curves. Appending a separate path would
    // start a new subpath and fill the upper curve closed along a diagonal.
    private static func ribbon(upper: [NSPoint], lower: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        appendSmooth(upper, to: path, startingWithMove: true)
        appendSmooth(lower.reversed(), to: path, startingWithMove: false)
        path.close()
        return path
    }

    private static func fillVertical(_ path: NSBezierPath, top: NSColor, bottom: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = path.bounds
        guard b.height > 0.5, let gradient = NSGradient(starting: bottom, ending: top) else {
            top.setFill()
            path.fill()
            return
        }
        ctx.saveGState()
        path.addClip()
        gradient.draw(
            from: NSPoint(x: b.midX, y: b.minY), to: NSPoint(x: b.midX, y: b.maxY), options: [])
        ctx.restoreGState()
    }

    private static func smoothPath(_ pts: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        appendSmooth(pts, to: path, startingWithMove: true)
        return path
    }

    // Catmull-Rom spline through the points, as cubic Béziers.
    private static func appendSmooth(
        _ pts: [NSPoint], to path: NSBezierPath, startingWithMove: Bool
    ) {
        func begin(_ p: NSPoint) {
            if startingWithMove { path.move(to: p) } else { path.line(to: p) }
        }
        guard pts.count > 2 else {
            if let p = pts.first { begin(p) }
            if pts.count == 2 { path.line(to: pts[1]) }
            return
        }
        begin(pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            path.curve(
                to: p2,
                controlPoint1: NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                controlPoint2: NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
    }
}

// MARK: - Footer

// A bordered pane: small-caps caption over one dot / label / value row.
final class DetailsPane: NSView {
    private let value = NSTextField(labelWithString: "—")

    init(caption: String, label: String, color: NSColor?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        applyBorderColor()

        let captionField = NSTextField(labelWithString: "")
        captionField.attributedStringValue = NSAttributedString(
            string: caption.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
            ])
        captionField.alignment = .center

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 11)
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.alignment = .right

        var rowViews: [NSView] = []
        if let color {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = 4.5
            dot.widthAnchor.constraint(equalToConstant: 9).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 9).isActive = true
            rowViews.append(dot)
        }
        rowViews += [labelField, value]
        let row = NSStackView(views: rowViews)
        row.spacing = 6
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.setCustomSpacing(16, after: labelField)

        let stack = NSStackView(views: [captionField, row])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func set(_ text: String) { value.stringValue = text }

    // A CGColor is resolved once, so re-take it when the appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
    }

    private func applyBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

// MARK: - Window

@MainActor
final class DetailsWindowController: NSObject, NSWindowDelegate {
    private static let rangeKey = "detailsRange"

    private var window: NSWindow?
    private let chart = DetailsChartView()
    private let picker = NSSegmentedControl(
        labels: HistoryRange.allCases.map(\.title), trackingMode: .selectOne, target: nil,
        action: nil)
    private let runningPane = DetailsPane(
        caption: "Running", label: "You waited", color: StatusLevel.running.color)
    private let waitingPane = DetailsPane(
        caption: "Waiting", label: "They waited", color: StatusLevel.waiting.color)
    private let errorPane = DetailsPane(
        caption: "Error", label: "Errored", color: StatusLevel.error.color)
    private let sessionsPane = DetailsPane(caption: "Sessions", label: "Peak", color: .labelColor)
    private let activePane = DetailsPane(caption: "Active", label: "Agents running", color: nil)
    private var minuteTimer: Timer?
    private var reloadPending = false

    var isVisible: Bool { window?.isVisible == true }

    private var range: HistoryRange {
        HistoryRange(rawValue: picker.selectedSegment) ?? .day
    }

    func show() {
        if window == nil { build() }
        reload()
        if minuteTimer == nil {
            minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // Sessions change on every hook; coalesce so a busy minute rereads the
    // log once a second at most.
    func setNeedsReload() {
        guard isVisible, !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.reload()
        }
    }

    func windowWillClose(_ notification: Notification) {
        minuteTimer?.invalidate()
        minuteTimer = nil
    }

    private func reload() {
        let report = HistoryReport(
            entries: HistoryLog.standard.read(), range: range, now: Date().timeIntervalSince1970)
        chart.report = report
        runningPane.set(Self.duration(report.running))
        waitingPane.set(Self.duration(report.waiting))
        errorPane.set(Self.duration(report.error))
        sessionsPane.set("\(report.peakSessions)")
        activePane.set(report.active.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
    }

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegment, forKey: Self.rangeKey)
        reload()
    }

    private func build() {
        let saved = UserDefaults.standard.object(forKey: Self.rangeKey) as? Int
        picker.selectedSegment = HistoryRange(rawValue: saved ?? -1)?.rawValue ?? HistoryRange.day.rawValue
        picker.target = self
        picker.action = #selector(rangeChanged(_:))

        let footer = NSStackView(views: [runningPane, waitingPane, errorPane, sessionsPane, activePane])
        footer.spacing = 10
        footer.distribution = .fillEqually

        chart.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [picker, chart, footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        NSLayoutConstraint.activate([
            chart.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            chart.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Scoreboard Details"
        window.contentView = stack
        window.contentMinSize = NSSize(width: 820, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("ScoreboardDetails")
        if !window.setFrameUsingName("ScoreboardDetails") { window.center() }
        self.window = window
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return seconds < 1 ? "0m" : "\(Int(seconds))s" }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

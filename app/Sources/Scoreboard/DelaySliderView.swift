import AppKit

/// A small NSView hosted inside an NSMenuItem: label + slider for one of the
/// delays (how long to wait before hiding the icon, or before quitting).
/// Modelled on the same pattern as ../newt.
final class DelaySliderView: NSView {
    private let slider: NSSlider
    private let valueLabel: NSTextField
    private let titleLabel: NSTextField
    private let onChange: (Int) -> Void

    /// Evenly spaced on the slider but logarithmically spaced in time: fine
    /// control over the short delays that matter, coarse over the long ones,
    /// and every stop is a round number rather than 37s or 143s.
    static let stops = [0, 1, 2, 5, 10, 15, 30, 45, 60, 90, 120, 180, 300, 600]

    static var minSeconds: Int { stops.first! }
    static var maxSeconds: Int { stops.last! }

    /// Nearest stop to an arbitrary stored value, so a delay written by an
    /// older build (or by hand) still lands on the slider.
    static func index(forSeconds seconds: Int) -> Int {
        stops.enumerated()
            .min { abs($0.element - seconds) < abs($1.element - seconds) }?.offset ?? 0
    }

    init(title: String, initialValue: Int, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        self.slider = NSSlider(
            value: Double(Self.index(forSeconds: initialValue)),
            minValue: 0, maxValue: Double(Self.stops.count - 1),
            target: nil, action: nil)
        self.valueLabel = NSTextField(labelWithString: "")
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 40))

        let font = NSFont.menuFont(ofSize: 0)
        titleLabel.font = font
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 21, y: 22, width: 180, height: 16)
        addSubview(titleLabel)

        valueLabel.font = font
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.frame = NSRect(x: 186, y: 22, width: 56, height: 16)
        addSubview(valueLabel)

        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.numberOfTickMarks = Self.stops.count
        slider.allowsTickMarkValuesOnly = true
        slider.frame = NSRect(x: 21, y: 3, width: 221, height: 18)
        addSubview(slider)

        updateLabel(Self.stops[Self.index(forSeconds: initialValue)])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let index = min(max(Int(sender.doubleValue.rounded()), 0), Self.stops.count - 1)
        sender.integerValue = index
        let seconds = Self.stops[index]
        updateLabel(seconds)
        onChange(seconds)
    }

    private func updateLabel(_ seconds: Int) {
        switch seconds {
        case 0: valueLabel.stringValue = "at once"
        case ..<60: valueLabel.stringValue = "\(seconds)s"
        case let s where s % 60 == 0: valueLabel.stringValue = "\(s / 60) min"
        default: valueLabel.stringValue = "\(seconds / 60)m \(seconds % 60)s"
        }
    }
}

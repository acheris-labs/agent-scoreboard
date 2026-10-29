import AppKit

// A session state that warrants attention, in priority order: a red error
// outranks a yellow question, which outranks green work in progress.
enum StatusLevel: Int, CaseIterable {
    case running = 0
    case waiting = 1
    case error = 2

    var color: NSColor {
        switch self {
        case .running: return NSColor(red: 0.20, green: 0.84, blue: 0.29, alpha: 1)  // #32D74B
        case .waiting: return NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)  // #FF9F0A
        case .error: return NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)  // #FF453A
        }
    }

    // Text drawn inside a filled badge of this color. Yellow and green are
    // bright enough that dark text reads better than white.
    var badgeTextColor: NSColor {
        switch self {
        case .error: return .white
        case .waiting, .running: return NSColor.black.withAlphaComponent(0.85)
        }
    }
}

// The badge reserves room to the right of the glyph.
let stoplightIconSize = NSSize(width: 22, height: 22)
let badgeIconSize = NSSize(width: 24, height: 22)

// Geometry, in unflipped coordinates (y grows upward).
private let housingRect = NSRect(x: 2.5, y: 0.5, width: 11, height: 21)
private let housingStroke: CGFloat = 1.2
private let lampX: CGFloat = 5
private let lampSize: CGFloat = 6
private let badgeRect = NSRect(x: 11, y: 9.5, width: 11, height: 11)

// Derived rather than hardcoded, so the gap above the top lamp is always the
// same as the gap below the bottom one: four equal spaces (two margins, two
// between lamps) share whatever the three lamps leave inside the housing.
private let lampGap = (housingRect.height - housingStroke - 3 * lampSize) / 4
private let lampFirstY = housingRect.minY + housingStroke / 2 + lampGap
private let lampPitch = lampSize + lampGap

// The menu bar icon: a stoplight whose lamps light for the states present on
// the board, plus a notification bubble on its top-right corner in the
// highest-priority colour (red > yellow > green) carrying that state's count.
// No number when the count is one; with nothing active, a dim template
// outline and no bubble.
@MainActor
func statusItemImage(counts: [StatusLevel: Int]) -> NSImage {
    var badge: (level: StatusLevel, count: Int)?
    if let top = StatusLevel.allCases.reversed().first(where: { (counts[$0] ?? 0) > 0 }) {
        badge = (top, counts[top] ?? 0)
    }
    return iconImage(counts: counts, badge: badge)
}

@MainActor
func iconImage(
    counts: [StatusLevel: Int], badge: (level: StatusLevel, count: Int)?
) -> NSImage {
    let anyLit = counts.values.contains { $0 > 0 }
    let size = badge == nil ? stoplightIconSize : badgeIconSize
    let image = NSImage(size: size, flipped: false) { _ in
        let outline: NSColor = anyLit ? .labelColor : .black

        let housing = NSBezierPath(
            roundedRect: housingRect, xRadius: 5.5, yRadius: 5.5)
        housing.lineWidth = 1.2
        outline.withAlphaComponent(0.9).setStroke()
        housing.stroke()

        // Unflipped, so red (top of the stoplight) has the highest y.
        for (i, level) in [StatusLevel.running, .waiting, .error].enumerated() {
            let rect = NSRect(
                x: lampX, y: lampFirstY + CGFloat(i) * lampPitch,
                width: lampSize, height: lampSize)
            if (counts[level] ?? 0) > 0 {
                level.color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                outline.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            }
        }

        if let badge {
            // Punch a halo so the bubble separates from the glyph the way
            // Control Center badges do, whatever the menu bar tint.
            let context = NSGraphicsContext.current?.cgContext
            context?.setBlendMode(.destinationOut)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.2, dy: -1.2)).fill()
            context?.setBlendMode(.normal)

            badge.level.color.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            if badge.count > 1 {
                // Wider numbers need a smaller face to stay inside the bubble.
                let fontSize: CGFloat = badge.count > 99 ? 7 : (badge.count > 9 ? 8.5 : 10)
                let text = NSAttributedString(
                    string: "\(badge.count)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                        .foregroundColor: badge.level.badgeTextColor,
                    ])
                let textSize = text.size()
                text.draw(
                    at: NSPoint(
                        x: badgeRect.midX - textSize.width / 2,
                        y: badgeRect.midY - textSize.height / 2))
            }
        }
        return true
    }
    // A lit lamp or a coloured bubble must keep its real colours; a fully
    // quiet icon adapts to the menu bar.
    image.isTemplate = !anyLit && badge == nil
    return image
}

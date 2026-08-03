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

// How the menu bar icon renders. Persisted so the choice survives a restart.
enum IconMode: String, CaseIterable {
    case stoplight
    case highestWins = "highest-wins"

    static let defaultsKey = "iconMode"

    static var current: IconMode {
        IconMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "")
            ?? .stoplight
    }

    var displayName: String {
        switch self {
        case .stoplight: return "Stoplight"
        case .highestWins: return "Highest Wins"
        }
    }
}

// Scoreboard mode reserves room to the right of the glyph for the badge.
let stoplightIconSize = NSSize(width: 22, height: 22)
let badgeIconSize = NSSize(width: 24, height: 22)

// Geometry, in unflipped coordinates (y grows upward).
private let housingRect = NSRect(x: 2.5, y: 0.5, width: 11, height: 21)
private let lampX: CGFloat = 5
private let lampSize: CGFloat = 6
private let badgeRect = NSRect(x: 11, y: 9.5, width: 11, height: 11)

// The menu bar icon. The stoplight is always drawn; the two modes differ
// only in whether a notification bubble rides on its top-right corner.
//
// - stoplight:     three lamps, each lit whenever any session is in that state.
// - highest-wins:  the same stoplight, plus a bubble in the highest-priority
//                  colour carrying that state's count (no number when it's 1).
//
// With nothing active both modes render the same dim template outline.
@MainActor
func statusItemImage(mode: IconMode, counts: [StatusLevel: Int]) -> NSImage {
    var badge: (level: StatusLevel, count: Int)?
    if mode == .highestWins,
        let top = StatusLevel.allCases.reversed().first(where: { (counts[$0] ?? 0) > 0 })
    {
        badge = (top, counts[top] ?? 0)
    }
    return iconImage(counts: counts, badge: badge)
}

@MainActor
private func iconImage(
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
                x: lampX, y: 2.9 + CGFloat(i) * 6.2, width: lampSize, height: lampSize)
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

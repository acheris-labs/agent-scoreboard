import AppKit

// Shared state colors (also used for the menu row dots).
enum StatusDot {
    case waiting
    case error

    var color: NSColor {
        switch self {
        case .waiting: return NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)  // #FF9F0A
        case .error: return NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)  // #FF453A
        }
    }
}

let runningGreen = NSColor(red: 0.20, green: 0.84, blue: 0.29, alpha: 1)  // #32D74B

// The menu bar icon is a stoplight: red / yellow / green lamps top to
// bottom. A lamp lights when any session is in that state (error / waiting /
// running); unlit lamps stay dim. With every lamp off the image is a
// template outline so macOS tints it like a normal menu extra.
@MainActor
func statusItemImage(hasError: Bool, hasWaiting: Bool, hasRunning: Bool) -> NSImage {
    let size = NSSize(width: 22, height: 22)
    let anyLit = hasError || hasWaiting || hasRunning
    let image = NSImage(size: size, flipped: true) { _ in
        let lamps: [(lit: Bool, color: NSColor)] = [
            (hasError, StatusDot.error.color),
            (hasWaiting, StatusDot.waiting.color),
            (hasRunning, runningGreen),
        ]
        // Rounded housing so it reads as one stoplight, not three dots.
        let housing = NSBezierPath(
            roundedRect: NSRect(x: 5.5, y: 0.5, width: 11, height: 21), xRadius: 5.5, yRadius: 5.5)
        housing.lineWidth = 1.2
        let outline: NSColor = anyLit ? .labelColor : .black
        outline.withAlphaComponent(0.9).setStroke()
        housing.stroke()
        for (i, lamp) in lamps.enumerated() {
            let rect = NSRect(x: 8, y: 2.9 + CGFloat(i) * 6.2, width: 6, height: 6)
            if lamp.lit {
                lamp.color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                outline.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            }
        }
        return true
    }
    // Lit lamps must keep their real colors; all-off adapts to the bar.
    image.isTemplate = !anyLit
    return image
}

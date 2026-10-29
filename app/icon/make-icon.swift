// Renders Scoreboard's app icon: the menu bar stoplight, grown up.
//
//   swift app/icon/make-icon.swift <out-dir>
//
// Writes <out-dir>/AppIcon.iconset (every size macOS asks for) and a 1024px
// preview PNG; `make -C app icon` turns the set into AppIcon.icns. Each size
// is drawn as vectors at that size, not downscaled from 1024.
import AppKit

// Same lamp colours as StatusLevel in the app.
let red = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
let amber = NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)
let green = NSColor(red: 0.20, green: 0.84, blue: 0.29, alpha: 1)

// Drawn on a 1024 canvas, unflipped (y grows upward).
func drawIcon() {
    // macOS icon grid: an 824pt rounded square centred on the canvas, with
    // room around it for the drop shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor(red: 0.10, green: 0.12, blue: 0.17, alpha: 1).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Night-sky tile: lighter at the top, so the lamps read as glowing.
    NSGradient(
        starting: NSColor(red: 0.20, green: 0.24, blue: 0.33, alpha: 1),
        ending: NSColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1)
    )!.draw(in: tilePath, angle: -90)

    // The stoplight housing, in the menu bar glyph's proportions.
    let housing = NSRect(x: 362, y: 168, width: 300, height: 688)
    let housingPath = NSBezierPath(roundedRect: housing, xRadius: 150, yRadius: 150)

    NSGraphicsContext.saveGraphicsState()
    let housingShadow = NSShadow()
    housingShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    housingShadow.shadowOffset = NSSize(width: 0, height: -10)
    housingShadow.shadowBlurRadius = 24
    housingShadow.set()
    NSColor.black.setFill()
    housingPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Brushed metal, lit from the left.
    NSGradient(colors: [
        NSColor(white: 0.30, alpha: 1), NSColor(white: 0.16, alpha: 1),
        NSColor(white: 0.10, alpha: 1), NSColor(white: 0.20, alpha: 1),
    ])!.draw(in: housingPath, angle: 0)
    NSColor(white: 0.45, alpha: 0.6).setStroke()
    housingPath.lineWidth = 6
    housingPath.stroke()

    // Three lamps, all lit: red on top, as on a real stoplight.
    let lampSize: CGFloat = 176
    let gap = (housing.height - 3 * lampSize) / 4
    for (i, color) in [green, amber, red].enumerated() {
        let lamp = NSRect(
            x: housing.midX - lampSize / 2,
            y: housing.minY + gap + CGFloat(i) * (lampSize + gap),
            width: lampSize, height: lampSize)
        drawLamp(lamp, color)
    }
}

func drawLamp(_ rect: NSRect, _ color: NSColor) {
    // Recessed socket around the lens.
    NSColor(white: 0.03, alpha: 1).setFill()
    NSBezierPath(ovalIn: rect.insetBy(dx: -14, dy: -14)).fill()

    // Glow spilling onto the housing.
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color.withAlphaComponent(0.9)
    glow.shadowBlurRadius = 56
    glow.set()
    color.setFill()
    NSBezierPath(ovalIn: rect).fill()
    NSGraphicsContext.restoreGraphicsState()

    // The lens: bright core fading to a deeper rim.
    let lens = NSBezierPath(ovalIn: rect)
    let core = color.blended(withFraction: 0.2, of: .white)!
    let rim = color.blended(withFraction: 0.3, of: .black)!
    NSGradient(starting: core, ending: rim)!.draw(
        in: lens, relativeCenterPosition: NSPoint(x: -0.15, y: 0.2))

    // Specular highlight, top-left.
    let shine = NSRect(
        x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.55,
        width: rect.width * 0.38, height: rect.height * 0.28)
    NSColor.white.withAlphaComponent(0.35).setFill()
    NSBezierPath(ovalIn: shine).fill()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.dropFirst().first ?? "."
let iconset = (outDir as NSString).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(
            to: URL(fileURLWithPath: (iconset as NSString).appendingPathComponent(name)))
    }
}
try render(pixels: 1024).write(
    to: URL(fileURLWithPath: (outDir as NSString).appendingPathComponent("preview.png")))
print("wrote \(iconset)")

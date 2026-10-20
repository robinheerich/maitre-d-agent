// Renders the app icon: a dark rounded square with three status dots.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(calibratedWhite: 0.22, alpha: 1), ending: NSColor(calibratedWhite: 0.1, alpha: 1))!
        .draw(in: path, angle: -90)

    let dot = s * 0.13
    let rows: [(NSColor, CGFloat, Bool)] = [
        (.systemOrange, 1.0, true),
        (.systemBlue, 0.75, false),
        (NSColor(calibratedWhite: 0.6, alpha: 1), 0.55, false),
    ]
    for (index, (color, width, filled)) in rows.enumerated() {
        let y = body.maxY - s * 0.24 - CGFloat(index) * s * 0.19
        let circle = NSRect(x: body.minX + s * 0.13, y: y - dot / 2, width: dot, height: dot)
        color.set()
        if filled {
            NSBezierPath(ovalIn: circle).fill()
        } else {
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: s * 0.012, dy: s * 0.012))
            ring.lineWidth = s * 0.022
            ring.stroke()
        }
        NSColor(calibratedWhite: 1, alpha: index == 0 ? 0.9 : 0.45).set()
        let barX = circle.maxX + s * 0.07
        let bar = NSRect(x: barX, y: y - s * 0.025, width: (body.maxX - s * 0.13 - barX) * width, height: s * 0.05)
        NSBezierPath(roundedRect: bar, xRadius: s * 0.025, yRadius: s * 0.025).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

// Renders the Clinqy app icon: swift assets/make-icon.swift  → assets/AppIcon.icns
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    let u = s / 1024

    // macOS squircle tile with the app's dark look.
    let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 24 * u, color: NSColor(white: 0, alpha: 0.45).cgColor)
    cg.addPath(tilePath); cg.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor); cg.fillPath()
    cg.restoreGState()
    cg.saveGState(); cg.addPath(tilePath); cg.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(red: 0.13, green: 0.15, blue: 0.21, alpha: 1).cgColor,
                                 NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    cg.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    let accent = NSColor(red: 0.23, green: 0.51, blue: 1.0, alpha: 1)

    // Focus ring the buddy circles things with.
    cg.setStrokeColor(accent.withAlphaComponent(0.35).cgColor)
    cg.setLineWidth(22 * u)
    cg.strokeEllipse(in: CGRect(x: 250 * u, y: 250 * u, width: 360 * u, height: 360 * u))

    // Tapered motion streak behind the arrow.
    for i in 0..<14 {
        let t = CGFloat(i) / 14
        let r = (8 + 26 * t) * u
        let c = CGPoint(x: (300 + 250 * t) * u, y: (300 + 250 * t) * u)
        cg.setFillColor(accent.withAlphaComponent(0.08 + 0.35 * t).cgColor)
        cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    // The buddy: a pointer arrow, tip up-left of center pointing to top-left.
    let arrow = CGMutablePath()
    let p: [(CGFloat, CGFloat)] = [(0, 0), (0, -330), (80, -250), (150, -390), (210, -360), (140, -225), (250, -225)]
    let origin = CGPoint(x: 420, y: 770)
    arrow.addLines(between: p.map { CGPoint(x: (origin.x + $0.0) * u, y: (origin.y + $0.1) * u) })
    arrow.closeSubpath()
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 60 * u, color: accent.withAlphaComponent(0.8).cgColor)
    cg.addPath(arrow); cg.setFillColor(accent.cgColor); cg.fillPath()
    cg.restoreGState()
    cg.addPath(arrow); cg.setLineJoin(.round); cg.setLineWidth(18 * u)
    cg.setStrokeColor(NSColor.white.cgColor); cg.strokePath()
    cg.restoreGState()

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "assets/AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

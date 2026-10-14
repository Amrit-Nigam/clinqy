import AppKit
import SwiftUI

// Isometric line drawings for setup, in the website's style: dark faces, white edges, Clinqy blue for whatever is
// active. Each loops on its own clock, so the page explains itself without anyone pressing anything.

// MARK: - Brand

enum Brand {
    private static func adaptive(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let bg = adaptive(NSColor(red: 0.031, green: 0.035, blue: 0.051, alpha: 1), NSColor(white: 0.97, alpha: 1))
    static let raised = adaptive(NSColor(red: 0.063, green: 0.071, blue: 0.102, alpha: 1), .white)
    static let line = adaptive(NSColor(red: 0.122, green: 0.137, blue: 0.188, alpha: 1), NSColor(white: 0.82, alpha: 1))
    static let text = adaptive(NSColor(red: 0.914, green: 0.925, blue: 0.953, alpha: 1), NSColor(white: 0.12, alpha: 1))
    static let soft = adaptive(NSColor(red: 0.553, green: 0.580, blue: 0.647, alpha: 1), NSColor(white: 0.42, alpha: 1))
    static let blue = adaptive(NSColor(red: 0.29, green: 0.55, blue: 1.0, alpha: 1), NSColor(red: 0.12, green: 0.36, blue: 0.80, alpha: 1))
    static let green = adaptive(NSColor(red: 0.553, green: 1.0, blue: 0.690, alpha: 1), NSColor(red: 0.12, green: 0.45, blue: 0.23, alpha: 1))

    /// Geist Pixel (headings) and Geist Mono (labels), bundled in the app's Resources by build.sh.
    static func registerFonts() {
        for name in ["GeistPixel-Square", "GeistMono-Variable"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "woff2") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func pixel(_ size: CGFloat) -> Font {
        NSFont(name: "GeistPixel-Square", size: size) != nil ? .custom("GeistPixel-Square", size: size) : .system(size: size, weight: .bold, design: .monospaced)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        NSFont(name: "GeistMono-Regular", size: size) != nil ? .custom("GeistMono-Regular", size: size).weight(weight) : .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Projection

/// World (x, y, z) to the screen: x runs right-down, y runs left-down, z is up.
private struct Iso {
    let origin: CGPoint
    let s: CGFloat
    static let c = cos(CGFloat.pi / 6), si = sin(CGFloat.pi / 6)

    func p(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + (x - y) * Iso.c * s, y: origin.y + (x + y) * Iso.si * s - z * s)
    }

    /// Scales and centres a drawing so every listed world point fits inside `size`.
    static func fit(_ pts: [(CGFloat, CGFloat, CGFloat)], in size: CGSize, pad: CGFloat = 10) -> Iso {
        let xs = pts.map { ($0.0 - $0.1) * c }, ys = pts.map { ($0.0 + $0.1) * si - $0.2 }
        let (x0, x1, y0, y1) = (xs.min() ?? 0, xs.max() ?? 1, ys.min() ?? 0, ys.max() ?? 1)
        let s = min((size.width - pad * 2) / max(1, x1 - x0), (size.height - pad * 2) / max(1, y1 - y0), 1.2)
        return Iso(origin: CGPoint(x: size.width / 2 - (x0 + x1) / 2 * s, y: size.height / 2 - (y0 + y1) / 2 * s), s: s)
    }

    /// Maps a flat drawing at height z onto the plane, with (0, 0) at world (x, y).
    func plane(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGAffineTransform {
        let o = p(x, y, z)
        return CGAffineTransform(a: Iso.c * s, b: Iso.si * s, c: -Iso.c * s, d: Iso.si * s, tx: o.x, ty: o.y)
    }
}

private struct BoxStyle {
    var top = Color(red: 0.08, green: 0.086, blue: 0.118)
    var left = Color(red: 0.047, green: 0.055, blue: 0.075)
    var right = Color(red: 0.063, green: 0.071, blue: 0.098)
    var edge = Color.white.opacity(0.85)
    var width: CGFloat = 1.2

    static let plain = BoxStyle()
    static let lit = BoxStyle(top: Brand.blue.opacity(0.32), left: Color(red: 0.07, green: 0.13, blue: 0.27),
                              right: Color(red: 0.09, green: 0.17, blue: 0.34), edge: Brand.blue)
    static let faint = BoxStyle(edge: Color.white.opacity(0.35), width: 1)
}

private func polygon(_ pts: [CGPoint]) -> Path {
    var path = Path()
    path.addLines(pts)
    path.closeSubpath()
    return path
}

/// Draws a box with its two front faces and its top.
private func box(_ ctx: inout GraphicsContext, _ iso: Iso, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat,
                 _ w: CGFloat, _ d: CGFloat, _ h: CGFloat, _ st: BoxStyle = .plain, opacity: Double = 1) {
    var c = ctx
    c.opacity = opacity
    let top = polygon([iso.p(x, y, z + h), iso.p(x + w, y, z + h), iso.p(x + w, y + d, z + h), iso.p(x, y + d, z + h)])
    let left = polygon([iso.p(x, y + d, z), iso.p(x + w, y + d, z), iso.p(x + w, y + d, z + h), iso.p(x, y + d, z + h)])
    let right = polygon([iso.p(x + w, y, z), iso.p(x + w, y + d, z), iso.p(x + w, y + d, z + h), iso.p(x + w, y, z + h)])
    for (face, fill) in [(left, st.left), (right, st.right), (top, st.top)] {
        c.fill(face, with: .color(fill))
        c.stroke(face, with: .color(st.edge), style: StrokeStyle(lineWidth: st.width, lineJoin: .round))
    }
}

/// Text lying flat on a plane at height z, starting at world (x, y).
private func flatText(_ ctx: inout GraphicsContext, _ iso: Iso, _ text: String, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat,
                      size: CGFloat, color: Color, pixel: Bool = false, system: Bool = false, opacity: Double = 1) {
    var c = ctx
    c.opacity = opacity
    c.concatenate(iso.plane(x, y, z))
    let font = system ? Font.system(size: size, weight: .semibold) : pixel ? Brand.pixel(size) : Brand.mono(size, .medium)
    c.draw(Text(text).font(font).foregroundColor(color),
           at: .zero, anchor: .topLeading)
}

/// A small upright tag pointing at a part of the drawing, so its name reads at any angle.
/// `trailing` puts the tag to the left of the point, for parts near the right edge.
private func label(_ ctx: inout GraphicsContext, _ text: String, at p: CGPoint, color: Color = Brand.text, opacity: Double = 1,
                   trailing: Bool = false) {
    var c = ctx
    c.opacity = opacity
    let resolved = c.resolve(Text(text).font(Brand.mono(10, .medium)).foregroundColor(color))
    let size = resolved.measure(in: CGSize(width: 300, height: 40))
    let x = trailing ? p.x - size.width - 10 : p.x - size.width / 2 - 5
    let rect = CGRect(x: x, y: p.y - size.height - 9, width: size.width + 10, height: size.height + 4)
    c.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Brand.bg.opacity(0.92)))
    c.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.white.opacity(0.18)), lineWidth: 0.8)
    c.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
}

/// The person's own pointer: a plain white arrow, drawn flat on the screen.
private func pointer(_ ctx: inout GraphicsContext, at p: CGPoint, pressed: Bool) {
    let k: CGFloat = pressed ? 0.88 : 1
    let pts: [CGPoint] = [(0, 0), (0, 17), (4.6, 12.8), (8, 19.6), (10.9, 18.2), (7.6, 11.4), (13.6, 11.4)].map {
        CGPoint(x: p.x + $0.0 * k, y: p.y + $0.1 * k)
    }
    let path = polygon(pts)
    ctx.fill(path, with: .color(.white))
    ctx.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
}

private func ring(_ ctx: inout GraphicsContext, at p: CGPoint, age: CGFloat) {
    guard age > 0, age < 1 else { return }
    let r = 6 + 16 * age
    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r * 0.6, width: r * 2, height: r * 1.2)),
               with: .color(Brand.blue.opacity(Double(1 - age))), lineWidth: 1.5)
}

private func span(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { min(1, max(0, (t - a) / (b - a))) }
private func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }
private func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }

/// A looping drawing: `draw` gets the loop's progress (0..1).
private struct Looping: View {
    let period: Double
    let draw: (inout GraphicsContext, CGSize, CGFloat) -> Void

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = CGFloat(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
                draw(&ctx, size, t)
            }
        }
    }
}

// MARK: - Keys

/// The ⌃ and ⌥ keys on a little plate, each `press` 0..1 (1 = all the way down).
private func keys(_ ctx: inout GraphicsContext, _ iso: Iso, press: CGFloat) {
    box(&ctx, iso, -10, -10, -6, 112, 62, 6, .faint)
    for (i, label) in ["⌃", "⌥"].enumerated() {
        let x = CGFloat(i) * 50
        let h = 14 - 8 * press
        box(&ctx, iso, x, 0, 0, 42, 42, h, press > 0.5 ? .lit : .plain)
        // Upright, so the symbol reads; it sits on the middle of the keycap's top.
        ctx.draw(Text(label).font(.system(size: 19 * iso.s, weight: .semibold)).foregroundColor(press > 0.5 ? .white : Brand.text),
                 at: iso.p(x + 21, 21, h), anchor: .center)
    }
}

/// Tap ⌃⌥: the keys go down and up, and the command bar appears with a request being typed.
struct TapKeysArt: View {
    var body: some View {
        Looping(period: 3.6) { ctx, size, t in
            let iso = Iso.fit([(-10, 52, -6), (102, -10, -6), (102, 52, -6), (-40, -70, 39), (150, -70, 39), (-40, -42, 34)], in: size)
            let press = span(t, 0.12, 0.17) * (1 - span(t, 0.24, 0.29))
            let bar = ease(span(t, 0.28, 0.4)) * (1 - span(t, 0.88, 0.98))
            if bar > 0 {
                let lift = 26 + 8 * bar
                // Wide enough for the whole request and the caret (Geist Mono at 8.5 is about 5.1 per character).
                box(&ctx, iso, -40, -70, lift, 190, 28, 5, .plain, opacity: Double(bar))
                let request = "where’s the brightness setting?"
                let n = Int((CGFloat(request.count) * span(t, 0.42, 0.78)).rounded())
                flatText(&ctx, iso, String(request.prefix(n)) + (t < 0.82 ? "▍" : ""), -34, -62, lift + 5,
                         size: 8.5, color: Brand.text, opacity: Double(bar))
            }
            keys(&ctx, iso, press: ease(press))
        }
    }
}

/// Hold ⌃⌥: the keys stay down while the voice bars move, and let go sends it.
struct HoldKeysArt: View {
    var body: some View {
        Looping(period: 3.8) { ctx, size, t in
            let iso = Iso.fit([(-10, 52, -6), (102, -10, -6), (102, 52, -6), (-44, -36, 34), (30, -36, 34), (-44, -27, 0)], in: size)
            let down = span(t, 0.1, 0.15) * (1 - span(t, 0.7, 0.75))
            let listening = t > 0.15 && t < 0.72
            for i in 0..<5 {
                let wave = abs(sin(Double(t) * 34 + Double(i) * 1.3)) * Double(listening ? 1 : 0)
                let h = 4 + CGFloat(wave) * 30
                box(&ctx, iso, -44 + CGFloat(i) * 16, -36, 0, 9, 9, h, listening ? .lit : .faint)
            }
            keys(&ctx, iso, press: ease(down))
            let sent = span(t, 0.76, 0.82) * (1 - span(t, 0.93, 0.99))
            if sent > 0 {
                label(&ctx, "sent ✓", at: iso.p(-10, -32, 30), color: Brand.green, opacity: Double(sent))
            }
        }
    }
}

/// While it works: the menu-bar icon turns into a stop button, and one click stops the task.
struct StopArt: View {
    var body: some View {
        Looping(period: 3.6) { ctx, size, t in
            let iso = Iso.fit([(-20, 26, 0), (130, -10, 6), (130, 56, 0), (-20, -10, 6)], in: size, pad: 16)
            box(&ctx, iso, -20, -10, 0, 150, 36, 6, .faint)
            for i in 0..<3 { box(&ctx, iso, CGFloat(i) * 26, 0, 6, 16, 16, 3) }
            let clickAt: CGFloat = 0.6
            let running = t < clickAt
            let pressed = t > clickAt - 0.03 && t < clickAt + 0.04
            box(&ctx, iso, 96, 0, 6, 18, 16, pressed ? 1.5 : 4, running ? .lit : .plain)
            flatText(&ctx, iso, running ? "■" : "▲", 100.5, 1.5, pressed ? 7.5 : 10, size: 10, color: running ? .white : Brand.blue)
            // The task it's doing: three dots stepping along under the bar.
            if running {
                for i in 0..<3 {
                    let on = Int(t * 18) % 3 == i
                    box(&ctx, iso, 104 + CGFloat(i) * 9, 46, 0, 5, 5, on ? 7 : 3, on ? .lit : .faint)
                }
            } else {
                label(&ctx, "stopped", at: iso.p(112, 48, 0), color: Brand.green, opacity: Double(1 - span(t, 0.9, 0.98)))
            }
            let target = iso.p(105, 8, 10)
            let from = CGPoint(x: size.width - 20, y: size.height - 14)
            let at = mix(from, target, ease(span(t, 0.25, clickAt - 0.04)))
            let back = mix(at, from, ease(span(t, 0.75, 0.98)))
            ring(&ctx, at: target, age: span(t, clickAt, clickAt + 0.18))
            pointer(&ctx, at: back, pressed: pressed)
        }
    }
}

// MARK: - Extension

/// Loading the extension by hand: Developer mode on, Load unpacked, pick the folder, and Clinqy shows up.
/// No labels on the drawing: the part to click lights up, and one caption underneath says the step.
struct ExtensionArt: View {
    private static let steps: [(until: CGFloat, text: String)] = [
        (0.3, "Turn on Developer mode"),
        (0.52, "Click Load unpacked"),
        (0.8, "Pick the Clinqy folder"),
        (1.01, "Clinqy is loaded"),
    ]

    var body: some View {
        Looping(period: 7) { ctx, size, t in
            let W: CGFloat = 170, D: CGFloat = 118
            let art = CGSize(width: size.width, height: size.height - 34)
            let iso = Iso.fit([(0, D, 0), (W, 0, 6), (W, D, 0), (0, 0, 6), (30, 30, 52), (150, 30, 52)], in: art, pad: 6)
            let z: CGFloat = 6
            box(&ctx, iso, 0, 0, 0, W, D, z)
            // The page's own furniture: a title bar strip and an extension that's already installed.
            box(&ctx, iso, 8, 6, z, 60, 8, 1, .faint)
            box(&ctx, iso, 90, 50, z, 72, 40, 3, .faint)
            box(&ctx, iso, 96, 56, z + 3, 12, 12, 2, .faint)
            box(&ctx, iso, 114, 58, z + 3, 40, 4, 1, .faint)

            // 1. Developer mode switch, top right. Lit while it's the thing to click.
            let toggled = t > 0.2
            let toggleTarget = iso.p(W - 20, 11, z + 2)
            box(&ctx, iso, W - 32, 6, z, 24, 10, 2, toggled || t < 0.2 ? .lit : .faint)
            box(&ctx, iso, toggled ? W - 19 : W - 31, 7, z + 2, 10, 8, 2)

            // 2. Load unpacked, which only shows once Developer mode is on.
            let reveal = ease(span(t, 0.22, 0.3))
            let loadTarget = iso.p(38, 30, z + 3)
            let loadPressed = t > 0.47 && t < 0.52
            if reveal > 0 {
                box(&ctx, iso, 8, 24, z, 62, 13, loadPressed ? 1 : 3, t < 0.52 ? .lit : .plain, opacity: Double(reveal))
            }

            // 4. The card that proves it worked, in the empty slot on the left.
            let card = ease(span(t, 0.8, 0.88))
            if card > 0 {
                box(&ctx, iso, 8, 50, z, 72, 40, 3, .plain, opacity: Double(card))
                box(&ctx, iso, 14, 56, z + 3, 12, 12, 3, .lit, opacity: Double(card))
                box(&ctx, iso, 32, 58, z + 3, 40, 4, 1, .plain, opacity: Double(card))
            }

            // 3. The folder picker floats above the page; the Clinqy folder lights up and gets picked.
            let picker = ease(span(t, 0.52, 0.58)) * (1 - span(t, 0.74, 0.8))
            let folderTarget = iso.p(80, 46, 50)
            if picker > 0 {
                box(&ctx, iso, 30, 30, 40, 120, 50, 4, .plain, opacity: Double(picker))
                for (i, y) in [CGFloat(38), 54, 66].enumerated() {
                    box(&ctx, iso, 40, y, 44, 80, 9, 2, i == 1 ? .lit : .faint, opacity: Double(picker))
                }
            }

            // The pointer: switch, then button, then folder, then away.
            let rest = CGPoint(x: art.width - 18, y: art.height - 10)
            var at = rest
            at = mix(at, toggleTarget, ease(span(t, 0.04, 0.17)))
            at = mix(at, loadTarget, ease(span(t, 0.3, 0.45)))
            at = mix(at, folderTarget, ease(span(t, 0.58, 0.66)))
            at = mix(at, rest, ease(span(t, 0.82, 0.97)))
            ring(&ctx, at: toggleTarget, age: span(t, 0.19, 0.33))
            ring(&ctx, at: loadTarget, age: span(t, 0.49, 0.63))
            ring(&ctx, at: folderTarget, age: span(t, 0.68, 0.82))
            let pressed = (t > 0.17 && t < 0.21) || loadPressed || (t > 0.65 && t < 0.69)
            pointer(&ctx, at: at, pressed: pressed)

            // The caption: which step this is.
            let i = Self.steps.firstIndex { t < $0.until } ?? 3
            let done = i == 3
            let num = ctx.resolve(Text(done ? "✓" : "\(i + 1)").font(Brand.mono(10.5, .bold)).foregroundColor(done ? Brand.bg : .white))
            let text = ctx.resolve(Text(Self.steps[i].text).font(Brand.mono(11.5, .medium)).foregroundColor(done ? Brand.green : Brand.text))
            let cy = size.height - 14
            let tw = text.measure(in: CGSize(width: size.width, height: 30)).width
            let x0 = (size.width - tw - 28) / 2
            ctx.fill(Path(ellipseIn: CGRect(x: x0, y: cy - 10, width: 20, height: 20)), with: .color(done ? Brand.green : Brand.blue))
            ctx.draw(num, at: CGPoint(x: x0 + 10, y: cy), anchor: .center)
            ctx.draw(text, at: CGPoint(x: x0 + 28, y: cy), anchor: .leading)
        }
    }
}

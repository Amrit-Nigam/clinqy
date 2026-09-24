import AppKit

/// The Clicky-style companion cursor: trails the mouse when idle and flies to targets when acting.
final class BuddyCursor {
    private let window: NSWindow
    private let view = BuddyView()
    private var followTimer: Timer?
    private var busyUntil = Date.distantPast
    private let offset = CGPoint(x: 18, y: -22)

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 290, height: 70),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = view
        window.orderFrontRegardless()

        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.follow()
        }
    }

    func setLabel(_ text: String?) {
        view.label = text
        view.needsDisplay = true
    }

    func setWorking(_ working: Bool) {
        view.working = working
        view.needsDisplay = true
    }

    private var flight: Timer?

    /// Glides along a gentle curve to a global top-left point (CGEvent space), then calls `completion`.
    func fly(to point: CGPoint, duration: TimeInterval = 0.32, completion: @escaping () -> Void) {
        flight?.invalidate()
        busyUntil = Date().addingTimeInterval(duration + 0.8)
        let cocoa = Self.toCocoa(point)
        let start = window.frame.origin
        let end = NSPoint(x: cocoa.x - 22, y: cocoa.y - window.frame.height + 22)
        // Control point bowed sideways from the straight line gives the arc.
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(1, hypot(dx, dy))
        let bow = min(120, length * 0.25)
        let control = NSPoint(x: (start.x + end.x) / 2 - dy / length * bow, y: (start.y + end.y) / 2 + dx / length * bow)
        let began = Date()
        flight = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let raw = min(1, Date().timeIntervalSince(began) / duration)
            let t = raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2   // ease in-out cubic
            let u = 1 - t
            let x = u * u * start.x + 2 * u * t * control.x + t * t * end.x
            let y = u * u * start.y + 2 * u * t * control.y + t * t * end.y
            self.window.setFrameOrigin(NSPoint(x: x, y: y))
            // Lean into the motion, settle upright on arrival.
            self.view.tilt = CGFloat(sin(raw * .pi)) * (dx >= 0 ? -0.35 : 0.35)
            self.view.needsDisplay = true
            if raw >= 1 {
                timer.invalidate()
                self.view.tilt = 0
                self.view.pulse()
                completion()
            }
        }
    }

    private func follow() {
        guard Date() > busyUntil else { return }
        let mouse = NSEvent.mouseLocation
        let target = NSPoint(x: mouse.x + offset.x - 20, y: mouse.y + offset.y - window.frame.height + 42)
        let current = window.frame.origin
        // Ease toward the mouse so it feels like it's following, not glued.
        let next = NSPoint(x: current.x + (target.x - current.x) * 0.25,
                           y: current.y + (target.y - current.y) * 0.25)
        if abs(next.x - current.x) > 0.3 || abs(next.y - current.y) > 0.3 {
            window.setFrameOrigin(next)
        }
    }

    static func toCocoa(_ point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

private final class BuddyView: NSView {
    var label: String?
    var working = false
    var tilt: CGFloat = 0
    private var pulseStart: Date?
    private var pulseTimer: Timer?

    /// Click ripple around the arrow tip.
    func pulse() {
        pulseStart = Date()
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self, let start = self.pulseStart else { t.invalidate(); return }
            if Date().timeIntervalSince(start) > 0.45 { self.pulseStart = nil; t.invalidate() }
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = working ? NSColor.systemPurple : NSColor.systemBlue
        let top = bounds.maxY - 22
        let tip: CGFloat = 22

        if let start = pulseStart {
            let p = CGFloat(min(1, Date().timeIntervalSince(start) / 0.45))
            let r = 4 + p * 16
            accent.withAlphaComponent(0.6 * (1 - p)).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: tip - r, y: top - r, width: r * 2, height: r * 2))
            ring.lineWidth = 2
            ring.stroke()
        }

        NSGraphicsContext.saveGraphicsState()
        let rotate = NSAffineTransform()
        rotate.translateX(by: tip, yBy: top)
        rotate.rotate(byRadians: tilt)
        rotate.translateX(by: -tip, yBy: -top)
        rotate.concat()

        // Arrow cursor shape with its tip at the top-left.
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: tip, y: top))
        arrow.line(to: NSPoint(x: tip, y: top - 20))
        arrow.line(to: NSPoint(x: tip + 5, y: top - 15))
        arrow.line(to: NSPoint(x: tip + 13, y: top - 15))
        arrow.close()
        accent.setFill()
        arrow.fill()
        NSColor.white.setStroke()
        arrow.lineWidth = 1.5
        arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()

        guard let label, !label.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: String(label.prefix(38)), attributes: attrs)
        let size = text.size()
        let pill = NSRect(x: tip + 16, y: top - 34, width: size.width + 16, height: size.height + 8)
        accent.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 4))
    }
}

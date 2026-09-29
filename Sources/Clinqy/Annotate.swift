import AppKit

/// A spot the user circled on screen to point Clinqy at ("this", "here", "that thing").
/// Points are global top-left screen coordinates, the same space as element frames.
struct Annotation: Equatable {
    let points: [CGPoint]

    var rect: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Dims every screen and lets the user draw a loop around something. Esc or a mere click cancels.
@MainActor
final class AnnotationOverlay {
    private var windows: [NSWindow] = []
    private var completion: ((Annotation?) -> Void)?

    func begin(_ completion: @escaping (Annotation?) -> Void) {
        guard windows.isEmpty else { return }
        self.completion = completion
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // The dimming layer mustn't end up in the screenshot that shows the model what was circled.
            window.sharingType = .none
            window.contentView = DrawView(onDone: { [weak self] in self?.end($0) })
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first { $0.screen == NSScreen.main }?.makeKey() ?? windows.first?.makeKey()
        NSCursor.crosshair.push()
    }

    private func end(_ annotation: Annotation?) {
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        let done = completion
        completion = nil
        done?(annotation)
    }

    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class DrawView: NSView {
        private var path: [CGPoint] = []   // view coordinates
        private let onDone: (Annotation?) -> Void

        init(onDone: @escaping (Annotation?) -> Void) {
            self.onDone = onDone
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onDone(nil) } }   // Esc
        override func cancelOperation(_ sender: Any?) { onDone(nil) }

        override func mouseDown(with event: NSEvent) { path = [convert(event.locationInWindow, from: nil)]; needsDisplay = true }
        override func mouseDragged(with event: NSEvent) { path.append(convert(event.locationInWindow, from: nil)); needsDisplay = true }

        override func mouseUp(with event: NSEvent) {
            guard let window, path.count > 3 else { return onDone(nil) }
            let xs = path.map(\.x), ys = path.map(\.y)
            guard (xs.max()! - xs.min()!) > 8 || (ys.max()! - ys.min()!) > 8 else { return onDone(nil) }
            // View (bottom-left, per screen) → global top-left, the space AX element frames use.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let global = path.map { p -> CGPoint in
                let s = window.convertPoint(toScreen: convert(p, to: nil))
                return CGPoint(x: s.x, y: primaryHeight - s.y)
            }
            onDone(Annotation(points: global))
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.18).setFill()
            bounds.fill()
            let hint = NSAttributedString(string: "Circle what you mean  ·  Esc to cancel", attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white])
            let size = hint.size()
            let pill = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 90, width: size.width + 28, height: size.height + 12)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            hint.draw(at: NSPoint(x: pill.minX + 14, y: pill.minY + 6))

            guard let first = path.first else { return }
            let stroke = NSBezierPath()
            stroke.move(to: first)
            path.dropFirst().forEach { stroke.line(to: $0) }
            stroke.lineWidth = 4
            stroke.lineCapStyle = .round
            stroke.lineJoinStyle = .round
            NSColor.systemYellow.setStroke()
            stroke.stroke()
        }
    }
}

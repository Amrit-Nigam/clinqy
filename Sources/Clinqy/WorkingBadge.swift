import AppKit

/// While a background run works out of sight: a small glowing pill in the corner of the user's screen nearest
/// Clinqy's hidden one, so they know it's still busy. It never takes focus; a click opens the live view.
@MainActor
final class WorkingBadge {
    private static let primary = WorkingBadge()
    static var shared: WorkingBadge { TaskExecution.current?.service(WorkingBadge.self, make: WorkingBadge.init) ?? primary }

    private var panel: NSPanel?
    private let spinner = NSProgressIndicator()

    func show() {
        if TaskExecution.current != nil { return } // Parallel jobs have their own colored task dock.
        if panel == nil { build() }
        guard let panel, let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 12, y: visible.minY + 12))
        spinner.startAnimation(nil)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                self?.spinner.stopAnimation(nil)
                self?.panel?.orderOut(nil)
            }
        }
    }

    private func build() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 172, height: 30),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let pill = Pill(frame: panel.contentRect(forFrameRect: panel.frame))
        pill.onClick = { AgentScreenView.shared.show() }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 10, y: 7, width: 16, height: 16)
        let label = NSTextField(labelWithString: "Working in background")
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .white
        label.frame = NSRect(x: 32, y: 7, width: 136, height: 16)
        pill.addSubview(spinner)
        pill.addSubview(label)
        pill.toolTip = "Clinqy is working on its hidden screen — click to watch"
        panel.contentView = pill
        self.panel = panel
    }

    /// The pill itself: dark, rounded, with a soft blue glow; clicks open the live view.
    private final class Pill: NSView {
        var onClick: () -> Void = {}

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = frame.height / 2
            layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.9).cgColor
            layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.55).cgColor
            layer?.borderWidth = 1
            layer?.shadowColor = NSColor.systemBlue.cgColor
            layer?.shadowOpacity = 0.6
            layer?.shadowRadius = 6
            layer?.shadowOffset = .zero
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseUp(with event: NSEvent) { onClick() }
    }
}

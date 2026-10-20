import AppKit
import ScreenCaptureKit

/// The live view of Clinqy's hidden screen: what a background run is doing there, buddy and all, a few frames a
/// second while it's open. The user can steer the run from here (or answer its question), stop it, or "Bring it
/// here": the run's windows move onto their screen to take over.
@MainActor
final class AgentScreenView: NSObject, NSWindowDelegate {
    static let shared = AgentScreenView()
    weak var agent: Agent?

    private var panel: NSPanel?
    private let picture = NSImageView()
    private let status = NSTextField(labelWithString: "")
    private let steer = NSTextField()
    private let stop = NSButton()
    private var timer: Timer?
    private var display: SCDisplay?
    private var capturing = false

    var isOpen: Bool { panel?.isVisible == true }

    /// Opens the view; with no hidden screen (this Mac couldn't make one) it shows the run's window itself instead.
    func show() {
        guard AgentScreen.bounds != nil else {
            Task { await Background.showLast() }
            return
        }
        if panel == nil { build() }
        display = nil
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refresh() } }
        }
        Task { await refresh() }
    }

    private func build() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Clinqy — background work"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentAspectRatio = NSSize(width: 16, height: 11)

        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let bring = NSButton(title: "Bring it here", target: self, action: #selector(bringHere))
        bring.bezelStyle = .rounded
        stop.title = "Stop"
        stop.bezelStyle = .rounded
        stop.target = self
        stop.action = #selector(stopRun)
        steer.placeholderString = "Tell it something (“use the cheaper one”) — Return to send"
        steer.target = self
        steer.action = #selector(sendSteer)
        steer.font = .systemFont(ofSize: 12)
        let bar = NSStackView(views: [status, NSView(), stop, bring])
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 10, right: 12)
        let steerRow = NSStackView(views: [steer])
        steerRow.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 0, right: 12)
        let stack = NSStackView(views: [picture, steerRow, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        picture.setContentHuggingPriority(.defaultLow, for: .vertical)
        panel.contentView = stack
        self.panel = panel
    }

    private func refresh() async {
        guard !capturing, panel?.isVisible == true, let id = AgentScreen.id else { return }
        capturing = true
        defer { capturing = false }
        if display == nil {
            display = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false))?
                .displays.first { $0.displayID == id }
        }
        guard let display else { return }
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                                                  configuration: config) {
            picture.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        let running = agent?.isRunning == true && agent?.runBackground == true
        if let q = agent?.question, running {
            status.stringValue = "Asks: " + q.text
            steer.placeholderString = "Your answer — Return to send"
        } else {
            status.stringValue = running ? (agent?.steps.last?.text ?? "Working…")
                : AgentScreen.windows().isEmpty ? "Nothing there right now" : "Done"
            steer.placeholderString = "Tell it something (“use the cheaper one”) — Return to send"
        }
        stop.isHidden = !running
        steer.isEnabled = running
    }

    @objc private func sendSteer() {
        let text = steer.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let agent, agent.isRunning else { return }
        agent.addContext(text)   // answers a waiting question too
        steer.stringValue = ""
    }

    @objc private func stopRun() { agent?.cancel() }

    @objc private func bringHere() {
        AgentScreen.bringHere()
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        picture.image = nil
    }
}

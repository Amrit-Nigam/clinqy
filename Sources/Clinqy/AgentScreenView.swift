import AppKit
import ScreenCaptureKit
import Combine

/// The live view of Clinqy's hidden screen: what a background run is doing there, buddy and all, a few frames a
/// second while it's open. The user can steer the run from here (or answer its question), stop it, or "Bring it
/// here": the run's windows move onto their screen to take over.
@MainActor
final class AgentScreenView: NSObject, NSWindowDelegate {
    static let shared = AgentScreenView()
    weak var agent: Agent? {
        didSet {
            questionObserver = agent?.$question.sink { [weak self] question in
                guard let self else { return }
                self.presentation += 1 // Discard an in-flight image when privacy/question state changes.
                if question?.sensitive == true { self.picture.image = nil }
                self.nextCapture = .distantPast
                Task { await self.refresh() }
            }
            phaseObserver = agent?.$phase.removeDuplicates().sink { [weak self] _ in
                self?.nextCapture = .distantPast
                Task { await self?.refresh() }
            }
        }
    }
    private var questionObserver: AnyCancellable?
    private var phaseObserver: AnyCancellable?

    private var panel: NSPanel?
    private let picture = NSImageView()
    private let status = NSTextField(labelWithString: "")
    private let steer = NSTextField()
    private let stop = NSButton()
    private let bring = NSButton()
    private var timer: Timer?
    private var display: SCDisplay?
    private var capturing = false
    private var nextCapture = Date.distantPast
    private var presentation = 0

    var isOpen: Bool { panel?.isVisible == true }

    /// Opens the view; with no hidden screen (this Mac couldn't make one) it shows the run's window itself instead.
    func show() {
        guard workerTab != nil || AgentScreen.bounds != nil else {
            Task { await Background.showLast() }
            return
        }
        if panel == nil { build() }
        display = nil
        presentation += 1
        nextCapture = .distantPast
        idleGeneration = nil
        bring.title = workerTab == nil ? "Bring it here" : "Tasks & Recovery"
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Efficiency.previewInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer?.tolerance = 0.1
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
        bring.title = "Bring it here"
        bring.target = self
        bring.action = #selector(bringHere)
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

    private var workerTab: BrowserBridge.TabInfo? {
        let tab = Background.active ? Background.tab : Background.last.tab
        return tab?.connection == ChromeWorker.shared.identity ? tab : nil
    }

    /// Once a run is over the picture doesn't change: one capture, not one every 250 ms.
    private var idleGeneration: Int?

    private func refresh() async {
        guard !capturing, panel?.isVisible == true,
              panel?.occlusionState.contains(.visible) == true else { return }
        let running = agent?.isRunning == true && agent?.runBackground == true
        let generation = ChromeWorker.shared.generation
        let request = presentation
        stop.isHidden = !running
        steer.isEnabled = running
        if agent?.question?.sensitive == true {
            picture.image = nil
            status.stringValue = "Waiting for private input on your Mac"
            return
        }
        if let q = agent?.question, running {
            status.stringValue = "Asks: " + q.text
            steer.placeholderString = "Your answer — Return to send"
        } else {
            status.stringValue = workerTab != nil ? (TaskStore.shared.active?.stage ?? "Worker Chrome — final task view")
                : running ? (agent?.steps.last?.text ?? "Working…") : "Done"
            steer.placeholderString = "Tell it something (“use the cheaper one”) — Return to send"
        }
        if running { idleGeneration = nil }
        if !running && idleGeneration == generation { return }
        guard Date() >= nextCapture else { return }
        let interval = agent?.question != nil || Efficiency.constrained ? Efficiency.waitingPreviewInterval : Efficiency.previewInterval
        nextCapture = Date().addingTimeInterval(interval)
        if let tab = workerTab {
            capturing = true
            defer { capturing = false }
            if let png = await BrowserBridge.shared.taskScreenshot(of: tab, preview: true) {
                guard canPublish(request, generation: generation), workerTab?.id == tab.id else { return }
                picture.image = NSImage(data: png)
                idleGeneration = running ? nil : generation
            }
            return
        }
        guard let id = AgentScreen.id else { return }
        capturing = true
        defer { capturing = false }
        if display == nil {
            display = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false))?
                .displays.first { $0.displayID == id }
        }
        guard let display else { return }
        guard canPublish(request, generation: generation), workerTab == nil else { return }
        let config = SCStreamConfiguration()
        config.width = min(display.width, 1280)
        config.height = max(1, Int(Double(display.height) * Double(config.width) / Double(max(1, display.width))))
        config.showsCursor = false
        if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                                                  configuration: config) {
            guard canPublish(request, generation: generation), workerTab == nil else { return }
            picture.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            idleGeneration = running ? nil : generation
        }
    }

    private func canPublish(_ request: Int, generation: Int) -> Bool {
        request == presentation && generation == ChromeWorker.shared.generation
            && panel?.isVisible == true && agent?.question?.sensitive != true
    }

    @objc private func sendSteer() {
        let text = steer.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let agent, agent.isRunning else { return }
        agent.addContext(text)   // answers a waiting question too
        steer.stringValue = ""
    }

    @objc private func stopRun() { agent?.cancel() }

    @objc private func bringHere() {
        if workerTab != nil { TasksPanel.shared.show(); return }
        AgentScreen.bringHere()
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        presentation += 1
        timer?.invalidate()
        timer = nil
        picture.image = nil
    }
}

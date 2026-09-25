import AppKit
import CryptoKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var buddy: Buddy!
    private var agent: Agent!
    private var voice: Voice!
    private var panel: CommandPanel!
    private var island: IslandPanel!
    private var resultPanel: ResultPanel!
    private var hotKey: HotKey?
    private var pressedAt: Date?
    private var holdTimer: Timer?
    private var holdToTalk = false
    private let overlay = AnnotationOverlay()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buddy = Buddy()
        agent = Agent(buddy: buddy)
        voice = Voice()
        panel = CommandPanel(agent: agent, voice: voice, onMic: { [weak self] in self?.toggleMic() },
                             onWatch: { [weak self] in self?.startWatching() },
                             onCircle: { [weak self] in self?.startCircling() })
        island = IslandPanel(agent: agent, voice: voice)
        resultPanel = ResultPanel(agent: agent)
        agent.onResult = { [weak self] in if self?.agent.result != nil { self?.resultPanel.show() } }
        Brain.prewarm()
        Whisper.shared.prepare()
        BrowserBridge.shared.start()
        startScheduler()

        agent.onStart = { [weak self] in
            guard let self else { return }
            self.setStatusIcon(running: true)
            // Keystrokes must reach the target app, and clicks must not land on our windows.
            self.panel.orderOut(nil)
            self.island.show()
        }
        agent.onFinish = { [weak self] _, _ in
            guard let self else { return }
            self.setStatusIcon(running: false)
            self.island.show(for: 4.5)
        }
        // Paused for the user's input: bring the bar up with the question; hide it again once answered.
        agent.onQuestion = { [weak self] in
            guard let self else { return }
            self.panel.showCentered()
            self.island.show()
        }
        agent.onAnswered = { [weak self] in self?.panel.orderOut(nil) }
        voice.onLevel = { [weak self] level in self?.buddy.level = level }
        voice.onFinal = { [weak self] text in
            guard let self else { return }
            self.buddy.mood = .idle
            // A spoken reply to a question answers it; otherwise it's a new request.
            if self.agent.question != nil { self.agent.answer(text) }
            else if self.agent.isRunning { self.agent.addContext(text) }
            else { self.agent.submit(text) }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Clinqy")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Clinqy  (⌃⌥)", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Talk  (hold ⌃⌥)", action: #selector(toggleMic), keyEquivalent: "")
        menu.addItem(withTitle: "Circle Something…", action: #selector(startCircling), keyEquivalent: "")
        menu.addItem(withTitle: "Check Permissions…", action: #selector(checkPermissions), keyEquivalent: "")
        menu.addItem(withTitle: "Edit Memory…", action: #selector(openMemory), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
        self.menu = menu

        // ⌃⌥ (Control + Option on their own): tap opens the bar, hold talks.
        hotKey = HotKey(onPress: { [weak self] in self?.hotKeyDown() },
                        onRelease: { [weak self] in self?.hotKeyUp() },
                        onOtherKey: { [weak self] in self?.hotKeyAbandoned() })

        if !Permissions.allGranted {
            Permissions.requestMissing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.checkPermissions() }
        }
    }

    /// `clinqy://run?task=…` runs a task in whatever app is in front (used for scripting and tests).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "clinqy" && url.host == "reload-extension" {
            Task { Agent.writeLog("extension reloaded in \(await BrowserBridge.shared.reloadAll()) browser(s)") }
        }
        for url in urls where url.scheme == "clinqy" && url.host == "answer" {
            agent.answer(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value)
        }
        for url in urls where url.scheme == "clinqy" && url.host == "cancel" { agent.cancel() }
        for url in urls where url.scheme == "clinqy" && url.host == "add" {
            agent.addContext(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value ?? "")
        }
        for url in urls where url.scheme == "clinqy" && url.host == "watch" { rememberTarget(); startWatching() }
        for url in urls where url.scheme == "clinqy" && url.host == "stop-watching" { stopWatching() }
        for url in urls where url.scheme == "clinqy" && url.host == "qa" { startQA(url) }
        for url in urls where url.scheme == "clinqy" && url.host == "workflow" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let name = items.first(where: { $0.name == "name" })?.value, let wf = Workflows.shared.named(name) else { continue }
            var params: [String: String] = [:]
            for item in items where item.name != "name" { params[item.name] = item.value ?? "" }
            rememberTarget()
            agent.runWorkflow(wf, params: params)
        }
        for url in urls where url.scheme == "clinqy" && url.host == "run" {
            guard let task = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "task" })?.value else { continue }
            rememberTarget()
            let test = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "test" }?.value == "1"
            agent.submit(task, test: test)
        }
    }

    /// While a task runs the menu-bar icon becomes a stop button (one click stops everything).
    private var menu: NSMenu?

    private func setStatusIcon(running: Bool) {
        guard let button = statusItem.button else { return }
        if running {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Clinqy")
            button.contentTintColor = .systemRed
            statusItem.menu = nil
            button.target = self
            button.action = #selector(stopFromMenuBar)
        } else {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Clinqy")
            button.contentTintColor = nil
            button.action = nil
            statusItem.menu = menu
        }
    }

    @objc private func stopFromMenuBar() {
        if Recorder.shared.isRecording { stopWatching() } else { agent.cancel() }
    }

    // MARK: - Watch & learn

    private func startWatching() {
        panel.orderOut(nil)
        // Give the user their app back, then watch.
        if let target = agent.targetApp { target.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            Recorder.shared.start()
            self.setStatusIcon(running: true)
            self.island.show()
            self.buddy.bubble("watching…", for: 2)
        }
    }

    private func stopWatching() {
        let recording = Recorder.shared.stop()
        setStatusIcon(running: false)
        island.hide()
        panel.showCentered()
        Task { await Skills.shared.learn(from: recording) }
    }

    // MARK: - Circle to point

    /// Hides the bar, lets the user draw a loop around something, then brings the bar back with it attached.
    /// While a task runs, the circle goes in as added context instead.
    @objc func startCircling() {
        rememberTarget()
        panel.orderOut(nil)
        overlay.begin { [weak self] circled in
            guard let self else { return }
            self.agent.targetApp?.activate()
            guard let circled else { if !self.agent.isRunning { self.panel.showCentered() }; return }
            if self.agent.isRunning {
                let r = circled.rect
                self.agent.addContext("I circled this area of the screen: x \(Int(r.minX))–\(Int(r.maxX)), y \(Int(r.minY))–\(Int(r.maxY)) (screen points).")
            } else {
                self.agent.annotation = circled
                self.panel.showCentered()
            }
        }
    }

    // MARK: - QA and schedules

    /// clinqy://qa?path=<test file>|text=<inline test>&out=<report.json>[&relearn=1][&model=…][&name=…]
    private func startQA(_ url: URL) {
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                           uniquingKeysWith: { a, _ in a })
        let out = URL(fileURLWithPath: q["out"] ?? NSTemporaryDirectory() + "clinqy-qa.json")
        var name = q["name"] ?? "Inline test"
        var test = q["text"] ?? ""
        var compiled: URL
        if let path = q["path"], !path.isEmpty {
            let file = URL(fileURLWithPath: path)
            let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            // A "# Title" line names the test; everything else is the steps.
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let title = lines.first(where: { $0.hasPrefix("# ") }) { name = String(title.dropFirst(2)) }
            else { name = file.deletingPathExtension().lastPathComponent }
            test = lines.filter { !$0.hasPrefix("# ") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // Compiled scripts live next to the tests, in .clinqy/, so they can be committed with them.
            compiled = file.deletingLastPathComponent().appendingPathComponent(".clinqy")
                .appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".json")
        } else {
            let key = SHA256.hash(data: Data(test.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
            compiled = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Clinqy/qa/\(key).json")
        }
        guard !test.isEmpty else {
            Agent.writeReport(QAReport(name: name, passed: false, mode: "none", durationMs: 0, steps: [], checks: [],
                                       message: "empty test"), to: out)
            return
        }
        rememberTarget()
        agent.runQA(name: name, test: test, compiled: compiled, relearn: q["relearn"] == "1",
                    model: q["model"].flatMap { $0.isEmpty ? nil : $0 }, report: out)
    }

    /// Runs workflows scheduled for this minute (checked every 30 s; once a day each).
    private var scheduler: Timer?

    private func startScheduler() {
        scheduler = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.agent.isRunning else { return }
                let now = Date()
                let hm = now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                for var wf in Workflows.shared.all where wf.schedule == hm {
                    if let last = wf.lastScheduledRun, Calendar.current.isDate(last, inSameDayAs: now) { continue }
                    wf.lastScheduledRun = now
                    Workflows.shared.update(wf)
                    Agent.writeLog("scheduled: \(wf.name) at \(hm)")
                    self.agent.runWorkflow(wf)
                    break
                }
            }
        }
    }

    // MARK: - Hotkey

    private func hotKeyDown() {
        // While watching, ⌃⌥ stops the recording and learns from it.
        if Recorder.shared.isRecording { stopWatching(); return }
        // While working, ⌃⌥ no longer stops (⏹ does): tap opens the bar to add context, hold talks.
        guard pressedAt == nil else { return }   // key repeat
        pressedAt = Date()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pressedAt != nil else { return }
                self.holdToTalk = true
                self.rememberTarget()
                self.panel.orderOut(nil)
                self.startListening(autoStop: false)
                self.island.show()
            }
        }
    }

    /// ⌃⌥ turned out to be part of another shortcut (⌃⌥ + some key): undo anything it started.
    private func hotKeyAbandoned() {
        holdTimer?.invalidate()
        if holdToTalk {
            voice.cancel()
            island.hide()
            buddy.mood = agent.isRunning ? .acting : .idle
        }
        pressedAt = nil
        holdToTalk = false
    }

    private func hotKeyUp() {
        holdTimer?.invalidate()
        defer { pressedAt = nil; holdToTalk = false }
        guard pressedAt != nil else { return }
        if holdToTalk {
            voice.stop()
            if voice.transcript.isEmpty { island.hide(); buddy.mood = .idle }
        } else {
            togglePanel()
        }
    }

    private func startListening(autoStop: Bool) {
        buddy.mood = .listening
        voice.start(autoStop: autoStop)
    }

    private func rememberTarget() {
        guard agent.question == nil, !agent.isRunning else { return }   // answering or steering, not starting anew
        let front = NSWorkspace.shared.frontmostApplication
        guard let front, front.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        agent.targetApp = front
        // Whatever the user had highlighted goes along with their request.
        agent.selectedText = AXEngine.selectedText(of: front)
        if agent.selectedText == nil, !Launcher.isBrowser(front) {
            agent.selectedText = AXEngine.copiedSelection(of: front)
        }
        if agent.selectedText == nil, Launcher.isBrowser(front), BrowserBridge.shared.isConnected {
            Task { [agent] in
                if let text = await BrowserBridge.shared.selection(), agent?.isRunning == false { agent?.selectedText = text }
            }
        }
    }

    // MARK: - Menu actions

    @objc func togglePanel() {
        if panel.isVisible { panel.orderOut(nil); return }
        rememberTarget()
        panel.showCentered()
    }

    @objc func toggleMic() {
        if voice.isListening { voice.stop(); return }
        rememberTarget()
        if !panel.isVisible { panel.showCentered() }
        startListening(autoStop: true)
    }

    @objc func openMemory() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/clinqy/memory.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    @objc func checkPermissions() {
        let lines = Permissions.all.map { "\($0.granted() ? "✅" : "❌")  \($0.name): \($0.why)" }
        let alert = NSAlert()
        alert.messageText = Permissions.allGranted ? "All permissions granted" : "Clinqy needs these permissions"
        alert.informativeText = lines.joined(separator: "\n") + """


        Claude CLI: \(ClaudeSession.claudePath ?? "❌ not found")

        After enabling something in System Settings, click Check Again. \
        Screen Recording may need Clinqy to be restarted.
        """
        alert.addButton(withTitle: "Check Again")
        let missing = Permissions.all.first { !$0.granted() }
        if missing != nil {
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "Done")
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Permissions.requestMissing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.checkPermissions() }
        case .alertSecondButtonReturn:
            if let missing, let url = URL(string: missing.settingsURL) {
                missing.request()
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }
}

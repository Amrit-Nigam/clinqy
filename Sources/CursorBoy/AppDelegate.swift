import AppKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        buddy = Buddy()
        agent = Agent(buddy: buddy)
        voice = Voice()
        panel = CommandPanel(agent: agent, voice: voice, onMic: { [weak self] in self?.toggleMic() },
                             onWatch: { [weak self] in self?.startWatching() })
        island = IslandPanel(agent: agent, voice: voice)
        resultPanel = ResultPanel(agent: agent)
        agent.onResult = { [weak self] in if self?.agent.result != nil { self?.resultPanel.show() } }
        Brain.prewarm()
        Whisper.shared.prepare()
        BrowserBridge.shared.start()

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
            if self.agent.question != nil { self.agent.answer(text) } else { self.agent.submit(text) }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "CursorBoy")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open CursorBoy  (⌥Space)", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Talk  (hold ⌥Space)", action: #selector(toggleMic), keyEquivalent: "")
        menu.addItem(withTitle: "Check Permissions…", action: #selector(checkPermissions), keyEquivalent: "")
        menu.addItem(withTitle: "Edit Memory…", action: #selector(openMemory), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
        self.menu = menu

        // ⌥Space: tap opens the bar, hold talks, and while working it stops.
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey),
                        onPress: { [weak self] in self?.hotKeyDown() },
                        onRelease: { [weak self] in self?.hotKeyUp() })

        if !Permissions.allGranted {
            Permissions.requestMissing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.checkPermissions() }
        }
    }

    /// `cursorboy://run?task=…` runs a task in whatever app is in front (used for scripting and tests).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "cursorboy" && url.host == "reload-extension" {
            Task { Agent.writeLog("extension reloaded in \(await BrowserBridge.shared.reloadAll()) browser(s)") }
        }
        for url in urls where url.scheme == "cursorboy" && url.host == "answer" {
            agent.answer(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value)
        }
        for url in urls where url.scheme == "cursorboy" && url.host == "cancel" { agent.cancel() }
        for url in urls where url.scheme == "cursorboy" && url.host == "watch" { rememberTarget(); startWatching() }
        for url in urls where url.scheme == "cursorboy" && url.host == "stop-watching" { stopWatching() }
        for url in urls where url.scheme == "cursorboy" && url.host == "run" {
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
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop CursorBoy")
            button.contentTintColor = .systemRed
            statusItem.menu = nil
            button.target = self
            button.action = #selector(stopFromMenuBar)
        } else {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "CursorBoy")
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

    // MARK: - Hotkey

    private func hotKeyDown() {
        // While watching, ⌥Space stops the recording and learns from it.
        if Recorder.shared.isRecording { stopWatching(); return }
        // While working, ⌥Space stops it — unless it's waiting on you, then it opens/talks as usual.
        if agent.isRunning, agent.question == nil { agent.cancel(); return }
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
        guard agent.question == nil else { return }   // answering, not starting something new
        let front = NSWorkspace.shared.frontmostApplication
        guard let front, front.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        agent.targetApp = front
        // Whatever the user had highlighted goes along with their request.
        agent.selectedText = AXEngine.selectedText(of: front)
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
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cursorboy/memory.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    @objc func checkPermissions() {
        let lines = Permissions.all.map { "\($0.granted() ? "✅" : "❌")  \($0.name): \($0.why)" }
        let alert = NSAlert()
        alert.messageText = Permissions.allGranted ? "All permissions granted" : "CursorBoy needs these permissions"
        alert.informativeText = lines.joined(separator: "\n") + """


        Claude CLI: \(ClaudeSession.claudePath ?? "❌ not found")

        After enabling something in System Settings, click Check Again. \
        Screen Recording may need CursorBoy to be restarted.
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

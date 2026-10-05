import AppKit
import CryptoKit
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    /// The current request was spoken (so a follow-up can be spoken too).
    private var voiceRun = false
    /// The mic is open for a follow-up after a finished task ("now email that to Rahul").
    private var followUpOpen = false

    func applicationWillTerminate(_ notification: Notification) {
        Persist.flush()
    }

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
        // Review before submit: the form's answers come up in the bar; it goes away once the user decides.
        UI.agent = agent
        UI.present = { [weak self] in self?.panel.showCentered(); self?.island.show() }
        UI.dismiss = { [weak self] in self?.panel.orderOut(nil) }
        enableOpenAtLogin()
        _ = Self.cliToken   // written now, so the clinqy command can read it before its first link
        installEditMenu()
        dismissOnOutsideClick()
        Brain.prewarm()
        // Vectors for memory and saved runs, in the background, so no request waits on embedding them.
        Embedder.shared.warm(Memory.facts + ReplayCache.shared.all.map(\.request))
        Whisper.shared.prepare()
        BrowserBridge.shared.start()
        Clipboard.start()
        startScheduler()

        agent.onStart = { [weak self] in
            guard let self else { return }
            self.setStatusIcon(running: true)
            StepUndo.shared.clear()
            // Keystrokes must reach the target app, and clicks must not land on our windows.
            self.panel.orderOut(nil)
            self.island.show()
        }
        agent.onFinish = { [weak self] answer, ok in
            guard let self else { return }
            UI.cancelReview()
            self.setStatusIcon(running: false)
            self.island.show(for: 4.5)
            // Stopped by the user: bring the bar back so they can say what to do differently ("no, the other one").
            if !ok, answer == "Stopped", !self.agent.isTest, !self.voiceRun {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, !self.agent.isRunning, !self.panel.isVisible, !Recorder.shared.isRecording else { return }
                    self.panel.showCentered()
                }
            }
            let spoken = self.voiceRun
            self.voiceRun = false
            if spoken, ok, !self.agent.isTest { self.listenForFollowUp() }
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
            let followUp = self.followUpOpen
            self.followUpOpen = false
            // A spoken reply to a question answers it; while working it steers; otherwise it's a new request.
            if self.agent.question != nil {
                self.agent.answer(text)
            } else if self.agent.isRunning {
                self.agent.addContext(text)
            } else if followUp, Router.isDismissal(text) {
                self.agent.continuation = nil
                self.island.hide()
            } else {
                self.voiceRun = true
                self.agent.submit(text)
            }
        }
        voice.onGaveUp = { [weak self] in
            guard let self else { return }
            self.followUpOpen = false
            if !self.agent.isRunning { self.agent.continuation = nil }
            self.buddy.mood = .idle
            self.island.hide()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Clinqy")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Clinqy  (⌃⌥)", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Talk  (hold ⌃⌥)", action: #selector(toggleMic), keyEquivalent: "")
        menu.addItem(withTitle: "Circle Something…", action: #selector(startCircling), keyEquivalent: "")
        menu.addItem(withTitle: "Check Permissions…", action: #selector(checkPermissions), keyEquivalent: "")
        menu.addItem(withTitle: "Edit Memory…", action: #selector(openMemory), keyEquivalent: "")
        menu.addItem(withTitle: "Applications…", action: #selector(showApplications), keyEquivalent: "")
        menu.addItem(withTitle: "Job Profile…", action: #selector(openProfile), keyEquivalent: "")
        menu.addItem(withTitle: "Stats…", action: #selector(showStats), keyEquivalent: "")
        let schedules = NSMenuItem(title: "Schedules", action: nil, keyEquivalent: "")
        let schedulesMenu = NSMenu()
        schedulesMenu.delegate = self   // rebuilt each time it opens
        schedules.submenu = schedulesMenu
        menu.addItem(schedules)
        menu.addItem(withTitle: "Tidy Memory", action: #selector(tidyMemory), keyEquivalent: "")
        menu.addItem(.separator())
        let dry = menu.addItem(withTitle: "Dry Run (show, don't act)", action: #selector(toggleDryRun(_:)), keyEquivalent: "")
        dry.state = agent.dryRun ? .on : .off
        let follow = menu.addItem(withTitle: "Follow My Cursor", action: #selector(toggleFollowCursor(_:)), keyEquivalent: "")
        follow.state = buddy.followsMouse ? .on : .off
        let language = NSMenuItem(title: "Voice Language", action: nil, keyEquivalent: "")
        let languages = NSMenu()
        for (code, name) in Whisper.languages {
            let item = languages.addItem(withTitle: name, action: #selector(setVoiceLanguage(_:)), keyEquivalent: "")
            item.representedObject = code
            item.target = self
            item.state = Whisper.language == code ? .on : .off
        }
        language.submenu = languages
        menu.addItem(language)
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
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

    /// A secret only local programs can read (~/.config/clinqy/cli-token, owner-only). Every clinqy:// link must
    /// carry it: any web page can open a clinqy:// link, and must never be able to start tasks, answer questions
    /// ("Yes, send it") or write files.
    static let cliToken: String = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/clinqy/cli-token")
        if let saved = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), saved.count >= 32 {
            return saved
        }
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }()

    /// `clinqy://run?task=…&token=…` runs a task in whatever app is in front (used for scripting and tests).
    func application(_ application: NSApplication, open urls: [URL]) {
        let urls = urls.filter { url in
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value
            guard url.scheme == "clinqy", token == Self.cliToken else {
                Agent.writeLog("ignored a clinqy:// link without the right token (host: \(url.host ?? "?"))")
                return false
            }
            return true
        }
        for url in urls where url.host == "browser" { Task { await answerBrowserQuery(url) } }
        for url in urls where url.scheme == "clinqy" && url.host == "reload-extension" {
            Task { Agent.writeLog("extension reloaded in \(await BrowserBridge.shared.reloadAll()) browser(s)") }
        }
        for url in urls where url.scheme == "clinqy" && url.host == "answer" {
            agent.answer(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value)
        }
        for url in urls where url.scheme == "clinqy" && url.host == "cancel" { agent.cancel() }
        // Same as the Undo button on the latest reversible step (voice, scripts, tests/run.sh).
        for url in urls where url.scheme == "clinqy" && url.host == "undo" { Task { await StepUndo.shared.undoLast(agent: agent) } }
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
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let test = items.first { $0.name == "test" }?.value == "1"
            let dry = items.first { $0.name == "dry" }?.value == "1"
            if items.first(where: { $0.name == "agy" })?.value == "1" {
                Provider.useAgy = true
            } else if items.first(where: { $0.name == "claude" })?.value == "1" {
                Provider.useAgy = false
            }
            // Tests skip the review card unless they ask for it (tests/run.sh answers it through clinqy://answer).
            agent.reviewInTests = items.first { $0.name == "review" }?.value == "1"
            agent.saveInTests = items.first { $0.name == "save" }?.value == "1"
            agent.submit(dry ? "dry run: " + task : task, test: test)
        }
    }

    /// `clinqy://browser?cmd=page|read|url&id=…`: what's in the focused browser tab, for the `clinqy page` command
    /// (read-only). The answer goes to Application Support/Clinqy/cli/<id>.txt, which the command waits for.
    private func answerBrowserQuery(_ url: URL) async {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let id = items.first(where: { $0.name == "id" })?.value, id.range(of: #"^[A-Za-z0-9-]{1,40}$"#, options: .regularExpression) != nil
        else { return }
        let cmd = items.first { $0.name == "cmd" }?.value ?? "page"
        var out: String
        if !BrowserBridge.shared.isConnected {
            out = "ERROR: the Clinqy browser extension isn't connected (open the browser; load extension/ from the repo)"
        } else if let page = await BrowserBridge.shared.snapshot() {
            switch cmd {
            case "url": out = "\(page.title)\n\(page.url)"
            case "read":
                let r = try? await BrowserBridge.shared.perform("read", on: page, timeout: 8)
                out = "\(page.title)\n\(page.url)\n\n\((r?["text"] as? String) ?? page.text)"
            default:
                var lines = ["\(page.title)", page.url]
                if let problem = page.problem { lines.append("(can't read this page: \(problem))") }
                lines += page.elements.map { "w\($0.index) \($0.role): \($0.text)\($0.extra.isEmpty ? "" : " [\($0.extra)]")" }
                if !page.messages.isEmpty { lines.append("Messages: " + page.messages.joined(separator: " · ")) }
                if page.above + page.below > 0 { lines.append("Not shown: \(page.above) fields/buttons above, \(page.below) below") }
                if !page.text.isEmpty { lines.append("Text on screen: " + page.text) }
                out = lines.joined(separator: "\n")
            }
        } else {
            out = "ERROR: no focused browser tab (click into the browser window first)"
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clinqy/cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? out.write(to: dir.appendingPathComponent("\(id).txt"), atomically: true, encoding: .utf8)
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
        if q["agy"] == "1" { Provider.useAgy = true }
        else if q["claude"] == "1" { Provider.useAgy = false }
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

    /// Runs workflows scheduled for this minute (checked every 30 s; once a day each), and scheduled requests
    /// (Scheduler) once they're due.
    private var scheduler: Timer?

    private func startScheduler() {
        scheduler = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.agent.isRunning, self.agent.question == nil, !Recorder.shared.isRecording else { return }
                if let item = Scheduler.takeDue() {
                    Agent.writeLog("scheduled request: \(item.request) (\(item.rule.label))")
                    // Whatever is in front when it fires; nothing selected or copied rides along.
                    let front = NSWorkspace.shared.frontmostApplication
                    if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier { self.agent.targetApp = front }
                    self.agent.selectedText = nil
                    self.agent.selectedFiles = []
                    self.agent.copied = nil
                    self.agent.annotation = nil
                    self.agent.continuation = nil
                    self.agent.submit(item.request)
                    return
                }
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

    /// After a spoken task, keep listening a few seconds for a follow-up that builds on it ("now email that to
    /// Rahul"), without pressing ⌃⌥ again. Silence closes the mic. FOLLOW_UP=off turns it off.
    private func listenForFollowUp() {
        guard !["off", "0", "no", "false"].contains((Config.value("FOLLOW_UP") ?? "on").lowercased()) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, !self.agent.isRunning, self.agent.question == nil, !self.voice.isListening,
                  !Recorder.shared.isRecording, !self.panel.isVisible else { return }
            self.agent.continuation = History.shared.entries.first
            self.followUpOpen = true
            self.island.show()
            self.buddy.mood = .listening
            self.voice.start(autoStop: true, giveUpAfter: 5)
        }
    }

    private func rememberTarget() {
        guard agent.question == nil, !agent.isRunning else { return }   // answering or steering, not starting anew
        let front = NSWorkspace.shared.frontmostApplication
        guard let front, front.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        agent.targetApp = front
        // Files selected in Finder ride along instead of text ("compress this", "merge these").
        agent.selectedFiles = front.bundleIdentifier == "com.apple.finder" ? AXEngine.copiedFiles(of: front) : []
        agent.copied = nil
        guard agent.selectedFiles.isEmpty else { agent.selectedText = nil; return }
        // Whatever the user had highlighted goes along with their request.
        agent.selectedText = AXEngine.selectedText(of: front)
        if agent.selectedText == nil, !Launcher.isBrowser(front) {
            agent.selectedText = AXEngine.copiedSelection(of: front)
        }
        // Nothing highlighted: something they copied a moment ago may be what "this" means.
        if agent.selectedText == nil, let c = Clipboard.recent() {
            agent.copied = .init(text: c.text, files: c.files, age: c.age)
        }
        if agent.selectedText == nil, Launcher.isBrowser(front), BrowserBridge.shared.isConnected {
            Task { [agent] in
                if let text = await BrowserBridge.shared.selection(in: front), agent?.isRunning == false { agent?.selectedText = text }
            }
        }
    }

    // MARK: - Menu actions

    /// Clicking anywhere outside the command bar puts it away, like Spotlight. Not while it's asking a question
    /// or listening (the answer is still needed). Clicks on Clinqy's own windows never reach a global monitor.
    private func dismissOnOutsideClick() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, self.agent.question == nil, ReviewCenter.shared.pending == nil,
                      !self.voice.isListening else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// A menu-bar app has no main menu, and without an Edit menu ⌘V/⌘C/⌘X/⌘A/⌘Z never reach text fields.
    /// This one is never shown; it only carries the shortcuts.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Clinqy", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Starts with the Mac by default (installed copy only), unless the user switched it off in the menu.
    private func enableOpenAtLogin() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: "openAtLoginOff"),
              SMAppService.mainApp.status != .enabled else { return }
        try? SMAppService.mainApp.register()
    }

    @objc func toggleOpenAtLogin(_ item: NSMenuItem) {
        let on = SMAppService.mainApp.status == .enabled
        do {
            if on { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            UserDefaults.standard.set(on, forKey: "openAtLoginOff")
        } catch {
            NSLog("Clinqy: open at login: \(error)")
        }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

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

    @objc func showApplications() { agent.showApplications() }

    @objc func openProfile() { Profile.open() }

    @objc func showStats() {
        agent.result = StatsCard.card
        agent.onResult()
    }

    // MARK: - Schedules menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = Scheduler.all
        if items.isEmpty {
            let none = menu.addItem(withTitle: "Nothing scheduled", action: nil, keyEquivalent: "")
            none.isEnabled = false
        }
        for item in items {
            let title = "\(item.request.prefix(50))\(item.request.count > 50 ? "…" : "")  ·  \(Scheduler.describe(item))"
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let run = sub.addItem(withTitle: "Run Now", action: #selector(runScheduleNow(_:)), keyEquivalent: "")
            run.representedObject = item.request
            run.target = self
            let remove = sub.addItem(withTitle: "Remove", action: #selector(removeSchedule(_:)), keyEquivalent: "")
            remove.representedObject = item.id
            remove.target = self
            row.submenu = sub
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let add = menu.addItem(withTitle: "New Schedule…", action: #selector(newSchedule), keyEquivalent: "")
        add.target = self
    }

    @objc func removeSchedule(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID else { return }
        Scheduler.remove(id)
    }

    @objc func runScheduleNow(_ item: NSMenuItem) {
        guard let request = item.representedObject as? String, !agent.isRunning else { return }
        agent.continuation = nil
        agent.submit(request)
    }

    /// Asks for a request and when to run it ("every weekday at 9", "tomorrow 8:30", "in 20 minutes").
    @objc func newSchedule() {
        let alert = NSAlert()
        alert.messageText = "Schedule a task"
        alert.informativeText = "When: “at 9am”, “tomorrow 8:30”, “in 20 minutes”, “every weekday at 9”, “daily 18:00”, “every hour”."
        let request = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        request.placeholderString = "What should I do? e.g. check placement mail"
        let when = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        when.placeholderString = "When? e.g. every weekday at 9"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        box.addSubview(request)
        box.addSubview(when)
        alert.accessoryView = box
        alert.window.initialFirstResponder = request
        alert.addButton(withTitle: "Schedule")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = request.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let done = NSAlert()
        if let line = Scheduler.add(request: text, phrase: when.stringValue) {
            done.messageText = "Scheduled"
            done.informativeText = line
        } else {
            done.messageText = "I couldn't read “\(when.stringValue)” as a time"
            done.informativeText = "Try “at 9am”, “tomorrow 8:30”, “in 20 minutes” or “every weekday at 9”."
        }
        done.runModal()
    }

    @objc func toggleDryRun(_ item: NSMenuItem) {
        agent.dryRun.toggle()
        item.state = agent.dryRun ? .on : .off
    }

    @objc func toggleFollowCursor(_ item: NSMenuItem) {
        buddy.followsMouse.toggle()
        item.state = buddy.followsMouse ? .on : .off
    }

    @objc func setVoiceLanguage(_ item: NSMenuItem) {
        guard let code = item.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: "voiceLanguage")
        for other in item.menu?.items ?? [] { other.state = (other.representedObject as? String) == code ? .on : .off }
    }

    @objc func tidyMemory() {
        Task {
            let report = await MemoryTidy.run() ?? "Memory is already tidy (or the tidy-up would have lost details, so it was skipped)"
            let alert = NSAlert()
            alert.messageText = "Memory"
            alert.informativeText = report
            alert.runModal()
        }
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


        Model: \(Provider.current.label)
        Calendars & Reminders: \(Events.hasAccess ? "✅" : "asked the first time you schedule something")

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

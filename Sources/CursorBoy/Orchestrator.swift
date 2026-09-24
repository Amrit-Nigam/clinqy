import AppKit

/// Runs each request through the fast local loop (Jev picks, we act and verify). agy runs only on an explicit "agy " prefix.
@MainActor
final class Orchestrator: ObservableObject {
    struct LogLine: Identifiable {
        enum Kind { case user, info, tool, agent, error, done }
        let id = UUID()
        let kind: Kind
        var text: String
    }

    @Published var log: [LogLine] = []
    @Published var isRunning = false
    @Published var input = ""

    private let buddy: BuddyCursor
    private let agy = AgyRunner()
    /// The app the user was in when they opened the panel; that's what "click X" refers to.
    var targetApp: NSRunningApplication?

    init(buddy: BuddyCursor) {
        self.buddy = buddy
    }

    func submit(_ raw: String) {
        let request = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isRunning else { return }
        requestStart = Date()
        append(.user, request)
        isRunning = true
        Task { await handle(request) }
    }

    func cancel() {
        agy.cancel()
        finish()
    }

    func clear() {
        guard !isRunning else { return }
        log.removeAll()
    }

    /// Called to get the panel out of the way so keystrokes reach the target app.
    var hidePanel: () -> Void = {}
    var showPanel: () -> Void = {}

    private func handle(_ request: String) async {
        if request.lowercased().hasPrefix("agy ") {
            return runAgent(String(request.dropFirst(4)))
        }
        var task = request
        if let (app, rest) = await openAppPrefix(request) {
            guard let rest else { return finish() }
            targetApp = app
            task = rest
        } else if await tryType(request) {
            return finish()
        }

        guard AXEngine.isTrusted else {
            append(.error, "Accessibility permission is off. Enable CursorBoy in System Settings → Privacy & Security → Accessibility.")
            return finish()
        }

        // Jev decides in parallel whether the request belongs in a different app ("say hi to jd" → WhatsApp).
        let route = Task { await routeApp(task) }
        guard let app = targetApp ?? NSWorkspace.shared.frontmostApplication else {
            append(.error, "No app to act on")
            return finish()
        }

        hidePanel()
        // Jev drives (fast); the Claude planner only takes over from where Jev got unsure.
        var outcome = await actLoop(task: task, app: app, route: route)
        if case .handoff(let history) = outcome {
            if Planner.isAvailable {
                append(.info, "Jev unsure, asking Claude to plan the rest…")
                outcome = await planLoop(task: task, app: targetApp ?? app, history: history)
            } else {
                outcome = .stuck("Jev wasn't sure what to do next")
            }
        }
        showPanel()
        switch outcome {
        case .done: append(.done, "Done")
        case .stuck(let why): append(.error, why)
        case .handoff: append(.error, "Stopped")
        }
        finish()
    }

    /// One Jev choice over installed apps; nil means "stay in the current app".
    func routeApp(_ task: String) async -> URL? {
        let current = targetApp?.localizedName?.replacingOccurrences(of: "\u{200E}", with: "") ?? "none"
        let apps = Self.installedApps()
        var criteria: [String: Any] = [
            "current": "Stay in \(current)\(Self.appKind(current).map { ", \($0)" } ?? "") — only if the request is about something in this app",
        ]
        let running = Set(NSWorkspace.shared.runningApplications.compactMap {
            $0.localizedName?.replacingOccurrences(of: "\u{200E}", with: "").lowercased()
        })
        for (i, app) in apps.prefix(240).enumerated() {
            let open = running.contains(app.name.lowercased()) ? " (open now, the user's usual choice)" : ""
            criteria["a\(i)"] = (Self.appKind(app.name).map { "\(app.name): \($0)" } ?? app.name) + open
        }
        do {
            let answers = try await Jev.ask(
                state: ["request": task, "currentApp": current],
                questions: [
                    "messaging": Jev.noul(
                        "Is `request` about sending, saying, telling, replying or writing something to a person or a group (a chat message)?",
                        yes: "It's a message to someone", no: "It's something else"),
                    "app": Jev.choice(
                    "Which app should `request` be carried out in? Messaging or saying something to a person or group belongs in a messaging app; websites and web searches in a browser; notes in a notes app. Among apps of the right kind, prefer one that's open now. Stay in `currentApp` only if the request is about what's in it.",
                    criteria)])
            let messaging = answers["messaging"]?.noul ?? 0
            let answer = messaging >= 0.6
                ? apps.firstIndex(where: { $0.name == "WhatsApp" || Self.appKind($0.name)?.hasPrefix("messaging") == true })
                    .map { Jev.Answer(choice: "a\($0)", confidence: 1, noul: nil, probabilities: ["a\($0)": messaging]) }
                : answers["app"]
            if echo {
                let k = answer?.choice ?? "-"
                let name = k == "current" ? "current" : Int(k.dropFirst()).map { apps[$0].name } ?? k
                print("   route → \(name) p=\(answer?.topProbability ?? 0)")
            }
            guard let key = answer?.choice, key != "current", (answer?.topProbability ?? 0) >= 0.55,
                  let i = Int(key.dropFirst()), i < apps.count else { return nil }
            var pick = apps[i]
            // Messaging: use the preferred messenger (config MESSENGER, else the first running one, WhatsApp first).
            if Self.appKind(pick.name)?.hasPrefix("messaging") == true {
                let order = [Config.value("MESSENGER"), "WhatsApp", "Telegram", "Slack", "Discord", "Signal", "Messages"].compactMap { $0 }
                let running = NSWorkspace.shared.runningApplications.compactMap {
                    $0.localizedName?.replacingOccurrences(of: "\u{200E}", with: "").lowercased()
                }
                if let preferred = order.first(where: { name in running.contains(name.lowercased()) && apps.contains { $0.name.lowercased() == name.lowercased() } })
                    ?? order.first(where: { name in apps.contains { $0.name.lowercased() == name.lowercased() } }),
                   let match = apps.first(where: { $0.name.lowercased() == preferred.lowercased() }) {
                    pick = match
                }
                if Self.appKind(current)?.hasPrefix("messaging") == true, current.lowercased() == pick.name.lowercased() { return nil }
            }
            if pick.name.lowercased() == current.lowercased() { return nil }
            append(.info, "Switching to \(pick.name)")
            return pick.url
        } catch {
            return nil
        }
    }

    /// Opens a URL as a real tab (Arc sends external links to its "Little Arc" popup, so script it instead).
    static func openInBrowser(_ url: URL, app: NSRunningApplication) async {
        if app.bundleIdentifier == "company.thebrowser.Browser" {
            let script = "tell application \"Arc\" to tell front window to make new tab with properties {URL:\"\(url.absoluteString)\"}"
            let ok = await Task.detached { () -> Bool in
                var error: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&error)
                return error == nil
            }.value
            if ok { return }
        }
        if let appURL = app.bundleURL {
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: .init())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Web tasks that are really "search X on <site>" or "open <site>": Jev picks the site and the words, code builds the URL.
    static func webShortcut(task: String, spans: [String]) async -> URL? {
        let sites: [String: (String, String?)] = [   // id: (home, search URL prefix)
            "youtube": ("https://www.youtube.com", "https://www.youtube.com/results?search_query="),
            "google": ("https://www.google.com", "https://www.google.com/search?q="),
            "github": ("https://github.com", "https://github.com/search?q="),
            "amazon": ("https://www.amazon.in", "https://www.amazon.in/s?k="),
            "wikipedia": ("https://en.wikipedia.org", "https://en.wikipedia.org/w/index.php?search="),
            "reddit": ("https://www.reddit.com", "https://www.reddit.com/search/?q="),
            "x": ("https://x.com", "https://x.com/search?q="),
            "gmail": ("https://mail.google.com", nil),
            "maps": ("https://maps.google.com", "https://www.google.com/maps/search/"),
            "spotify": ("https://open.spotify.com", "https://open.spotify.com/search/"),
        ]
        var siteCriteria: [String: Any] = ["other": "Some other website or not a website task"]
        for id in sites.keys { siteCriteria[id] = id == "x" ? "X / Twitter" : id }
        var spanCriteria: [String: Any] = ["none": "No search — just open the site"]
        for (i, span) in spans.enumerated() { spanCriteria["s\(i)"] = "\"\(span)\"" }
        guard let answers = try? await Jev.ask(
            state: ["request": task],
            questions: [
                "simple": Jev.noul("Is `request` only about opening a website or searching for something on a website (nothing else to do after)?",
                                   yes: "Just open or search a site", no: "More steps, or not a website task"),
                "site": Jev.choice("Which website is `request` about? For a general web search, choose google.", siteCriteria),
                "query": Jev.choice("What exact words from `request` should be searched for? Just the search terms, without the site name or verbs.", spanCriteria),
            ]) else { return nil }
        guard (answers["simple"]?.noul ?? 0) >= 0.6, let site = answers["site"]?.choice, let entry = sites[site],
              (answers["site"]?.topProbability ?? 0) >= 0.6 else { return nil }
        if let q = answers["query"]?.choice, q != "none", let i = Int(q.dropFirst()), i < spans.count, let prefix = entry.1 {
            let encoded = spans[i].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? spans[i]
            return URL(string: prefix + encoded)
        }
        return URL(string: entry.0)
    }

    /// One-line purpose for well-known apps, so routing can match what a request needs.
    static func appKind(_ name: String) -> String? {
        let kinds: [(String, [String])] = [
            ("messaging app: send messages to people and groups", ["whatsapp", "messages", "telegram", "signal", "discord", "slack", "messenger"]),
            ("web browser: websites, web search, YouTube", ["arc", "safari", "google chrome", "chrome", "firefox", "brave browser", "microsoft edge", "dia", "comet"]),
            ("notes app", ["notes", "obsidian", "notion", "bear"]),
            ("email app", ["mail", "spark", "outlook", "superhuman"]),
            ("code editor", ["cursor", "xcode", "visual studio code", "zed", "windsurf"]),
            ("terminal", ["terminal", "iterm", "warp", "ghostty"]),
            ("music player", ["spotify", "music"]),
            ("calendar", ["calendar", "fantastical", "notion calendar"]),
            ("reminders / to-do list", ["reminders", "things3", "todoist"]),
        ]
        let lower = name.lowercased().replacingOccurrences(of: "\u{200E}", with: "")
        return kinds.first { $0.1.contains(lower) }?.0
    }

    private static func installedApps() -> [(name: String, url: URL)] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [(String, URL)] = []
        for dir in ["/Applications", "\(fm.homeDirectoryForCurrentUser.path)/Applications", "/System/Applications",
                    "/System/Applications/Utilities"] {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                if seen.insert(name.lowercased()).inserted { result.append((name, URL(fileURLWithPath: "\(dir)/\(item)"))) }
            }
        }
        return result
    }

    // MARK: - Local shortcuts (no model needed)

    /// Handles "open X" and "open X and/then <rest>". Returns nil if no app matched.
    private func openAppPrefix(_ request: String) async -> (NSRunningApplication, String?)? {
        let lower = request.lowercased()
        guard lower.hasPrefix("open ") else { return nil }
        let words = request.dropFirst(5).split(separator: " ").map(String.init)
        // Try the longest app name first: "open visual studio code and ..." etc.
        for count in stride(from: min(words.count, 4), through: 1, by: -1) {
            let name = words.prefix(count).joined(separator: " ")
            guard let url = Self.findApp(named: name) else { continue }
            var rest = words.dropFirst(count).joined(separator: " ")
            for joiner in ["and then ", "then ", "and ", ", "] where rest.lowercased().hasPrefix(joiner) {
                rest = String(rest.dropFirst(joiner.count))
                break
            }
            append(.info, "Opening \(url.deletingPathExtension().lastPathComponent)")
            guard let app = await launch(url) else { return nil }
            return (app, rest.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rest)
        }
        return nil
    }

    private func bringToFront(_ app: NSRunningApplication) async {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else { return }
        // Plain activate() is ignored when we aren't frontmost; opening the app always brings it forward.
        if let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            app.activate()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Opens (or reopens the window of) an app and waits until it's frontmost with UI loaded.
    private func launch(_ url: URL) async -> NSRunningApplication? {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: config) else { return nil }
        // `open` on an already-running app with its window closed brings the window back.
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        reopen.arguments = [url.path]
        try? reopen.run()
        for _ in 0..<30 {
            if app.isActive, AXEngine.elements(of: app, limit: 5).count > 1 { break }
            app.activate()
            try? await Task.sleep(for: .milliseconds(100))
        }
        return app
    }

    private func tryType(_ request: String) async -> Bool {
        guard request.lowercased().hasPrefix("type ") else { return false }
        let text = String(request.dropFirst(5))
        hidePanel()
        targetApp?.activate()
        try? await Task.sleep(for: .milliseconds(150))
        AXEngine.type(text)
        showPanel()
        append(.info, "Typed \(text.count) characters")
        return true
    }

    private static func findApp(named name: String) -> URL? {
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "\(fm.homeDirectoryForCurrentUser.path)/Applications"]
        let target = name.lowercased()
        var fuzzy: URL?
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let base = item.dropLast(4).lowercased()
                if base == target { return URL(fileURLWithPath: "\(dir)/\(item)") }
                if fuzzy == nil, target.count >= 3, base.hasPrefix(target) {
                    fuzzy = URL(fileURLWithPath: "\(dir)/\(item)")
                }
            }
        }
        return fuzzy
    }

    // MARK: - Fast path: see → Jev picks next action → act → repeat

    enum LoopOutcome { case done, stuck(String), handoff([String]) }

    private enum Action: Equatable {
        case click(Int), type(Int, String), enter, key(String), scroll(Int32), openURL(URL)
    }

    static let browserIDs: Set<String> = [
        "company.thebrowser.Browser", "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.dia",
    ]

    /// Keyboard actions Jev can choose: id → (description, key code, modifiers).
    static let keyActions: [String: (String, CGKeyCode, CGEventFlags)] = [
        "key_esc": ("Press Escape to close a popup, menu or dialog", 0x35, []),
        "key_tab": ("Press Tab to move to the next field", 0x30, []),
        "key_down": ("Press the Down arrow to move to the next item or result", 0x7D, []),
        "key_up": ("Press the Up arrow to move to the previous item", 0x7E, []),
        "key_cmd_f": ("Press ⌘F to open find/search in this app", 0x03, .maskCommand),
        "key_cmd_n": ("Press ⌘N to create something new (new chat, document, window, note, email)", 0x2D, .maskCommand),
        "key_cmd_t": ("Press ⌘T to open a new tab", 0x11, .maskCommand),
        "key_cmd_w": ("Press ⌘W to close the current tab or window", 0x0D, .maskCommand),
        "key_cmd_l": ("Press ⌘L to focus the browser address bar", 0x25, .maskCommand),
        "key_cmd_enter": ("Press ⌘Return to send or submit where plain Return adds a new line", 0x24, .maskCommand),
    ]

    struct Decision {
        let key: String
        let probability: Double
        let done: Double
        let absent: Double
        let ms: Int
        var destOpen: Double = 0
        /// Which request span Jev thinks should be typed, if any.
        var typeSpan: Int? = nil
        var typeProbability: Double = 0
        var needsWriting: Double = 0
    }

    // MARK: - Plan once with GPT, execute fast, re-plan only on failure

    private func planLoop(task: String, app startApp: NSRunningApplication, history startHistory: [String] = []) async -> LoopOutcome {
        var app = startApp
        var history = startHistory
        var problem: String?
        var lastPlan: [String] = []
        let installed = Self.installedApps().map(\.name)
        defer { AXEngine.targetPid = nil }
        AXEngine.targetPid = app.processIdentifier
        var verified = false
        app.activate()
        try? await Task.sleep(for: .milliseconds(150))

        for attempt in 0...3 {
            guard isRunning else { return .stuck("Stopped") }
            let appName = app.localizedName?.replacingOccurrences(of: "\u{200E}", with: "") ?? "?"
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.localizedName?.replacingOccurrences(of: "\u{200E}", with: "") }
            let elements = AXEngine.elements(of: app, limit: 150)
            let focus = AXEngine.focusSummary(of: app)
            buddy.setLabel(attempt == 0 ? "planning…" : "re-planning…")
            let started = Date()
            let plan: (steps: [Planner.PlannedStep], reason: String)
            do {
                let image = await Screenshot.annotated(app: app, elements: elements)
                plan = try await Planner.plan(task: task, app: appName, focused: focus.focused, history: history,
                                              elements: elements, screenshot: image, problem: problem,
                                              isBrowser: Self.browserIDs.contains(app.bundleIdentifier ?? ""),
                                              runningApps: running, installedApps: installed)
            } catch {
                return .stuck(error.localizedDescription)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if plan.steps.isEmpty { return history.isEmpty ? .stuck("Nothing to do: \(plan.reason)") : .done }
            if plan.steps.first?.action == .fail { return .stuck("Can't do this here: \(plan.reason)") }
            let summary = plan.steps.map(\.summary)
            if summary == lastPlan { return .stuck("The new plan was the same as the one that just failed, so I stopped") }
            lastPlan = summary
            append(.info, "\(attempt == 0 ? "plan" : "re-plan") (\(ms) ms): " + summary.joined(separator: " → "))

            problem = nil
            for step in plan.steps {
                guard isRunning else { return .stuck("Stopped") }
                if step.action == .open_app {
                    guard let name = step.text, let next = await switchTo(appNamed: name) else {
                        problem = "couldn't open app \(step.text ?? "?")"
                        append(.error, problem!)
                        break
                    }
                    app = next
                    targetApp = next
                    AXEngine.targetPid = next.processIdentifier
                    history.append("switched to \(name)")
                    append(.info, "switched to \(name)")
                    continue
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                    return .stuck("You switched apps, so I stopped before acting in the wrong place")
                }
                if step.action == .open_url, !Self.browserIDs.contains(app.bundleIdentifier ?? "") {
                    problem = "open_url is only allowed in a browser (current app: \(appName)); use open_app first or navigate in this app"
                    append(.error, problem!)
                    break
                }
                if let failure = await execute(step, task: task, app: app, history: &history) {
                    problem = failure
                    append(.error, failure)
                    break
                }
            }
            if problem == nil {
                // Confirm the whole request actually looks done before saying so; otherwise re-plan once.
                if verified || !history.contains(where: { $0.contains("(no visible change)") }) { return .done }
                verified = true
                try? await Task.sleep(for: .milliseconds(250))
                let after = AXEngine.elements(of: app, limit: 150)
                let done = (try? await Jev.ask(
                    state: ["request": task, "actionsTaken": history,
                            "screen": after.map { "\($0.role.dropFirst(2)): \($0.label)" }],
                    questions: ["done": Jev.noul(
                        "Judging by `screen` and `actionsTaken`, has every part of `request` been carried out?",
                        yes: "Everything asked is done", no: "Something asked is still missing")]
                ))?["done"]?.noul ?? 1
                if done >= 0.4 { return .done }
                problem = "after the plan, the request still doesn't look complete (p done \(String(format: "%.2f", done)))"
                append(.error, "Not finished yet, checking again…")
            }
        }
        return .stuck("Couldn't finish after 3 re-plans")
    }

    private func switchTo(appNamed name: String) async -> NSRunningApplication? {
        let wanted = name.lowercased()
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.replacingOccurrences(of: "\u{200E}", with: "").lowercased() == wanted
        }), let url = running.bundleURL {
            return await launch(url)
        }
        guard let url = Self.findApp(named: name) else { return nil }
        return await launch(url)
    }

    /// Runs one planned step. Returns a description of the failure, or nil on success.
    private func execute(_ step: Planner.PlannedStep, task: String, app: NSRunningApplication,
                         history: inout [String]) async -> String? {
        let before = AXEngine.fingerprint(of: app)
        switch step.action {
        case .click, .type:
            let elements = AXEngine.elements(of: app, limit: 150)
            guard let target = step.target, let (index, how) = await ground(target, in: elements, typing: step.action == .type) else {
                return "couldn't find \"\(step.target ?? "?")\" on screen"
            }
            let el = elements[index]
            if step.action == .click {
                append(.info, "click \"\(el.label.prefix(50))\"  (\(how))")
                history.append("clicked \(el.role.dropFirst(2)) \"\(el.label.prefix(60))\"")
                await pressOrClick(el, app: app, before: before)
            } else {
                guard let text = step.text, !text.isEmpty else { return "type step without text" }
                // Last line of defence before text reaches a person: is this box right, right now?
                let ok = (try? await Self.fieldCheck(text: text, task: task, field: el, elements: elements)) ?? 0
                guard ok >= 0.5 else {
                    return "\"\(el.label.prefix(40))\" didn't look like the right place for \"\(text.prefix(30))\" (p \(String(format: "%.2f", ok)))"
                }
                append(.info, "type \"\(text.prefix(60))\" into \(el.label.prefix(30))  (\(how), check \(String(format: "%.2f", ok)))")
                history.append("typed \"\(text.prefix(80))\" into \(el.role.dropFirst(2)) \"\(el.label.prefix(50))\"")
                await click(el)
                _ = AXEngine.focus(el.element)
                try? await Task.sleep(for: .milliseconds(100))
                buddy.setLabel("typing…")
                if !(await enterVerified(text, app: app)) {
                    return "the text didn't go into \"\(el.label.prefix(30))\" completely"
                }
            }
        case .key:
            guard let id = step.key.flatMap(Planner.keyAction) else { return "unknown key \(step.key ?? "")" }
            append(.info, "press \(step.key!)")
            history.append("pressed \(step.key!)")
            if id == "enter" { AXEngine.pressReturn() } else {
                let (_, code, flags) = Self.keyActions[id]!
                AXEngine.press(code, flags: flags)
            }
        case .scroll:
            append(.info, "scroll \(step.key ?? "down")")
            history.append("scrolled \(step.key ?? "down")")
            AXEngine.scroll(step.key == "up" ? 8 : -8, in: app)
        case .open_url:
            guard let raw = step.text, let url = URL(string: raw.hasPrefix("http") ? raw : "https://\(raw)") else {
                return "invalid URL"
            }
            append(.info, "open \(url.absoluteString.prefix(70))")
            history.append("opened \(url.absoluteString)")
            await Self.openInBrowser(url, app: app)
            try? await Task.sleep(for: .milliseconds(300))
            return nil
        case .applescript:
            guard let source = step.text, !source.isEmpty else { return "empty AppleScript" }
            append(.info, step.summary)
            history.append("ran AppleScript: \(source.prefix(120))")
            let result: (ok: Bool, message: String) = await Task.detached {
                var error: NSDictionary?
                let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error { return (false, error[NSAppleScript.errorMessage] as? String ?? "AppleScript error") }
                return (true, output?.stringValue ?? "")
            }.value
            if !result.ok { return "AppleScript failed: \(result.message)" }
            if !result.message.isEmpty { append(.agent, result.message) }
            return nil
        case .done, .open_app:
            return nil
        case .fail:
            return "planner gave up"
        }

        // The screen should react; if it doesn't, the step missed.
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(100))
            if AXEngine.fingerprint(of: app) != before {
                try? await Task.sleep(for: .milliseconds(120))
                return nil
            }
        }
        history[history.count - 1] += " (no visible change)"
        // Clicking something already selected/open legitimately changes nothing; let the next step decide.
        if step.action == .click { return nil }
        return "nothing changed after: \(step.summary)"
    }

    /// Replaces the focused field's contents with `text` and confirms it's all there (one retry through
    /// system-wide input, which some apps need). Never leaves partial text for a following Return to send.
    private func enterVerified(_ text: String, app: NSRunningApplication) async -> Bool {
        for attempt in 0..<2 {
            if attempt == 1 {
                AXEngine.targetPid = nil
                app.activate()
                try? await Task.sleep(for: .milliseconds(100))
            }
            AXEngine.selectAll()
            AXEngine.enter(text)
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(80))
                if AXEngine.fieldHolds(text, in: app) { return true }
            }
            if echo { print("   field has: \((AXEngine.focusedValue(of: app) ?? "nil").debugDescription)") }
        }
        // Don't leave half a message behind.
        AXEngine.selectAll()
        AXEngine.press(0x33)
        return false
    }

    /// Accessibility press first (exact, works even if covered); real mouse click if that had no effect.
    private func pressOrClick(_ el: UIElementInfo, app: NSRunningApplication, before: Int) async {
        buddy.setLabel(el.label)
        await withCheckedContinuation { continuation in
            buddy.fly(to: el.center, duration: 0.18) { continuation.resume() }
        }
        if AXEngine.axPress(el.element) {
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(80))
                if AXEngine.fingerprint(of: app) != before { return }
            }
        }
        AXEngine.click(at: el.center)
    }

    /// Finds the element a plan step describes: e<N> or an exact/near label match in code (instant),
    /// otherwise Jev picks among what's on screen.
    private func ground(_ target: String, in elements: [UIElementInfo], typing: Bool) async -> (Int, String)? {
        let pool = elements.enumerated().filter { !typing || Self.isTextInput($0.element) }
        guard !pool.isEmpty else { return nil }

        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces) }
        let wanted = norm(target)
        // Before a replan, GPT may reference current ids directly. Labels are preferred since ids shift.
        if let exact = pool.filter({ norm($0.element.label) == wanted }).first { return (exact.offset, "matched") }
        let prefixed = pool.filter { norm($0.element.label).hasPrefix(wanted) && !wanted.isEmpty }
        if prefixed.count == 1 { return (prefixed[0].offset, "matched") }

        var criteria: [String: Any] = ["none": "None of these is the element described"]
        for (i, el) in pool.prefix(240) { criteria["e\(i)"] = "\(el.role.dropFirst(2)): \(el.label)" }
        let started = Date()
        guard let answer = try? await Jev.ask(
            state: ["described": target],
            questions: ["pick": Jev.choice("Which on-screen element is the one `described` (same thing, even if the wording differs a little)?", criteria)]
        )["pick"], let key = answer.choice, key != "none", answer.topProbability >= 0.7,
              let i = Int(key.dropFirst()), i < elements.count else { return nil }
        return (i, "Jev \(Int(Date().timeIntervalSince(started) * 1000)) ms, p \(String(format: "%.2f", answer.topProbability))")
    }

    static func fieldCheck(text: String, task: String, field: UIElementInfo, elements: [UIElementInfo]) async throws -> Double {
        let answers = try await Jev.ask(
            state: ["request": task, "textAboutToBeTyped": text,
                    "field": "\(field.role.dropFirst(2)): \(field.label)",
                    "screen": elements.map { "\($0.role.dropFirst(2)): \($0.label)" }],
            questions: ["ok": Jev.noul(
                "The text `textAboutToBeTyped` is about to be typed into the text box `field`. First find which conversation, document or page is currently open in `screen` (e.g. \"Messages in chat with X\", a heading, or a window title). Is that the place `request` is aimed at, and does this text belong in `field`?",
                yes: "Right place and right box for this text", no: "A different conversation/page is open, or this box is wrong")])
        return answers["ok"]?.noul ?? 0
    }

    private func actLoop(task: String, app startApp: NSRunningApplication, route: Task<URL?, Never>? = nil) async -> LoopOutcome {
        var app = startApp
        let spans = Self.textSpans(of: task)
        let appName = app.localizedName?.replacingOccurrences(of: "\u{200E}", with: "") ?? "?"
        var history: [String] = []
        var lastAction: Action?
        var misses = 0
        var writer: Task<String?, Never>?
        await bringToFront(app)

        for step in 1...16 {
            guard isRunning else { return .stuck("Stopped") }
            let elements = AXEngine.elements(of: app, limit: 150)
            let focus = AXEngine.focusSummary(of: app)
            buddy.setLabel("looking… (\(step))")

            // Just typed a message (not a search): send it, no model call needed.
            if case .type(let i, _) = lastAction, i < elements.count || true,
               !Self.isSearch(history.last ?? ""), lastAction != .enter {
                let before = AXEngine.fingerprint(of: app)
                append(.info, "press Return (send)")
                history.append("pressed Return")
                lastAction = .enter
                AXEngine.pressReturn()
                for _ in 0..<16 {
                    try? await Task.sleep(for: .milliseconds(60))
                    if AXEngine.fingerprint(of: app) != before { return .done }
                }
                return .stuck("Pressed Return but nothing changed")
            }

            let d: Decision
            do {
                d = try await Self.decideNext(task: task, app: app, elements: elements, focus: focus,
                                              spans: spans, history: history)
            } catch {
                return .stuck(error.localizedDescription)
            }
            // First step: if the routing check says another app, switch and look again there.
            if step == 1, let route, let url = await route.value, let next = await launch(url) {
                app = next
                targetApp = next
                continue
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier { await bringToFront(app) }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                if echo { print("   frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") target=\(app.bundleIdentifier ?? "-")") }
                return .stuck("You switched apps, so I stopped before acting in the wrong place")
            }
            if !history.isEmpty, d.done >= 0.8 { return .done }

            // Jev's pick, if it's confident and not a repeat.
            var action: Action?
            // Text has to be composed: Claude writes just the text (started early, in parallel); Jev still navigates.
            if d.needsWriting >= 0.5, Planner.isAvailable {
                if writer == nil {
                    writer = Task { try? await Planner.writeText(for: task) }
                }
                if d.destOpen >= 0.5, !history.contains(where: { $0.hasPrefix("typed") }) {
                    buddy.setLabel("writing…")
                    guard let text = await writer?.value else { return .stuck("Couldn't write the text") }
                    if let field = try? await Self.chooseField(text: text, task: task, elements: elements), field.ok >= 0.5 {
                        action = .type(field.index, text)
                    }
                }
            }
            // Destination already open and there's text to type: go straight to typing (field is checked).
            else if d.destOpen >= 0.5, let si = d.typeSpan, d.typeProbability >= 0.5,
               !history.contains(where: { $0.hasPrefix("typed \"\(spans[si])\"") }),
               let field = try? await Self.chooseField(text: spans[si], task: task, elements: elements), field.ok >= 0.6 {
                action = .type(field.index, spans[si])
            }
            let source = "Jev \(d.ms) ms, p \(String(format: "%.2f", d.probability))"
            let isBrowser = Self.browserIDs.contains(app.bundleIdentifier ?? "")
            if isBrowser {
                if history.isEmpty, let url = await Self.webShortcut(task: task, spans: spans) {
                    append(.info, "open \(url.absoluteString.prefix(80))  (Jev)")
                    await Self.openInBrowser(url, app: app)
                    return .done
                }
                return .handoff(history)
            }
            if action == nil, d.key != "none", d.probability >= 0.6, d.done < 0.5 {
                if d.key.hasPrefix("click_"), let i = Int(d.key.dropFirst(6)), i < elements.count { action = .click(i) }
                else if d.key.hasPrefix("type_"), d.needsWriting < 0.5, let i = Int(d.key.dropFirst(5)), i < spans.count {
                    if let field = try? await Self.chooseField(text: spans[i], task: task, elements: elements),
                       field.ok >= 0.6 {
                        action = .type(field.index, spans[i])
                    }
                }
                else if d.key == "enter" { action = .enter }
                else if Self.keyActions[d.key] != nil { action = .key(d.key) }
                else if d.key == "scroll_down" { action = .scroll(-8) }
                else if d.key == "scroll_up" { action = .scroll(8) }
            }
            if action == lastAction { action = nil }

            // Jev isn't sure (or the task needs written text): hand over to the planner.
            if action == nil { return .handoff(history) }
            guard let action else { return .stuck("No action chosen") }
            let typedLast = lastAction.map { if case .type = $0 { return true } else { return false } } ?? false
            lastAction = action

            let before = AXEngine.fingerprint(of: app)
            switch action {
            case .click(let i):
                let el = elements[i]
                append(.info, "click \"\(el.label.prefix(50))\"  (\(source))")
                history.append("clicked \(el.role.dropFirst(2)) \"\(el.label.prefix(60))\"")
                await pressOrClick(el, app: app, before: before)

            case .type(let i, let text):
                let field = elements[i]
                append(.info, "type \"\(text.prefix(60))\" into \(field.label.prefix(30))  (\(source))")
                history.append("typed \"\(text.prefix(80))\" into \(field.role.dropFirst(2)) \"\(field.label.prefix(50))\"")
                await click(field)
                try? await Task.sleep(for: .milliseconds(120))
                buddy.setLabel("typing…")
                if !(await enterVerified(text, app: app)) {
                    return .stuck("The text didn't go into the box completely, so I didn't send anything")
                }

            case .key(let id):
                let (desc, code, flags) = Self.keyActions[id]!
                let name = desc.components(separatedBy: " to ").first ?? id
                append(.info, "\(name)  (\(source))")
                history.append(name)
                AXEngine.press(code, flags: flags)

            case .scroll(let amount):
                append(.info, "scroll \(amount < 0 ? "down" : "up")  (\(source))")
                history.append("scrolled \(amount < 0 ? "down" : "up")")
                AXEngine.scroll(amount, in: app)

            case .openURL(let url):
                append(.info, "open \(url.absoluteString.prefix(70))  (\(source))")
                history.append("opened \(url.absoluteString)")
                if let appURL = app.bundleURL {
                    _ = try? await NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                                           configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(url)
                }
                try? await Task.sleep(for: .milliseconds(600))

            case .enter:
                append(.info, "press Return  (\(source))")
                history.append("pressed Return in \(focus.focused.prefix(60))")
                AXEngine.pressReturn()
            }

            // Wait for the screen to react. A miss is noted so the next decision can adapt; two misses stop.
            var changed = false
            for _ in 0..<16 {
                try? await Task.sleep(for: .milliseconds(60))
                if AXEngine.fingerprint(of: app) != before { changed = true; break }
            }
            // Typing then sending is the end of a message task; skip a whole extra round of checks.
            var isSend = false
            if case .enter = action { isSend = true }
            if case .click(let i) = action, elements[i].label.lowercased().hasPrefix("send") { isSend = true }
            if changed, typedLast, isSend { return .done }
            if !changed {
                misses += 1
                if misses >= 2 { return .stuck("Two actions had no visible effect, so I stopped instead of guessing") }
                history[history.count - 1] += " (no visible change)"
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return .stuck("Stopped after 16 actions")
    }

    private static func screenState(task: String, app: NSRunningApplication, elements: [UIElementInfo],
                                    focus: (window: String, focused: String), history: [String]) -> [String: Any] {
        [
            "request": task,
            "app": app.localizedName?.replacingOccurrences(of: "\u{200E}", with: "") ?? "?",
            "window": focus.window,
            "focusedElement": focus.focused,
            "actionsSoFar": history.isEmpty ? ["(none yet)"] : history,
            "screen": elements.map { "\($0.role.dropFirst(2)): \($0.label)" },
        ]
    }

    /// One Jev call: the next action plus "done?" and "missing?" checks, all answered in parallel.
    static func decideNext(task: String, app: NSRunningApplication, elements: [UIElementInfo],
                           focus: (window: String, focused: String), spans: [String],
                           history: [String]) async throws -> Decision {
        let started = Date()
        var criteria: [String: Any] = [:]
        for (i, el) in elements.enumerated() {
            criteria["click_\(i)"] = "Click the \(el.role.dropFirst(2)) \"\(el.label)\""
        }
        for (i, span) in spans.enumerated() {
            criteria["type_\(i)"] = "Type the text \"\(span)\" into the right text box (the box is chosen afterwards)"
        }
        criteria["enter"] = "Press Return to submit or send what's in the focused field"
        for (id, entry) in keyActions { criteria[id] = entry.0 }
        criteria["scroll_down"] = "Scroll down to reveal more content that isn't visible yet"
        criteria["scroll_up"] = "Scroll up to reveal earlier content"
        // Explicit escape hatch: without it Jev still picks some element when the right one is absent.
        criteria["none"] = "None of these actions makes progress; the needed control isn't on screen"

        let instructions: [String: Any] = [
            "question": "What is the single next UI action that makes progress on `request`, given `actionsSoFar` and `screen`?",
            "rules": [
                "Go step by step: open the right place first (click the matching chat, contact, tab or result; use search only if it isn't visible), then click into the input, then type, then submit.",
                "Type a message only when the correct conversation or destination is open, as shown in `screen` (e.g. 'Messages in chat with X').",
                "Type only the exact text that belongs in that field: a search term into search, just the message body into the message box.",
                "Don't repeat an action from `actionsSoFar` that already worked.",
                "Prefer clicking a visible control; use keyboard shortcuts or scrolling only when that's the clearer way.",
            ],
        ]
        // Speculative fan-out: a navigation-only version of the same choice, used when the
        // destination isn't open yet, so nothing can be typed into the wrong conversation.
        var navCriteria: [String: Any] = [:]
        for (i, el) in elements.enumerated() where !Self.isTextInput(el) || Self.isSearch(el.label + el.role) {
            navCriteria["click_\(i)"] = criteria["click_\(i)"]
        }
        if elements.contains(where: { Self.isTextInput($0) && Self.isSearch($0.label) }) || Self.isSearch(focus.focused) {
            for (i, span) in spans.enumerated() {
                navCriteria["type_\(i)"] = "Type the search term \"\(span)\" into the search box"
            }
            navCriteria["enter"] = criteria["enter"]
        }
        var destCriteria: [String: Any] = [:]
        for (i, el) in elements.enumerated() where !Self.isTextInput(el) {
            destCriteria["click_\(i)"] = "\(el.role.dropFirst(2)): \(el.label)"
        }
        destCriteria["none"] = "The destination isn't visible in this list"
        for id in ["key_cmd_f", "key_cmd_n", "key_cmd_l", "key_esc", "scroll_down", "scroll_up"] { navCriteria[id] = criteria[id] }
        navCriteria["none"] = criteria["none"]
        let navInstructions: [String: Any] = [
            "question": "The place `request` is aimed at isn't open yet. Which single action best navigates toward it (e.g. click the matching chat, contact, tab, or search for it)?",
            "rules": ["Prefer clicking the destination directly if it's visible in `screen`; otherwise use search."],
        ]

        var spanCriteria: [String: Any] = ["nothing": "No text needs to be typed for this request"]
        for (i, span) in spans.enumerated() { spanCriteria["s\(i)"] = "\"\(span)\"" }
        let answers = try await Jev.ask(
            state: screenState(task: task, app: app, elements: elements, focus: focus, history: history),
            questions: [
                "next": Jev.choice(instructions, criteria),
                "destItem": Jev.choice(
                    "Which visible item IS the destination `request` names (the chat, contact, file, tab or page it is aimed at, even if spelled a little differently)? Not a search box or a header.",
                    destCriteria),
                "destOpen": Jev.noul(
                    "First find which conversation, document or page is currently open in `screen` (look for things like \"Messages in chat with X\", a heading, or a window title). Is that currently open place the same one `request` is aimed at? If `request` names no specific place, answer yes.",
                    yes: "The place currently open is the one the request is aimed at", no: "A different place is open"),
                "needsWriting": Jev.noul(
                    "Does `request` ask for new text to be written or composed (e.g. 'write something nice', 'reply with a joke', 'tell them I'm running late' in my own words), rather than giving the exact words to type?",
                    yes: "Text has to be composed", no: "The exact words are given, or no text is needed"),
                "typeText": Jev.choice(
                    "If `request` involves typing text (a message, a search term, a name), which exact text from `request` is the text to type? Choose nothing if no typing is needed.",
                    spanCriteria),
            ].merging(history.isEmpty ? [:] : [
                "done": Jev.noul("Judging by `screen` and `actionsSoFar`, has every part of `request` already been carried out?",
                                 yes: "Everything asked has been done", no: "Something asked is still not done"),
            ]) { a, _ in a })
        let useNav = (answers["destOpen"]?.noul ?? 1) < 0.5
        // When navigating, a clearly visible destination beats any other route (like search).
        if useNav, let dest = answers["destItem"], let key = dest.choice, key != "none", dest.topProbability >= 0.5,
           !history.contains(where: { $0.hasPrefix("clicked") && $0.contains(criteria[key] as? String ?? "\u{0}") }) {
            return Decision(key: key, probability: dest.topProbability,
                            done: answers["done"]?.noul ?? 0, absent: answers["absent"]?.noul ?? 0,
                            ms: Int(Date().timeIntervalSince(started) * 1000))
        }
        _ = navCriteria; _ = navInstructions
        guard let next = answers["next"], let key = next.choice else { throw Jev.JevError.badResponse }
        var decision = Decision(key: key, probability: next.topProbability,
                                done: answers["done"]?.noul ?? 0, absent: answers["absent"]?.noul ?? 0,
                                ms: Int(Date().timeIntervalSince(started) * 1000))
        decision.destOpen = answers["destOpen"]?.noul ?? 0
        decision.needsWriting = answers["needsWriting"]?.noul ?? 0
        if let t = answers["typeText"], let k = t.choice, k != "nothing", let i = Int(k.dropFirst()), i < spans.count {
            decision.typeSpan = i
            decision.typeProbability = t.topProbability
        }
        return decision
    }

    static func isTextInput(_ el: UIElementInfo) -> Bool {
        ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(el.role)
    }

    static func isSearch(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("search") || lower.contains("find")
    }

    /// Checks every visible text box in parallel: "is this the right place to type `text` right now?"
    /// Returns the best box and its probability, or nil if there are no text boxes.
    static func chooseField(text: String, task: String, elements: [UIElementInfo]) async throws -> (index: Int, ok: Double)? {
        let inputs = elements.enumerated().filter { isTextInput($0.element) }.prefix(8)
        guard !inputs.isEmpty else { return nil }
        var questions: [String: Any] = [:]
        for (i, el) in inputs {
            questions["f\(i)"] = Jev.noul(
                "The text `textAboutToBeTyped` is about to be typed into the text box \"\(el.role.dropFirst(2)): \(el.label)\". First find which conversation, document or page is currently open in `screen` (e.g. \"Messages in chat with X\", a heading, or a window title). Is that the place `request` is aimed at, and does this text belong in that box?",
                yes: "Right place and right box for this text", no: "A different conversation/page is open, or this box is wrong")
        }
        let answers = try await Jev.ask(
            state: [
                "request": task,
                "textAboutToBeTyped": text,
                "screen": elements.map { "\($0.role.dropFirst(2)): \($0.label)" },
            ],
            questions: questions)
        return inputs.map { (index: $0.offset, ok: answers["f\($0.offset)"]?.noul ?? 0) }.max { $0.ok < $1.ok }
    }

    /// Candidate strings to type: every contiguous run of words in the request (Jev selects, it doesn't generate).
    static func textSpans(of request: String) -> [String] {
        var spans: [String] = []
        // Quoted text is almost always what should be typed.
        if let quoted = request.range(of: #""([^"]+)""#, options: .regularExpression) {
            spans.append(String(request[quoted]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        let words = request.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”,")) }
        guard !words.isEmpty else { return spans }
        for length in 1...min(words.count, 14) {
            for start in 0...(words.count - length) {
                let span = words[start..<start + length].joined(separator: " ")
                if !spans.contains(span) { spans.append(span) }
                if spans.count >= 90 { return spans }
            }
        }
        return spans
    }

    private func click(_ element: UIElementInfo) async {
        buddy.setLabel(element.label)
        await withCheckedContinuation { continuation in
            buddy.fly(to: element.center) { continuation.resume() }
        }
        AXEngine.click(at: element.center)
    }

    // MARK: - Slow path: Antigravity agent

    private func runAgent(_ request: String) {
        append(.info, "Handing off to agy…")
        buddy.setWorking(true)
        buddy.setLabel("working…")
        let appName = targetApp?.localizedName ?? "unknown"
        let prompt = """
        You are CursorBoy, an assistant running in the background on the user's Mac. \
        Complete the task fully and autonomously; don't ask follow-up questions. \
        You can control the Mac with shell commands, `open`, and `osascript` (AppleScript / System Events). \
        The user was in the app "\(appName)" when they asked. Finish with a one-or-two-sentence summary.

        Task: \(request)
        """

        var agentLineIndex: Int?
        agy.run(prompt: prompt) { [weak self] event in
            guard let self else { return }
            switch event {
            case .tool(let detail):
                agentLineIndex = nil
                self.append(.tool, detail)
                self.buddy.setLabel(String(detail.prefix(30)))
            case .text(let delta):
                if let index = agentLineIndex, index < self.log.count {
                    self.log[index].text += delta
                } else {
                    let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    self.append(.agent, delta)
                    agentLineIndex = self.log.count - 1
                }
            case .finished(let success, let response):
                if agentLineIndex == nil, !response.isEmpty { self.append(.agent, response) }
                self.append(success ? .done : .error, success ? "Done" : "Agent reported a failure")
                self.finish()
            case .failed(let message):
                self.append(.error, message)
                self.finish()
            }
        }
    }

    private func finish() {
        isRunning = false
        buddy.setWorking(false)
        buddy.setLabel(nil)
    }

    /// Test mode: mirror the log to stdout with timestamps relative to the request.
    var echo = false
    private var requestStart = Date()

    private func append(_ kind: LogLine.Kind, _ text: String) {
        if echo { print(String(format: "[%6.2fs] ", Date().timeIntervalSince(requestStart)) + "\(kind): \(text)") }
        log.append(LogLine(kind: kind, text: text))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
}

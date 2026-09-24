import AppKit

/// Runs a request as a conversation with one Claude session: observe the screen → Claude picks actions →
/// the buddy carries them out the way a person would (travel, point, click, type) → report → repeat.
@MainActor
final class Agent: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, acting, waiting, done, failed }

    /// Something CursorBoy needs from the user before it can go on (details, a choice, a confirmation).
    struct Question: Equatable {
        let text: String
        let options: [String]
        let sensitive: Bool
    }

    struct Step: Identifiable {
        enum State { case running, ok, failed, info }
        let id = UUID()
        var text: String
        var state: State
    }

    @Published var phase: Phase = .idle
    @Published var narration = ""
    @Published var steps: [Step] = []
    @Published var input = ""
    @Published var answer = ""
    /// Set while the run is paused waiting for the user's answer.
    @Published var question: Question?
    private var answerWaiter: CheckedContinuation<String?, Never>?
    /// Answers the user marked private; masked in the log.
    private var secrets: [String] = []
    var onQuestion: () -> Void = {}
    /// Output worth looking at (options, plans, prices, summaries), shown in its own card.
    @Published var result: ResultCard?
    var onResult: () -> Void = {}
    /// An earlier run the next request builds on ("Continue" in History).
    @Published var continuation: History.Entry?
    private var request = ""
    private var runResult: ResultCard?
    var onAnswered: () -> Void = {}

    /// The app the user was looking at when they summoned CursorBoy.
    var targetApp: NSRunningApplication?
    /// Text the user had selected when they summoned CursorBoy; sent along with the request.
    @Published var selectedText: String?
    var onStart: () -> Void = {}
    var onFinish: (_ answer: String, _ ok: Bool) -> Void = { _, _ in }
    /// Test mode: mirror progress to stdout with timings.
    var echo = false

    private let buddy: Buddy
    private let hand: Hand
    private var task: Task<Void, Never>?
    private var session: ClaudeSession?
    private var started = Date()
    /// Whether this task already opened a browser tab (so later website visits reuse it).
    private var openedTab = false
    /// The browser tab this task opened (the only tab it may navigate in place).
    private var ownedTab: Int?
    /// The user already said yes to a confirmation in this run.
    private var userConfirmed = false

    static func isNewTabPage(_ url: String) -> Bool {
        url.isEmpty || url.hasPrefix("chrome://newtab") || url.hasPrefix("arc://newtab") || url == "about:blank"
            || url.hasPrefix("chrome://new-tab-page") || url.hasPrefix("edge://newtab") || url.hasPrefix("brave://newtab")
    }

    var isRunning: Bool { phase == .thinking || phase == .acting || phase == .waiting }

    /// Pauses for the user's answer to `text` (nil = no answer / cancelled).
    private func askUser(_ text: String, options: [String] = [], sensitive: Bool = false) async -> String? {
        let previous = phase
        phase = .waiting
        buddy.bubble("need your input", for: 4)
        question = Question(text: text, options: options, sensitive: sensitive)
        onQuestion()
        let reply = await withCheckedContinuation { answerWaiter = $0 }
        if !Task.isCancelled { phase = previous == .waiting ? .acting : previous }
        return reply
    }

    /// Consequential clicks (pay, book, send, delete…) the request didn't clearly ask for need the user's OK.
    private func confirmRisky(_ label: String) async -> Bool {
        guard !userConfirmed, let what = Safety.needsConfirmation(label: label, request: request) else { return true }
        let reply = await askUser("About to click “\(what)”. Go ahead?", options: ["Yes, go ahead", "No"])
        let yes = reply.map(Safety.isYes) ?? false
        if yes { userConfirmed = true }
        return yes
    }

    /// The user's reply to the current question (nil = they declined / cancelled).
    func answer(_ text: String?) {
        guard let waiter = answerWaiter else { return }
        answerWaiter = nil
        lastProgress = Date()   // time spent answering isn't "stuck"
        question = nil
        input = ""
        onAnswered()
        waiter.resume(returning: text?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    init(buddy: Buddy) {
        self.buddy = buddy
        hand = Hand(buddy: buddy)
    }

    func submit(_ raw: String) {
        let request = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isRunning else { return }
        started = Date()
        steps = []
        answer = ""
        input = ""
        narration = ""
        openedTab = false
        ownedTab = nil
        userConfirmed = false
        secrets = []
        self.request = request
        runResult = nil
        phase = .thinking
        buddy.clearMark()
        onStart()
        startWatchdog()
        Self.writeLog("=== \(request)\(selectedText.map { " [selection: \($0.count) chars]" } ?? "")")
        task = Task {
            await run(request)
            selectedText = nil
            continuation = nil
        }
    }

    func cancel() {
        answer(nil)
        task?.cancel()
        session?.close()
        if isRunning { finish(ok: false, "Stopped") }
    }

    // MARK: - Loop

    private func run(_ request: String) async {
        guard AXEngine.isTrusted else {
            return finish(ok: false, "Turn on Accessibility for CursorBoy in System Settings → Privacy & Security.")
        }
        buddy.mood = .thinking

        // Don't start clicking around during a call or meeting unless the user says so.
        if Safety.micInUse {
            let reply = await askUser("You seem to be on a call (the mic is in use). Should I go ahead and use the screen?",
                                      options: ["Go ahead", "Not now"])
            guard let reply, reply.lowercased().hasPrefix("go") || Safety.isYes(reply) else {
                return finish(ok: false, "Okay, I'll wait until you're off the call")
            }
            phase = .thinking
        }

        let session: ClaudeSession
        do { session = try Brain.session() } catch { return finish(ok: false, error.localizedDescription) }
        self.session = session
        defer { session.close() }

        var app = targetApp ?? NSWorkspace.shared.frontmostApplication
        var message = intro(request)
        var wantsLook = false
        var failures = 0
        var lastSignature = ""
        var repeats = 0
        var lastScreen = ""

        for turn in 0..<30 {
            guard !Task.isCancelled else { return }
            let obs = await Observation.capture(app)
            if let page = obs.page {
                let fields = page.elements.filter(\.editable).map { "w\($0.index) \($0.extra)" }.joined(separator: " | ")
                log("  page: \(page.title.prefix(50)) · \(page.elements.count) elements\(fields.isEmpty ? "" : " · fields: \(fields.prefix(300))")")
            }
            if obs.elements.count < 6 || failures >= 2 { wantsLook = true }
            var image: String?
            if wantsLook, let shotApp = obs.app { image = await Screenshot.annotated(app: shotApp, elements: obs.elements) }
            wantsLook = false
            // An unchanged screen is one line, not the whole list again (less to read, faster replies).
            let screen = obs.text == lastScreen && image == nil ? "Screen: unchanged since your last look." : obs.text
            lastScreen = obs.text
            let turnText = message + "\n\n" + screen + (image != nil ? "\n(Screenshot attached: red boxes are tagged with the same e<N> ids.)" : "")

            phase = .thinking
            buddy.mood = .thinking
            let t0 = Date()
            let reply: String
            do { reply = try await session.send(turnText, image: image) } catch {
                if Task.isCancelled { return }
                return finish(ok: false, error.localizedDescription)
            }
            if Task.isCancelled { return }
            log("turn \(turn) · \(Int(Date().timeIntervalSince(t0) * 1000)) ms · \(reply.prefix(300))")

            guard let json = Brain.json(from: reply) else {
                message = "Your last reply wasn't a JSON object. Reply with JSON only."
                continue
            }
            let say = (json["say"] as? String) ?? ""
            let actions = (json["actions"] as? [[String: Any]]) ?? []
            let isDone = json["done"] as? Bool == true
            if !say.isEmpty, !isDone { narration = say }

            let signature = actions.map { "\($0)" }.joined()
            repeats = signature == lastSignature ? repeats + 1 : 0
            lastSignature = signature
            if repeats >= 2 { return finish(ok: false, "I kept trying the same thing, so I stopped") }

            if !actions.isEmpty {
                phase = .acting
                buddy.mood = .acting
            }
            var results: [String] = []
            var context = ActionContext(app: obs.app, elements: obs.elements, fingerprint: obs.fingerprint,
                                        page: obs.page, webArea: obs.webArea)
            for (i, action) in actions.enumerated() {
                guard !Task.isCancelled else { return }
                let result = await perform(action, context: &context)
                if case .look = result.effect { wantsLook = true }
                results.append("\(i + 1). \(result.summary)")
                if !result.ok { failures += 1; break }
                failures = 0
            }
            app = context.app
            // A final reply may carry last actions; finish once they ran (unless one failed).
            if isDone, failures == 0 {
                finish(ok: true, say.isEmpty ? "Done" : say)
                await learn(from: session)
                return
            }
            if actions.isEmpty { results.append("(no actions taken)") }
            message = "Results:\n" + results.joined(separator: "\n")
        }
        finish(ok: false, "That took too many steps, so I stopped")
    }

    /// After a task, keep anything lasting it revealed about the user (people, preferences, usual apps and
    /// places), so next time is faster. Runs in the background once the user already has their answer.
    private func learn(from session: ClaudeSession) async {
        guard !Task.isCancelled else { return }
        let known = Memory.facts
        let prompt = """
        The task is finished. List lasting facts about the user that this task revealed and that would help future \
        tasks: people and where to reach them (which app/chat), preferences (seats, airlines, food, tone), usual apps, \
        home/work city, frequent places, accounts or usernames. Not passwords, card numbers, OTPs, one-off details, \
        or facts about the screen. Skip anything already known:
        \(known.isEmpty ? "(nothing yet)" : known.map { "- \($0)" }.joined(separator: "\n"))
        Reply with JSON only: {"facts":["short fact", ...]} — an empty list if nothing new.
        """
        guard let reply = try? await session.send(prompt), let json = Brain.json(from: reply),
              let facts = json["facts"] as? [String] else { return }
        let lower = Set(known.map { $0.lowercased() })
        for fact in facts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        where !fact.isEmpty && fact.count < 200 && !lower.contains(fact.lowercased()) {
            Memory.add(fact)
            log("🧠 remembered: \(fact)")
        }
    }

    private func intro(_ request: String) -> String {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.cleanName)
        let date = Date().formatted(date: .complete, time: .shortened)
        var text = """
        Request: \(request)
        User: \(NSFullUserName()) · \(date)
        Running apps: \(running.joined(separator: ", "))
        Default browser: \(Launcher.defaultBrowserName ?? "unknown")
        """
        if let selected = selectedText, !selected.isEmpty {
            text += "\nSelected text (the user highlighted this before asking; \"this\", \"it\", \"that\" usually mean it):\n\"\"\"\n\(selected.prefix(4000))\n\"\"\""
        }
        if let earlier = continuation {
            text += """

            This continues an earlier task (\(earlier.date.formatted(date: .abbreviated, time: .shortened))):
            Earlier request: \(earlier.request)
            What happened: \(earlier.steps.suffix(12).joined(separator: "; "))
            Earlier result: \(earlier.answer)\(earlier.result.map { "\nEarlier output: \($0.plain.prefix(1500))" } ?? "")
            """
        }
        let skills = Skills.shared.promptText
        if !skills.isEmpty {
            text += "\nSkills the user taught you (follow the matching one's steps when a request fits; ask for any missing parameters):\n" + skills
        }
        let facts = Memory.facts
        if !facts.isEmpty { text += "\nThings you remember about the user:\n" + facts.map { "- \($0)" }.joined(separator: "\n") }
        return text
    }

    // MARK: - Actions

    struct ActionContext {
        var app: NSRunningApplication?
        var elements: [UIElementInfo]
        var fingerprint: Int
        /// The live web page (via the browser extension) and where its viewport is on screen.
        var page: BrowserBridge.Page?
        var webArea: CGRect?
        /// Page fields typed into this turn (index → text), re-checked because browser autofill can change them later.
        var typedFields: [(Int, String)] = []
    }

    struct ActionResult {
        enum Effect { case none, look }
        let ok: Bool
        let summary: String
        var effect: Effect = .none
    }

    private func perform(_ action: [String: Any], context: inout ActionContext) async -> ActionResult {
        let kind = (action["do"] as? String ?? "").lowercased()
        switch kind {
        case "open_app":
            guard let name = action["name"] as? String else { return fail("open_app needs a name") }
            let line = begin("Open \(name)")
            guard let app = await hand.openApp(named: name) else { return end(line, fail("Couldn't find an app called \(name)")) }
            context.app = app
            await refresh(&context)
            return end(line, .init(ok: true, summary: "\(app.cleanName ?? name) is now frontmost"))

        case "open_url":
            guard let raw = action["url"] as? String,
                  let url = URL(string: raw.contains("://") ? raw : "https://\(raw)") else { return fail("bad url") }
            let line = begin("Go to \(url.host ?? raw)")
            // Already there: nothing to open.
            if let page = context.page, let host = url.host?.replacingOccurrences(of: "www.", with: ""),
               page.url.contains(host), url.path.count <= 1 || page.url.contains(url.path) {
                return end(line, .init(ok: true, summary: "already on \(page.url)"))
            }
            // Never take over one of the user's tabs: reuse only a tab this task opened itself, or an empty
            // new-tab page; anything else gets a fresh tab.
            let bridge = BrowserBridge.shared
            let before = context.app.map(Launcher.isBrowser) == true ? await bridge.activeTab() : nil
            let emptyTab = before.map { Self.isNewTabPage($0.url) } ?? false
            // Each site gets its own tab ("open github and wikipedia" = two tabs); staying on the same site in our
            // own tab (youtube.com → a YouTube search) reuses it.
            let host = { (u: String) in (URL(string: u)?.host ?? "").replacingOccurrences(of: "www.", with: "") }
            let sameSite = before.map { host($0.url) == host(url.absoluteString) && !host($0.url).isEmpty } ?? false
            let reuse = before != nil && (emptyTab || (before?.id == ownedTab && sameSite))
            let browser = await hand.openURL(url, current: context.app, newTab: !reuse)
            openedTab = true
            if let before, let after = await bridge.activeTab() {
                log("    tab: \(reuse ? "reused" : "new") · before #\(before.id) \(before.url.prefix(50)) · now #\(after.id)")
                if !reuse, after.id == before.id, !Self.isNewTabPage(before.url) {
                    log("    tab: the user's tab was changed — restoring it and opening a separate tab")
                    // The new tab didn't happen and the user's page was changed: put it back, open ours separately.
                    await bridge.tabCommand("goBack", on: after, ["tabId": after.id])
                    ownedTab = (await bridge.tabCommand("newTab", on: after, ["url": url.absoluteString]))?["id"] as? Int
                    try? await Task.sleep(for: .milliseconds(1200))
                } else {
                    ownedTab = after.id
                }
            }
            context.app = browser ?? NSWorkspace.shared.frontmostApplication
            await refresh(&context)
            // With the extension we can check the page really opened; if the typed address went astray, go directly.
            if let page = context.page, let host = url.host?.replacingOccurrences(of: "www.", with: ""),
               !page.url.contains(host), let tab = await BrowserBridge.shared.activeTab() {
                // Only ever redirect our own tab; otherwise open the page in a new one.
                if tab.id == ownedTab {
                    await BrowserBridge.shared.tabCommand("navigate", on: tab, ["url": url.absoluteString])
                } else {
                    ownedTab = (await BrowserBridge.shared.tabCommand("newTab", on: tab, ["url": url.absoluteString]))?["id"] as? Int
                }
                try? await Task.sleep(for: .milliseconds(1200))
                await refresh(&context)
            }
            return end(line, .init(ok: true, summary: "opened \(url.absoluteString) in \(context.app?.cleanName ?? "the browser")"))

        case "click" where Self.isWebRef(action["id"]):
            guard let (el, rect) = webTarget(action["id"], context) else { return fail("page element \(action["id"] ?? "?") not found; look again") }
            let line = begin("Click \(el.text.prefix(32))")
            guard await confirmRisky(el.text) else { return end(line, fail("the user said not to click \(el.text.prefix(40).debugDescription); stop and tell them where things stand")) }
            if let app = context.app { await Launcher.bringToFront(app) }
            // A real mouse click, like a person: many sites (Google Forms, React apps) ignore script clicks.
            // If nothing changed and it wasn't covered, fall back to clicking through the page.
            let page = context.page!
            let state = { (try? await BrowserBridge.shared.perform("state", on: page, ["index": el.index]))?["sig"] as? String }
            let before = await state()
            await hand.click(at: CGPoint(x: rect.midX, y: rect.midY))
            var after = await state()
            for _ in 0..<3 where before != nil && before == after {
                try? await Task.sleep(for: .milliseconds(120))
                after = await state()
            }
            if before != nil, before == after {
                do { _ = try await BrowserBridge.shared.perform("click", on: page, ["index": el.index]) }
                catch { return end(line, fail(error.localizedDescription)) }
                try? await Task.sleep(for: .milliseconds(250))
            }
            buddy.clearHighlight()
            return end(line, .init(ok: true, summary: "clicked \(el.role) \(el.text.prefix(60).debugDescription) on the page"))

        case "type" where Self.isWebRef(action["id"]):
            guard let text = action["text"] as? String else { return fail("type needs text") }
            guard let (el, rect) = webTarget(action["id"], context), let page = context.page, let app = context.app
            else { return fail("page element \(action["id"] ?? "?") not found; look again") }
            let line = begin("Type “\(text.prefix(40))”")
            await Launcher.bringToFront(app)
            await buddy.travel(to: CGPoint(x: rect.midX, y: rect.midY), framing: rect)
            buddy.click()
            if el.role == "select" {
                // Dropdown: choose the option directly (typing into a native select is unreliable).
                do {
                    let r = try await BrowserBridge.shared.perform("fill", on: page, ["index": el.index, "text": text])
                    // Confirm the page really holds the new choice before calling it done.
                    let now = (try? await BrowserBridge.shared.perform("value", on: page, ["index": el.index]))?["value"] as? String
                    log("    dropdown: fill → \(r["value"] ?? "nil") · now \(now ?? "nil")")
                    buddy.clearHighlight()
                    return end(line, .init(ok: true, summary: "chose \((r["value"] as? String ?? text).debugDescription) in the dropdown"))
                } catch { return end(line, fail(error.localizedDescription)) }
            }
            // Keep the browser's autocomplete list from opening over the field, then click into it for real
            // like a person (a real click also closes any popup still open from the previous field).
            _ = try? await BrowserBridge.shared.perform("prepare", on: page, ["index": el.index])
            await hand.click(at: CGPoint(x: rect.midX, y: rect.midY))
            try? await Task.sleep(for: .milliseconds(150))
            // It must be *this* field that has the caret (not just any text box, e.g. the previous one);
            // keys anywhere else would trigger page shortcuts or land in the wrong field.
            let isActive = { (try? await BrowserBridge.shared.perform("isActive", on: page, ["index": el.index]))?["active"] as? Bool == true }
            var ready = await isActive()
            if !ready {
                _ = try? await BrowserBridge.shared.perform("focus", on: page, ["index": el.index])
                try? await Task.sleep(for: .milliseconds(100))
                ready = await isActive()
            }
            if !ready {
                // Still no caret: set the text directly on the field.
                guard let r = try? await BrowserBridge.shared.perform("fill", on: page, ["index": el.index, "text": text]) else {
                    return end(line, fail("\(el.text.prefix(30)) isn't a text box"))
                }
                if action["submit"] as? Bool == true { hand.press("return"); try? await Task.sleep(for: .milliseconds(500)) }
                buddy.clearHighlight()
                return end(line, .init(ok: true, summary: "set \((r["value"] as? String ?? text).prefix(60).debugDescription) in \(el.role) \(el.text.prefix(40).debugDescription)\(action["submit"] as? Bool == true ? " and pressed Return" : "")"))
            }
            // Type it like a person; if the page didn't take the keys, set it the way frameworks notice.
            // Start from an empty field (it may hold autofill or old text); keystrokes then type the rest.
            if let old = (try? await BrowserBridge.shared.perform("value", on: page, ["index": el.index]))?["value"] as? String, !old.isEmpty {
                _ = try? await BrowserBridge.shared.perform("fill", on: page, ["index": el.index, "text": ""])
            }
            buddy.setTyping(true)
            AXEngine.targetPid = app.processIdentifier
            await hand.keystrokes(text)
            AXEngine.targetPid = nil
            buddy.setTyping(false)
            // Keys queue up in the browser; wait until the field shows them before moving on (or focus could
            // move to the next field while this one's last keys are still in flight).
            var value: String?
            for _ in 0..<12 {
                value = (try? await BrowserBridge.shared.perform("value", on: page, ["index": el.index]))?["value"] as? String
                if let v = value, AXEngine.similar(v, text) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let value, !AXEngine.similar(value, text) || value.count > text.count + 3 {
                _ = try? await BrowserBridge.shared.perform("fill", on: page, ["index": el.index, "text": text])
            }
            // Browser autofill can rewrite fields filled a moment ago (e.g. focusing a password box refills the
            // username): put back anything that changed.
            context.typedFields.removeAll { $0.0 == el.index }
            context.typedFields.append((el.index, text))
            for (index, expected) in context.typedFields where index != el.index {
                let now = (try? await BrowserBridge.shared.perform("value", on: page, ["index": index]))?["value"] as? String
                if let now, now.trimmingCharacters(in: .whitespaces) != expected {
                    _ = try? await BrowserBridge.shared.perform("fill", on: page, ["index": index, "text": expected])
                }
            }
            if action["submit"] as? Bool == true {
                try? await Task.sleep(for: .milliseconds(120))
                hand.press("return")
                try? await Task.sleep(for: .milliseconds(500))
            }
            buddy.clearHighlight()
            return end(line, .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into \(el.role) \(el.text.prefix(40).debugDescription)\(action["submit"] as? Bool == true ? " and pressed Return" : "")"))

        case "type" where action["id"] == nil && context.page != nil:
            guard let text = action["text"] as? String, let page = context.page, let app = context.app else { return fail("type needs text") }
            let line = begin("Type “\(text.prefix(40))”")
            await Launcher.bringToFront(app)
            let before = try? await BrowserBridge.shared.perform("activeValue", on: page)
            guard before?["editable"] as? Bool == true else {
                return end(line, fail("no text box on the page has focus; click one first (give its w-id)"))
            }
            if let existing = before?["value"] as? String, !existing.isEmpty {
                AXEngine.targetPid = app.processIdentifier
                AXEngine.selectAll()
                AXEngine.targetPid = nil
                try? await Task.sleep(for: .milliseconds(60))
            }
            buddy.setTyping(true)
            AXEngine.targetPid = app.processIdentifier
            await hand.keystrokes(text)
            AXEngine.targetPid = nil
            buddy.setTyping(false)
            if let value = (try? await BrowserBridge.shared.perform("activeValue", on: page))?["value"] as? String,
               !AXEngine.similar(value, text) || value.count > text.count + 3 {
                _ = try? await BrowserBridge.shared.perform("fillActive", on: page, ["text": text])
            }
            if action["submit"] as? Bool == true {
                try? await Task.sleep(for: .milliseconds(120))
                hand.press("return")
                try? await Task.sleep(for: .milliseconds(500))
            }
            buddy.clearHighlight()
            return end(line, .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into the focused field\(action["submit"] as? Bool == true ? " and pressed Return" : "")"))

        case "point" where Self.isWebRef(action["id"]), "mark" where Self.isWebRef(action["id"]):
            guard let (el, rect) = webTarget(action["id"], context) else { return fail("page element \(action["id"] ?? "?") not found; look again") }
            let line = begin("Show \(el.text.prefix(32))")
            await buddy.mark(rect, label: action["label"] as? String)
            hand.lingerBeforeHome = 3.5
            return end(line, .init(ok: true, summary: "marked it on screen with a circle and arrow"))

        case "scroll" where context.page != nil:
            let up = (action["dir"] as? String)?.lowercased() == "up"
            let line = begin("Scroll \(up ? "up" : "down")")
            if let web = context.webArea { await buddy.travel(to: CGPoint(x: web.midX, y: web.midY)) }
            _ = try? await BrowserBridge.shared.perform("scroll", on: context.page!, ["dy": up ? -600 : 600])
            try? await Task.sleep(for: .milliseconds(450))
            return end(line, .init(ok: true, summary: "scrolled \(up ? "up" : "down")"))

        case "read":
            // Best source first: the web page, the document file behind the window (PDF, Word…), a PDF open in
            // the browser, and finally recognising the text on screen (scans, images, anything else).
            let line = begin("Read")
            var text: String?
            var source = ""
            let short = { (t: String?) in (t?.count ?? 0) < 80 }
            if let page = context.page, !page.url.lowercased().hasSuffix(".pdf"), page.url.hasPrefix("http") || page.url.hasPrefix("file") {
                text = (try? await BrowserBridge.shared.perform("read", on: page))?["text"] as? String
                source = "the web page"
            }
            if short(text), let page = context.page, let url = URL(string: page.url),
               url.pathExtension.lowercased() == "pdf" || page.url.contains(".pdf") {
                text = await Reader.fileText(url)
                source = "the PDF \(url.lastPathComponent)"
            }
            if short(text), let app = context.app, let doc = await Reader.documentText(of: app) {
                text = doc.text
                source = "the document \(doc.name)"
            }
            if short(text), let app = context.app, let seen = await Reader.ocr(app) {
                text = seen
                source = "the screen (text recognition)"
            }
            guard let text, !text.isEmpty else { return end(line, fail("couldn't read any text here; try look")) }
            return end(line, .init(ok: true, summary: "text from \(source):\n\(text)"))

        case "type" where action["id"] == nil && context.page != nil:
            guard let text = action["text"] as? String, let page = context.page, let app = context.app else { return fail("type needs text") }
            let line = begin("Type “\(text.prefix(40))”")
            await Launcher.bringToFront(app)
            let before = try? await BrowserBridge.shared.perform("activeValue", on: page)
            guard before?["editable"] as? Bool == true else {
                return end(line, fail("no text box on the page has focus; click one first (give its w-id)"))
            }
            if let existing = before?["value"] as? String, !existing.isEmpty {
                AXEngine.targetPid = app.processIdentifier
                AXEngine.selectAll()
                AXEngine.targetPid = nil
                try? await Task.sleep(for: .milliseconds(60))
            }
            buddy.setTyping(true)
            AXEngine.targetPid = app.processIdentifier
            await hand.keystrokes(text)
            AXEngine.targetPid = nil
            buddy.setTyping(false)
            if let value = (try? await BrowserBridge.shared.perform("activeValue", on: page))?["value"] as? String,
               !AXEngine.similar(value, text) || value.count > text.count + 3 {
                _ = try? await BrowserBridge.shared.perform("fillActive", on: page, ["text": text])
            }
            if action["submit"] as? Bool == true {
                try? await Task.sleep(for: .milliseconds(120))
                hand.press("return")
                try? await Task.sleep(for: .milliseconds(500))
            }
            buddy.clearHighlight()
            return end(line, .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into the focused field\(action["submit"] as? Bool == true ? " and pressed Return" : "")"))

        case "point" where Self.isWebRef(action["id"]), "mark" where Self.isWebRef(action["id"]):
            guard let (el, rect) = webTarget(action["id"], context) else { return fail("page element \(action["id"] ?? "?") not found; look again") }
            let line = begin("Show \(el.text.prefix(32))")
            await buddy.mark(rect, label: action["label"] as? String)
            hand.lingerBeforeHome = 3.5
            return end(line, .init(ok: true, summary: "marked it on screen with a circle and arrow"))

        case "scroll" where context.page != nil:
            let up = (action["dir"] as? String)?.lowercased() == "up"
            let line = begin("Scroll \(up ? "up" : "down")")
            if let web = context.webArea { await buddy.travel(to: CGPoint(x: web.midX, y: web.midY)) }
            _ = try? await BrowserBridge.shared.perform("scroll", on: context.page!, ["dy": up ? -600 : 600])
            try? await Task.sleep(for: .milliseconds(450))
            return end(line, .init(ok: true, summary: "scrolled \(up ? "up" : "down")"))

        case "read":
            guard let page = context.page else { return fail("reading needs a web page with the CursorBoy extension") }
            let line = begin("Read the page")
            guard let r = try? await BrowserBridge.shared.perform("read", on: page) else { return end(line, fail("couldn't read the page")) }
            return end(line, .init(ok: true, summary: "page text:\n\(r["text"] as? String ?? "")"))

        case "click" where action["id"] == nil:
            // By position on the last screenshot, for things with no element (canvas, custom-drawn UI, text links).
            guard let x = (action["x"] as? NSNumber)?.doubleValue, let y = (action["y"] as? NSNumber)?.doubleValue,
                  let p = Screenshot.screenPoint(x: x, y: y) else { return fail("click needs an id, or x/y on the last screenshot") }
            let line = begin("Click")
            if let app = context.app { await Launcher.bringToFront(app) }
            await hand.click(at: p)
            try? await Task.sleep(for: .milliseconds(450))
            if let app = context.app { context.fingerprint = await AXEngine.fingerprintAsync(of: app) }
            return end(line, .init(ok: true, summary: "clicked at (\(Int(x)), \(Int(y))) on the screenshot"))

        case "click":
            guard let app = context.app else { return fail("no app") }
            guard let el = await resolve(action["id"], context: &context) else { return fail("element \(action["id"] ?? "?") isn't on screen anymore") }
            let line = begin("Click \(el.shortLabel)")
            guard await confirmRisky(el.label) else { return end(line, fail("the user said not to click \(el.label.prefix(40).debugDescription); stop and tell them where things stand")) }
            await Launcher.bringToFront(app)
            await hand.click(el, in: app, fingerprint: context.fingerprint)
            let didChange = await changed(app, from: context.fingerprint, ms: 600)
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            buddy.clearHighlight()
            return end(line, .init(ok: true, summary: "clicked \(el.describe)\(didChange ? "" : " (no visible change)")"))

        case "type":
            guard let app = context.app else { return fail("no app") }
            guard let text = action["text"] as? String else { return fail("type needs text") }
            let submit = action["submit"] as? Bool ?? false
            let line = begin("Type “\(text.prefix(40))”")
            await Launcher.bringToFront(app)
            var target = "the focused field"
            if action["id"] != nil {
                guard let el = await resolve(action["id"], context: &context) else { return end(line, fail("element \(action["id"] ?? "?") isn't on screen anymore")) }
                await hand.focus(el, in: app)
                target = el.describe
            }
            guard await hand.type(text, in: app) else {
                return end(line, fail("the text didn't land in \(target) (field shows \((AXEngine.focusedValue(of: app) ?? "nothing").prefix(60).debugDescription))"))
            }
            if submit {
                try? await Task.sleep(for: .milliseconds(120))
                hand.press("return")
                _ = await changed(app, from: context.fingerprint, ms: 500)
            }
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            buddy.clearHighlight()
            return end(line, .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into \(target)\(submit ? " and pressed Return" : "")"))

        case "key":
            guard let keys = action["keys"] as? String else { return fail("key needs keys") }
            let line = begin("Press \(keys)")
            if let app = context.app { await Launcher.bringToFront(app) }
            guard hand.press(keys) else { return end(line, fail("unknown key \(keys)")) }
            var didChange = false
            if let app = context.app {
                didChange = await changed(app, from: context.fingerprint, ms: 450)
                context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            }
            return end(line, .init(ok: true, summary: "pressed \(keys)\(didChange ? "" : " (no visible change)")"))

        case "scroll":
            guard let app = context.app else { return fail("no app") }
            let up = (action["dir"] as? String)?.lowercased() == "up"
            let line = begin("Scroll \(up ? "up" : "down")")
            await hand.scroll(up: up, in: app)
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            return end(line, .init(ok: true, summary: "scrolled \(up ? "up" : "down")"))

        case "applescript":
            guard let script = action["script"] as? String else { return fail("applescript needs script") }
            let line = begin("Run a script")
            let r = await Shell.run("/usr/bin/osascript", ["-e", script])
            return end(line, .init(ok: r.status == 0, summary: r.status == 0 ? "AppleScript ok\(r.output.isEmpty ? "" : ": \(r.output.prefix(1500))")" : "AppleScript failed: \(r.output.prefix(400))"))

        case "shell":
            guard let cmd = action["cmd"] as? String else { return fail("shell needs cmd") }
            let line = begin("Look something up")
            let r = await Shell.run("/bin/zsh", ["-lc", cmd])
            return end(line, .init(ok: r.status == 0, summary: "exit \(r.status)\(r.output.isEmpty ? "" : ": \(r.output.prefix(2000))")"))

        case "point", "mark":
            // Mark an element, or a spot on the last screenshot (for things without an element).
            var rect: CGRect?
            var name = "that"
            if action["id"] != nil {
                guard let el = await resolve(action["id"], context: &context) else { return fail("element \(action["id"] ?? "?") isn't on screen anymore") }
                rect = el.frame
                name = el.shortLabel
            } else if let x = (action["x"] as? NSNumber)?.doubleValue, let y = (action["y"] as? NSNumber)?.doubleValue,
                      let p = Screenshot.screenPoint(x: x, y: y) {
                let w = (action["w"] as? NSNumber)?.doubleValue ?? 36, h = (action["h"] as? NSNumber)?.doubleValue ?? 36
                let scale = (Screenshot.lastWindowFrame?.width ?? 1) / (Screenshot.lastImageSize?.width ?? 1)
                rect = CGRect(x: p.x - w * scale / 2, y: p.y - h * scale / 2, width: w * scale, height: h * scale)
            }
            guard let rect else { return fail("point needs an id, or x/y on the last screenshot") }
            let line = begin("Show \(name)")
            await buddy.mark(rect, label: action["label"] as? String)
            hand.lingerBeforeHome = 3.5
            return end(line, .init(ok: true, summary: "marked it on screen with a circle and arrow"))

        case "ask":
            guard let text = action["question"] as? String, !text.isEmpty else { return fail("ask needs a question") }
            let options = (action["options"] as? [String]) ?? []
            let sensitive = action["sensitive"] as? Bool ?? false
            let line = begin("Ask: \(text.prefix(60))")
            phase = .waiting
            buddy.mood = .idle
            buddy.bubble("need your input", for: 4)
            question = Question(text: text, options: options, sensitive: sensitive)
            onQuestion()
            let reply = await withCheckedContinuation { answerWaiter = $0 }
            guard let reply, !reply.isEmpty, !Task.isCancelled else {
                return end(line, fail("the user didn't answer; stop here and say what's still needed"))
            }
            if sensitive { secrets.append(reply) }
            if !options.isEmpty, Safety.isYes(reply) { userConfirmed = true }
            phase = .acting
            buddy.mood = .acting
            if let app = context.app { await Launcher.bringToFront(app) }
            return end(line, .init(ok: true, summary: "the user answered: \(reply)"))

        case "show":
            guard let card = ResultCard(action: action) else { return fail("show needs text or items") }
            steps.append(Step(text: "Showed: \(card.title)", state: .info))
            runResult = card
            result = card
            onResult()
            return .init(ok: true, summary: "shown to the user on screen")

        case "look":
            return .init(ok: true, summary: "screenshot attached next turn", effect: .look)

        case "wait":
            let ms = min(5000, (action["ms"] as? Int) ?? 600)
            try? await Task.sleep(for: .milliseconds(ms))
            if let app = context.app { context.fingerprint = await AXEngine.fingerprintAsync(of: app) }
            return .init(ok: true, summary: "waited \(ms) ms")

        case "remember":
            guard let fact = action["fact"] as? String else { return fail("remember needs fact") }
            Memory.add(fact)
            steps.append(Step(text: "Remembered: \(fact)", state: .info))
            return .init(ok: true, summary: "saved")

        default:
            return fail("unknown action \(kind.debugDescription)")
        }
    }

    static func isWebRef(_ ref: Any?) -> Bool { (ref as? String)?.lowercased().hasPrefix("w") == true }

    /// A page element by its w-id, with its rect on screen.
    private func webTarget(_ ref: Any?, _ context: ActionContext) -> (BrowserBridge.PageElement, CGRect)? {
        guard let page = context.page, let web = context.webArea, let ref = ref as? String,
              let n = Int(ref.dropFirst()), let el = page.elements.first(where: { $0.index == n }) else { return nil }
        let sx = web.width / page.viewport.width, sy = web.height / page.viewport.height
        let rect = CGRect(x: web.minX + el.rect.minX * sx, y: web.minY + el.rect.minY * sy,
                          width: el.rect.width * sx, height: el.rect.height * sy)
        return (el, rect.intersection(web).isNull ? rect : rect.intersection(web))
    }

    private func refresh(_ context: inout ActionContext) async {
        guard let app = context.app else { return }
        let scan = await AXEngine.scan(app)
        context.elements = scan.elements
        context.fingerprint = scan.fingerprint
        // Keep the web page current too, so page actions in the same turn see what's actually there.
        if Launcher.isBrowser(app), BrowserBridge.shared.isConnected, let page = await BrowserBridge.shared.snapshot() {
            context.page = page
            context.webArea = await Task.detached { AXEngine.webAreaFrame(of: app) }.value ?? page.estimatedArea
        } else {
            context.page = nil
        }
    }

    /// Looks an element up by id; if the screen changed since it was listed, finds the same role+label again.
    private func resolve(_ ref: Any?, context: inout ActionContext) async -> UIElementInfo? {
        guard let app = context.app, let ref = ref as? String,
              let n = Int(ref.trimmingCharacters(in: CharacterSet(charactersIn: "eE"))), n < context.elements.count else { return nil }
        let wanted = context.elements[n]
        if await AXEngine.fingerprintAsync(of: app) == context.fingerprint { return wanted }
        // The screen moved on. The same element is usually still alive (maybe shifted); else find its twin.
        if let frame = AXEngine.liveFrame(of: wanted.element), frame.width > 2, frame.height > 2 {
            return UIElementInfo(id: wanted.id, role: wanted.role, label: wanted.label, frame: frame, element: wanted.element)
        }
        await refresh(&context)
        let near = { (e: UIElementInfo) in hypot(e.frame.midX - wanted.frame.midX, e.frame.midY - wanted.frame.midY) }
        return context.elements.first { $0.role == wanted.role && $0.label == wanted.label }
            ?? context.elements.first { $0.label == wanted.label }
            ?? context.elements.filter { $0.role == wanted.role && near($0) < 40 }.min { near($0) < near($1) }
    }

    private func changed(_ app: NSRunningApplication, from fingerprint: Int, ms: Int) async -> Bool {
        for _ in 0..<max(1, ms / 60) {
            try? await Task.sleep(for: .milliseconds(60))
            if await AXEngine.fingerprintAsync(of: app) != fingerprint { return true }
        }
        return false
    }

    // MARK: - Progress

    private func fail(_ why: String) -> ActionResult { .init(ok: false, summary: "FAILED: \(why)") }

    private func begin(_ text: String) -> Int {
        var text = text
        for secret in secrets where secret.count >= 3 { text = text.replacingOccurrences(of: secret, with: "••••") }
        steps.append(Step(text: text, state: .running))
        narration = text
        log("  → \(text)")
        return steps.count - 1
    }

    private func end(_ index: Int, _ result: ActionResult) -> ActionResult {
        if index < steps.count { steps[index].state = result.ok ? .ok : .failed }
        if !result.ok { log("    ✗ \(result.summary)") }
        return result
    }

    private func finish(ok: Bool, _ text: String) {
        guard isRunning else { return }
        phase = ok ? .done : .failed
        narration = text
        answer = text
        buddy.mood = ok ? .success : .failure
        let linger = hand.lingerBeforeHome
        hand.lingerBeforeHome = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + linger + 0.35) { [buddy] in
            buddy.goHome()
            buddy.mood = .idle
        }
        log(ok ? "✓ \(text)" : "✗ \(text)")
        // Long answers are easier to read in the result card than in the status bar.
        if ok, runResult == nil, text.count > 140 {
            runResult = ResultCard(title: String(request.prefix(60)), text: text, items: [])
            result = runResult
            onResult()
        }
        History.shared.add(.init(date: started, request: request, answer: text, ok: ok,
                                 steps: steps.map(\.text), app: targetApp?.cleanName, result: runResult))
        session = nil
        onFinish(text, ok)
    }

    /// Last time the run made progress; a watchdog stops runs stuck on one step.
    private var lastProgress = Date()
    private var watchdog: Timer?

    private func startWatchdog() {
        lastProgress = Date()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { timer.invalidate(); return }
                guard self.phase != .waiting, Date().timeIntervalSince(self.lastProgress) > 30 else { return }
                let step = self.steps.last?.text ?? "a step"
                self.log("watchdog: no progress for 30 s on \(step)")
                self.task?.cancel()
                self.session?.close()
                self.finish(ok: false, "I got stuck on “\(step)” and stopped")
            }
        }
    }

    private func log(_ text: String) {
        lastProgress = Date()
        var text = text
        for secret in secrets where secret.count >= 3 { text = text.replacingOccurrences(of: secret, with: "••••") }
        let line = String(format: "[%6.2fs] ", Date().timeIntervalSince(started)) + text
        if echo { print(line); fflush(stdout) }
        Self.writeLog(line)
    }

    /// Every run is also written to ~/Library/Logs/CursorBoy/agent.log (for debugging and tests).
    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CursorBoy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent.log")
    }()

    static func writeLog(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - Observation

struct Observation {
    let app: NSRunningApplication?
    let elements: [UIElementInfo]
    let fingerprint: Int
    let text: String
    var page: BrowserBridge.Page? = nil
    var webArea: CGRect? = nil

    /// Reads the frontmost app's UI off the main thread, so the buddy never stutters while we look.
    @MainActor
    static func capture(_ preferred: NSRunningApplication?) async -> Observation {
        let front = NSWorkspace.shared.frontmostApplication
        let app = (front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front) ?? preferred
        guard let app else { return Observation(app: nil, elements: [], fingerprint: 0, text: "No app is frontmost.") }
        let scan = await AXEngine.scan(app)

        // In a browser with the extension: the real page, element by element.
        var page: BrowserBridge.Page?
        var webArea: CGRect?
        if Launcher.isBrowser(app), BrowserBridge.shared.isConnected {
            page = await BrowserBridge.shared.snapshot()
            if page != nil { webArea = await Task.detached { AXEngine.webAreaFrame(of: app) }.value ?? page?.estimatedArea }
            if webArea == nil { page = nil }
        }
        // With the page covered by the extension, list only the browser's own controls from Accessibility.
        let list = scan.elements.enumerated()
            .filter { item in
                guard let web = webArea else { return true }
                return !web.contains(CGPoint(x: item.element.frame.midX, y: item.element.frame.midY))
            }
            .map { "e\($0.offset) \($0.element.role.dropFirst(2)): \($0.element.label)" }
            .joined(separator: "\n")
        var text = """
        Frontmost app: \(app.cleanName ?? "?")\(Launcher.isBrowser(app) ? " (browser)" : "")
        Window: \(scan.window.isEmpty ? "(none)" : scan.window)
        Focused: \(scan.focused)
        \(page != nil ? "Browser controls" : "Elements"):
        \(list.isEmpty ? "(none readable — ask to look)" : list)
        """
        if let page {
            let items = page.elements.map { "w\($0.index) \($0.role): \($0.text)\($0.extra.isEmpty ? "" : " [\($0.extra)]")" }
            text += """

            Web page (via extension; use w-ids for anything on the page): \(page.title)
            URL: \(page.url)
            Scroll: \(Int(page.scrollY)) of \(Int(page.scrollMax))\(page.headings.isEmpty ? "" : "\nHeadings: " + page.headings.joined(separator: " | "))
            Page elements (visible part):
            \(items.isEmpty ? "(none)" : items.joined(separator: "\n"))
            """
        } else if Launcher.isBrowser(app) {
            text += "\n(Browser extension not connected: page content comes from Accessibility only.)"
        }
        return Observation(app: app, elements: scan.elements, fingerprint: scan.fingerprint, text: text,
                           page: page, webArea: webArea)
    }
}

extension AXEngine {
    struct Scan: @unchecked Sendable {
        let elements: [UIElementInfo]
        let fingerprint: Int
        let window: String
        let focused: String
    }

    static func scan(_ app: NSRunningApplication) async -> Scan {
        await Task.detached(priority: .userInitiated) {
            enableManualAccessibility(app)
            let focus = focusSummary(of: app)
            return Scan(elements: elements(of: app, limit: 150), fingerprint: fingerprint(of: app),
                        window: focus.window, focused: focus.focused)
        }.value
    }

    static func fingerprintAsync(of app: NSRunningApplication) async -> Int {
        await Task.detached(priority: .userInitiated) { fingerprint(of: app) }.value
    }
}

extension UIElementInfo {
    var shortLabel: String { String(label.prefix(32)) }
    var describe: String { "\(role.dropFirst(2)) \(label.prefix(60).debugDescription)" }
}

extension NSRunningApplication {
    var cleanName: String? { localizedName?.replacingOccurrences(of: "\u{200E}", with: "") }
}

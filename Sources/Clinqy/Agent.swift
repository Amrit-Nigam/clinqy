import AppKit
import UniformTypeIdentifiers

/// Runs a request as a conversation with one Claude session: observe the screen → Claude picks actions →
/// the buddy carries them out the way a person would (travel, point, click, type) → report → repeat.
@MainActor
final class Agent: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, acting, waiting, done, failed }

    /// Something Clinqy needs from the user before it can go on (details, a choice, a confirmation).
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

    /// The app the user was looking at when they summoned Clinqy.
    var targetApp: NSRunningApplication?
    /// Text the user had selected when they summoned Clinqy; sent along with the request.
    @Published var selectedText: String?
    /// An area the user circled on screen before asking; sent as a marked screenshot on the first turn.
    @Published var annotation: Annotation?
    /// Files the user had selected in Finder when they summoned Clinqy ("compress this", "merge these").
    @Published var selectedFiles: [URL] = []
    var onStart: () -> Void = {}
    var onFinish: (_ answer: String, _ ok: Bool) -> Void = { _, _ in }
    /// Test mode: mirror progress to stdout with timings.
    var echo = false
    /// Test runs aren't saved to History and teach memory nothing.
    var isTest = false

    private let buddy: Buddy
    private let hand: Hand
    fileprivate var task: Task<Void, Never>?
    private var session: ClaudeSession?
    fileprivate var started = Date()
    /// Whether this task already opened a browser tab (so later website visits reuse it).
    private var openedTab = false
    /// Step screenshots taken this run with snap, for paste_snaps.
    private var snaps: [(caption: String, png: Data)] = []
    /// The browser tab this task opened (the only tab it may navigate in place).
    private var ownedTab: Int?
    /// The user already said yes to a confirmation in this run.
    private var userConfirmed = false

    static func isNewTabPage(_ url: String) -> Bool {
        url.isEmpty || url.hasPrefix("chrome://newtab") || url.hasPrefix("arc://newtab") || url == "about:blank"
            || url.hasPrefix("chrome://new-tab-page") || url.hasPrefix("edge://newtab") || url.hasPrefix("brave://newtab")
    }

    var isRunning: Bool { phase == .thinking || phase == .acting || phase == .waiting }

    /// What this run actually did, step by step, in a replayable form (saved as a workflow / QA script).
    var trace: [WorkflowStep] = []
    /// How the last resolved element can be found again (set whenever an action resolves its target).
    var lastTarget: WorkflowStep.Target?
    /// QA mode: the run is a UI test; checks are collected instead of asking the user anything.
    var qa: QAContext?
    /// Use a different Claude model for this run (e.g. from `clinqy qa --model`).
    var modelOverride: String?

    /// Things the user added while the task was running; folded into the next step.
    private var addedNotes: [String] = []

    /// Steer a running task: more context or a change of plan, picked up at the next step.
    func addContext(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isRunning else { return }
        if question != nil { return answer(text) }   // waiting on a question: this is the answer
        addedNotes.append(text)
        steps.append(Step(text: "You: \(text)", state: .info))
        input = ""
        lastProgress = Date()
        log("  + user added: \(text)")
    }

    /// Pauses for the user's answer to `text` (nil = no answer / cancelled).
    private func askUser(_ text: String, options: [String] = [], sensitive: Bool = false) async -> String? {
        if qa != nil { return options.first }   // tests run unattended: take the first (go-ahead) option
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
        if let text, !text.isEmpty { userAnswers.append(text) }
        waiter.resume(returning: text?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    init(buddy: Buddy) {
        self.buddy = buddy
        hand = Hand(buddy: buddy)
    }

    func submit(_ raw: String, test: Bool = false) {
        let request = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isRunning else { return }
        prepare(request, test: test)
        task = Task {
            await run(request)
            selectedText = nil
            annotation = nil
            selectedFiles = []
            continuation = nil
        }
    }

    /// Resets per-run state; shared by requests, workflow replays and QA runs.
    fileprivate func prepare(_ request: String, test: Bool) {
        isTest = test || echo
        started = Date()
        trace = []
        lastTarget = nil
        steps = []
        answer = ""
        input = ""
        narration = ""
        openedTab = false
        checkedMemoryForAsk = false
        turnCount = 0; fastTurnCount = 0; lookCount = 0
        reviewedForm = false
        userAnswers = []
        snaps = []
        addedNotes = []
        ownedTab = nil
        userConfirmed = false
        secrets = []
        self.request = request
        runResult = nil
        phase = .thinking
        buddy.clearMark()
        onStart()
        startWatchdog()
        Self.writeLog("=== \(request)\(selectedText.map { " [selection: \($0.count) chars]" } ?? "")\(selectedFiles.isEmpty ? "" : " [files: \(selectedFiles.map(\.lastPathComponent).joined(separator: ", "))]")\(annotation.map { " [circled: \(Int($0.rect.width))×\(Int($0.rect.height)) at \(Int($0.rect.minX)),\(Int($0.rect.minY))]" } ?? "")")
    }

    func cancel() {
        answer(nil)
        task?.cancel()
        session?.close()
        if isRunning { finish(ok: false, "Stopped") }
    }

    // MARK: - Loop

    fileprivate func run(_ request: String) async {
        guard AXEngine.isTrusted else {
            return finish(ok: false, "Turn on Accessibility for Clinqy in System Settings → Privacy & Security.")
        }
        buddy.mood = .thinking

        // Don't start clicking around during a call or meeting unless the user says so (or told Clinqy it's fine,
        // e.g. the remembered fact "OK to work during calls and screen sharing").
        let callsOK = Memory.facts.contains { fact in
            let f = fact.lowercased()
            return f.contains("ok to work") && (f.contains("call") || f.contains("screen shar"))
        }
        if Safety.micInUse, qa == nil, !callsOK {
            let reply = await askUser("You seem to be on a call (the mic is in use). Should I go ahead and use the screen?",
                                      options: ["Go ahead", "Not now"])
            guard let reply, reply.lowercased().hasPrefix("go") || Safety.isYes(reply) else {
                return finish(ok: false, "Okay, I'll wait until you're off the call")
            }
            phase = .thinking
        }

        let session: ClaudeSession
        do { session = try Brain.session(model: modelOverride) } catch { return finish(ok: false, error.localizedDescription) }
        self.session = session
        defer { session.close() }

        var app = targetApp ?? NSWorkspace.shared.frontmostApplication
        var message = intro(request)
        let fast = FastLane(intro: message, leadModel: modelOverride ?? Brain.model)
        defer { fast.close() }
        message += fast.leadNote
        var wantsLook = false
        var failures = 0
        var lastSignature = ""
        var repeats = 0
        var askedForAnswer = false
        var lastScreen = ""

        for turn in 0..<50 {   // long forms take 30+ turns
            guard !Task.isCancelled else { return }
            let obs = await Observation.capture(app)
            if let page = obs.page {
                let fields = page.elements.filter(\.editable).map { "w\($0.index) \($0.extra)" }.joined(separator: " | ")
                log("  page: \(page.title.prefix(50)) · \(page.elements.count) elements\(fields.isEmpty ? "" : " · fields: \(fields.prefix(300))")")
            }
            // Auto-screenshot when there's little to go on. With the extension, the page's own list counts
            // (the browser's toolbar controls alone say nothing about the page).
            let known = obs.page.map { $0.elements.count } ?? obs.elements.count
            if known < 6 || failures >= 2 { wantsLook = true }
            // The first look shows what the user circled; after that it's just in the request text.
            let circled = turn == 0 ? annotation : nil
            if let circled {
                wantsLook = true
                let inside = obs.elements.enumerated().filter { circled.rect.intersects($0.element.frame) }.map { "e\($0.offset)" }
                message += "\nInside the circled area: " + (inside.isEmpty ? "no listed elements (use the screenshot)." : inside.prefix(30).joined(separator: ", "))
            }
            var image: String?
            if wantsLook, let shotApp = obs.app {
                image = await Screenshot.annotated(app: shotApp, elements: obs.elements, circled: circled)
            }
            wantsLook = false
            // An unchanged screen is one line, not the whole list again (less to read, faster replies).
            let screen = obs.text == lastScreen && image == nil ? "Screen: unchanged since your last look." : obs.text
            lastScreen = obs.text
            // Anything the user added mid-task comes first: it can change the plan.
            if !addedNotes.isEmpty {
                message = "The user added while you were working (take it into account; it may change the plan):\n"
                    + addedNotes.map { "- \($0)" }.joined(separator: "\n") + "\n\n" + message
                addedNotes = []
            }
            let turnText = message + "\n\n" + screen + (image != nil ? "\n(Screenshot attached: red boxes are tagged with the same e<N> ids.\(circled != nil ? " The yellow loop is what the user circled." : ""))" : "")

            phase = .thinking
            buddy.mood = .thinking
            let t0 = Date()
            let reply: String
            do { reply = try await fast.reply(to: turnText, message: message, image: image, failures: failures, lead: session) } catch {
                if Task.isCancelled { return }
                return finish(ok: false, error.localizedDescription)
            }
            if Task.isCancelled { return }
            log("turn \(turn) · \(Int(Date().timeIntervalSince(t0) * 1000)) ms · \(fast.tag)\(reply.prefix(300))")
            turnCount += 1
            if fast.tag.hasPrefix("fast") { fastTurnCount += 1 }
            if image != nil { lookCount += 1 }

            guard let json = Brain.json(from: reply) else {
                message = "Your last reply wasn't a JSON object. Reply with JSON only."
                continue
            }
            let say = (json["say"] as? String) ?? ""
            let actions = (json["actions"] as? [[String: Any]]) ?? []
            let isDone = json["done"] as? Bool == true
            if !say.isEmpty, !isDone { narration = say }

            // Only the same actions three times in a row is a loop; turns with no actions (thinking, finishing) aren't.
            let signature = actions.map { "\($0)" }.joined()
            repeats = !actions.isEmpty && signature == lastSignature ? repeats + 1 : 0
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
                // The user added something mid-batch: the rest of this plan may be outdated, re-plan first.
                if !addedNotes.isEmpty {
                    results.append("(stopped before step \(i + 1): the user added something — see above)")
                    break
                }
                lastTarget = nil
                var action = action
                // click/type/open_* already wait for the screen to settle; a wait stacked on top is mostly dead time.
                if (action["do"] as? String) == "wait", i > 0,
                   ["click", "type", "open_url", "open_app", "key"].contains(actions[i - 1]["do"] as? String ?? ""),
                   (action["ms"] as? Int ?? 600) > 1000 {
                    action["ms"] = 1000
                }
                let result = await perform(action, context: &context)
                if result.ok { record(action) }
                if case .look = result.effect { wantsLook = true }
                results.append("\(i + 1). \(result.summary)")
                if !result.ok { failures += 1; break }
                failures = 0
            }
            app = context.app
            // A final reply may carry last actions; finish once they ran (unless one failed).
            if isDone, failures == 0, !addedNotes.isEmpty {
                message = "Results:\n" + results.joined(separator: "\n") + "\n(You were about to finish, but the user added something.)"
                continue
            }
            // A question answered with a status label ("Your roll number") instead of the answer: ask once for the answer.
            if isDone, failures == 0, !askedForAnswer, Self.isQuestion(request), Self.looksLikeLabel(say) {
                askedForAnswer = true
                message = (results.isEmpty ? "" : "Results:\n" + results.joined(separator: "\n") + "\n")
                    + "Your final say (\"\(say)\") is a label, not the answer. The user asked a question: finish again with done:true "
                    + "and a say that contains the answer itself, as a full sentence (e.g. \"Your roll number is 1601…\")."
                continue
            }
            if isDone, failures == 0 {
                finish(ok: true, say.isEmpty ? "Done" : say)
                await learn(from: session)
                return
            }
            if actions.isEmpty { results.append("(no actions taken)") }
            message = "Results:\n" + results.joined(separator: "\n")
        }
        finish(ok: false, "Ran out of steps, so I stopped. Last done: \(steps.last?.text ?? "nothing"). Check the screen before retrying.")
    }

    private var checkedMemoryForAsk = false
    /// This run's numbers for runs.jsonl: model turns, turns the fast helper took, screenshots sent.
    private var turnCount = 0, fastTurnCount = 0, lookCount = 0

    /// One JSON line per run in ~/Library/Logs/Clinqy/runs.jsonl (`clinqy stats` sums them up).
    private func recordStats(ok: Bool, answer: String) {
        let row: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: started), "request": String(request.prefix(160)), "ok": ok,
            "stopped": !ok && answer == "Stopped", "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
            "turns": turnCount, "fast_turns": fastTurnCount, "screenshots": lookCount,
            "steps": steps.count, "failed_steps": steps.filter { $0.state == .failed }.count, "app": targetApp?.cleanName ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = Self.logURL.deletingLastPathComponent().appendingPathComponent("runs.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
    /// What the user typed in answer to questions this run (their own words, unlike anything read on screen).
    private var userAnswers: [String] = []

    /// The application tracker in the result card (menu: Applications…).
    func showApplications() {
        let card = Applications.card
        result = card
        onResult()
    }
    private var reviewedForm = false

    /// Reads every answer on the page's form and shows it as a card: question → answer, empty required ones flagged.
    private func reviewForm(_ page: BrowserBridge.Page) async -> ActionResult {
        let line = begin("Review the form")
        guard let r = try? await BrowserBridge.shared.perform("review", on: page, timeout: 8),
              let items = r["items"] as? [[String: Any]], !items.isEmpty else { return end(line, fail("no form fields found on this page")) }
        reviewedForm = true
        let missing = r["missing"] as? [String] ?? []
        let cards = items.map { i -> ResultCard.Item in
            let q = i["q"] as? String ?? "?", a = i["answer"] as? String ?? ""
            let flag = a.isEmpty ? (i["required"] as? Bool == true ? "⚠️ required — empty" : "(empty)") : nil
            return ResultCard.Item(title: q, subtitle: a.isEmpty ? nil : a, detail: flag, link: nil)
        }
        let messages = r["messages"] as? [String] ?? []
        let note = (missing.isEmpty ? "All required questions are answered." : "⚠️ \(missing.count) required unanswered: " + missing.joined(separator: "; "))
            + (messages.isEmpty ? "" : "\nPage says: " + messages.joined(separator: " · "))
        let card = ResultCard(title: "Check before submitting: \(String((r["title"] as? String ?? "form").prefix(50)))", text: note, items: cards)
        runResult = card
        result = card
        onResult()
        let summary = items.map { "- \($0["q"] as? String ?? "?"): \(($0["answer"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(empty)")" }.joined(separator: "\n")
        return end(line, .init(ok: true, summary: "review shown to the user. \(note)\n\(summary)"))
    }

    /// A question for the user's own details (name, email, phone, college…), which memory may already hold.
    static func asksForPersonalDetails(_ question: String) -> Bool {
        // Confirmations ("Submit with your resume attached?") aren't requests for details.
        if question.range(of: #"(?i)\b(submit|send it|should i|shall i|go ahead|ready to|confirm|okay to|ok to)\b"#, options: .regularExpression) != nil { return false }
        return question.range(of: #"(?i)\b(your|you)\b.*\b(name|e-?mail|phone|mobile|number|college|university|cgpa|gpa|degree|graduat|linkedin|github|portfolio|address|city|gender|birth|dob|age|skills?|stack|experience|resume|cv)\b"#,
                       options: .regularExpression) != nil
    }

    /// "What is…?", "tell me…", "who/where/when/which/how…" — requests that want information back.
    static func isQuestion(_ request: String) -> Bool {
        let r = request.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if r.hasSuffix("?") { return true }
        return r.range(of: #"^(so |and |ok |okay )?(what|what's|whats|who|who's|where|when|which|how|tell me|do you know|remind me)\b"#,
                       options: .regularExpression) != nil
    }

    /// A short title with nothing in it ("Your roll number", "Found it"): no digits, no verb like "is", few words.
    static func looksLikeLabel(_ say: String) -> Bool {
        let words = say.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= 5, !say.contains(where: \.isNumber), !say.contains("@") else { return words.isEmpty }
        let verbs: Set<String> = ["is", "are", "was", "were", "it's", "isn't", "can't", "don't", "no", "not", "yes", "has", "have"]
        return !words.contains { verbs.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
    }

    /// After a task, keep anything lasting it revealed about the user (people, preferences, usual apps and
    /// places), so next time is faster. Runs in the background once the user already has their answer.
    private func learn(from session: ClaudeSession) async {
        guard !Task.isCancelled, !isTest else { return }
        let known = Memory.facts
        let prompt = """
        The task is finished. List lasting facts about the user that this task revealed and that would help future \
        tasks: people and where to reach them (which app/chat), preferences (seats, airlines, food, tone), usual apps, \
        home/work city, frequent places, accounts or usernames. Not passwords, card numbers, OTPs, one-off details, \
        not job applications (the application tracker holds those), \
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
        await MemoryTidy.runIfDue()
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
        if !selectedFiles.isEmpty {
            text += "\nFiles selected in Finder (\"this\", \"these\", \"it\" usually mean them):\n" + selectedFiles.map { "- \($0.path)" }.joined(separator: "\n")
        } else if let app = targetApp, let doc = AXEngine.documentURL(of: app), doc.isFileURL {
            text += "\nFile open in \(app.cleanName ?? "the front app"): \(doc.path)"
        }
        if let circled = annotation {
            let r = circled.rect
            text += "\nThe user circled an area on screen before asking (\"this\", \"here\", \"that\" usually mean it): "
                + "x \(Int(r.minX))–\(Int(r.maxX)), y \(Int(r.minY))–\(Int(r.maxY)) in screen points. It's the yellow loop on the first screenshot."
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
        // Only the memory that matters for this request (plus core facts); the rest is one recall away.
        let context = [request, targetApp?.cleanName ?? "", selectedText ?? "", continuation?.request ?? ""].joined(separator: " ")
        let (facts, omitted) = Memory.relevant(to: context)
        let profile = facts.filter(Memory.isProfile), other = facts.filter { !Memory.isProfile($0) }
        text += "\nThe user's profile (their own details: fill forms with these and never ask for them; the latest line wins if two disagree):\n"
            + "- Full name: \(NSFullUserName())\n" + profile.map { "- \($0)" }.joined(separator: "\n")
        if !other.isEmpty { text += "\nOther things you remember about the user:\n" + other.map { "- \($0)" }.joined(separator: "\n") }
        if omitted > 0 { text += "\n(\(omitted) more remembered facts not shown — use recall if you need something about the user that isn't here.)" }
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

    fileprivate func perform(_ action: [String: Any], context: inout ActionContext) async -> ActionResult {
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
            // Already there: nothing to open (in a QA test the page is always loaded fresh).
            if qa != nil, let page = context.page, page.url.hasPrefix(url.absoluteString) || url.absoluteString.hasPrefix(page.url),
               let tab = await BrowserBridge.shared.activeTab(in: context.app) {
                await BrowserBridge.shared.tabCommand("navigate", on: tab, ["url": url.absoluteString])
                try? await Task.sleep(for: .milliseconds(1200))
                await refresh(&context)
                return end(line, .init(ok: true, summary: "reloaded \(url.absoluteString)"))
            }
            if qa == nil, let page = context.page, let host = url.host?.replacingOccurrences(of: "www.", with: ""),
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
               !page.url.contains(host), let tab = await BrowserBridge.shared.activeTab(in: context.app) {
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

        case "application":
            // The application tracker: find before applying, record after filling/sending.
            let op = (action["op"] as? String ?? "find").lowercased()
            let company = (action["company"] as? String) ?? "", role = (action["role"] as? String) ?? ""
            let link = action["url"] as? String
            if op == "find" || op == "check" {
                let query = (action["query"] as? String) ?? [company, role, link ?? ""].joined(separator: " ")
                let hits = Applications.find(query)
                return .init(ok: true, summary: hits.isEmpty ? "no earlier application matches \(query.debugDescription)"
                             : "already in the tracker:\n" + hits.map { "- " + Applications.describe($0) }.joined(separator: "\n"))
            }
            if op == "list" || op == "show" {
                let card = Applications.card
                runResult = card
                result = card
                onResult()
                steps.append(Step(text: "Showed \(card.title)", state: .info))
                return .init(ok: true, summary: "tracker shown to the user:\n" + card.plain.prefix(3000))
            }
            guard !company.isEmpty else { return fail("application record needs company (and role)") }
            let summary = Applications.record(company: company, role: role, url: link, status: (action["status"] as? String) ?? "",
                                              resume: action["resume"] as? String, notes: action["notes"] as? String)
            steps.append(Step(text: "Tracked: \(company) — \(role)", state: .info))
            return .init(ok: true, summary: summary)

        case "upload" where context.page != nil:
            // Straight into the page's upload field (no Mac file picker): the extension builds the file from its bytes.
            guard let path = (action["file"] ?? action["path"]) as? String else { return fail("upload needs file") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url) else { return fail("can't read \(url.path)") }
            guard data.count < 15_000_000 else { return fail("\(url.lastPathComponent) is too big to upload this way (\(data.count / 1_000_000) MB)") }
            let page = context.page!
            var index = -1
            if Self.isWebRef(action["id"]) {
                guard let (el, _) = webTarget(action["id"], context) else { return fail("page element \(action["id"] ?? "?") not found; look again") }
                index = el.index
            }
            let line = begin("Upload \(url.lastPathComponent)")
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            do {
                let r = try await BrowserBridge.shared.perform("upload", on: page, ["index": index, "name": url.lastPathComponent, "type": type,
                                                                                    "data": data.base64EncodedString()], timeout: 20)
                guard r["ok"] as? Bool == true else { return end(line, fail("the page didn't take the file")) }
                try? await Task.sleep(for: .milliseconds(800))   // sites upload/parse it (Greenhouse fills fields from a resume)
                return end(line, .init(ok: true, summary: "attached \(url.lastPathComponent) to the upload field (now holds: \((r["files"] as? [String] ?? []).joined(separator: ", ")))"))
            } catch {
                return end(line, fail("\(error.localizedDescription) — if the site uses its own picker (Google Forms uses Google Drive), click its upload button instead"))
            }

        case "review" where context.page != nil:
            return await reviewForm(context.page!)

        case "choose" where Self.isWebRef(action["id"]):
            // A dropdown in one step: open it with a real click (type to filter if it's a search box), find the
            // option by its text, click it, then check the field shows it. Works for native selects, Google Forms
            // listboxes and React-style comboboxes (Greenhouse, Lever…).
            guard let want = (action["option"] ?? action["text"]) as? String, !want.isEmpty else { return fail("choose needs option") }
            guard let (el, rect) = webTarget(action["id"], context), let page = context.page, let app = context.app,
                  let web = context.webArea else { return fail("page element \(action["id"] ?? "?") not found; look again") }
            let line = begin("Choose “\(want.prefix(40))”")
            await Launcher.bringToFront(app)
            await buddy.travel(to: CGPoint(x: rect.midX, y: rect.midY), framing: rect)
            let current = { (try? await BrowserBridge.shared.perform("chosen", on: page, ["index": el.index]))?["value"] as? String ?? "" }
            if el.role == "select" {
                do {
                    let r = try await BrowserBridge.shared.perform("fill", on: page, ["index": el.index, "text": want])
                    buddy.clearHighlight()
                    return end(line, .init(ok: true, summary: "chose \((r["value"] as? String ?? want).debugDescription) in the dropdown"))
                } catch { return end(line, fail(error.localizedDescription)) }
            }
            if AXEngine.similar(await current(), want) {
                buddy.clearHighlight()
                return end(line, .init(ok: true, summary: "\(want.debugDescription) was already chosen"))
            }
            await hand.click(at: CGPoint(x: rect.midX, y: rect.midY))
            if el.editable {
                // A search-as-you-type box: typing narrows the list to the option.
                try? await Task.sleep(for: .milliseconds(150))
                AXEngine.targetPid = app.processIdentifier
                await hand.enterText(want, codeEditor: false)
                AXEngine.targetPid = nil
            }
            var option: [String: Any]?
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(200))
                option = try? await BrowserBridge.shared.perform("findOption", on: page, ["text": want])
                if option?["found"] as? Bool == true { break }
            }
            guard let option, option["found"] as? Bool == true,
                  let x = (option["x"] as? NSNumber)?.doubleValue, let y = (option["y"] as? NSNumber)?.doubleValue,
                  let w = (option["w"] as? NSNumber)?.doubleValue, let h = (option["h"] as? NSNumber)?.doubleValue else {
                hand.press("esc")
                let seen = (option?["options"] as? [String]) ?? []
                return end(line, fail("no option like \(want.debugDescription)\(seen.isEmpty ? " appeared" : "; the options are: " + seen.joined(separator: " | "))"))
            }
            let sx = web.width / page.viewport.width, sy = web.height / page.viewport.height
            await hand.click(at: CGPoint(x: web.minX + (x + w / 2) * sx, y: web.minY + (y + h / 2) * sy))
            try? await Task.sleep(for: .milliseconds(350))
            let now = await current()
            buddy.clearHighlight()
            let picked = option["text"] as? String ?? want
            if !now.isEmpty, !AXEngine.similar(now, picked), !now.lowercased().contains(picked.lowercased()) {
                return end(line, fail("clicked \(picked.debugDescription) but the field shows \(now.debugDescription)"))
            }
            return end(line, .init(ok: true, summary: "chose \(picked.debugDescription)\(now.isEmpty ? "" : " (field shows \(now.debugDescription))")"))

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
            let isCode = (try? await BrowserBridge.shared.perform("activeValue", on: page))?["code"] as? Bool ?? false
            buddy.setTyping(true)
            AXEngine.targetPid = app.processIdentifier
            await hand.enterText(text, codeEditor: isCode)
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
                // The caret is in something the page can't see: a native dialog over it (the upload picker's
                // "Go to folder" box, a Save sheet) or a frame. Type there if the app says a text field has focus.
                let role = AXEngine.focusedRole(of: app) ?? ""
                guard ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) else {
                    return end(line, fail("no text box on the page has focus; click one first (give its w-id)"))
                }
                AXEngine.targetPid = app.processIdentifier
                let landed = await hand.type(text, in: app)
                AXEngine.targetPid = nil
                guard landed else { return end(line, fail("the text didn't land in the focused field")) }
                if action["submit"] as? Bool == true {
                    try? await Task.sleep(for: .milliseconds(120))
                    hand.press("return")
                    try? await Task.sleep(for: .milliseconds(500))
                }
                context.fingerprint = await AXEngine.fingerprintAsync(of: app)
                return end(line, .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into the focused field (outside the page)\(action["submit"] as? Bool == true ? " and pressed Return" : "")"))
            }
            if let existing = before?["value"] as? String, !existing.isEmpty {
                AXEngine.targetPid = app.processIdentifier
                AXEngine.selectAll()
                AXEngine.targetPid = nil
                try? await Task.sleep(for: .milliseconds(60))
            }
            let isCode = (try? await BrowserBridge.shared.perform("activeValue", on: page))?["code"] as? Bool ?? false
            buddy.setTyping(true)
            AXEngine.targetPid = app.processIdentifier
            // Document editors (Google Docs) take the caret into an iframe: paste the whole text at once there.
            if before?["frame"] as? Bool == true { AXEngine.paste(text) }
            else { await hand.enterText(text, codeEditor: isCode) }
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
            // A specific file (e.g. the user's resume from memory), read without opening it.
            if let path = action["path"] as? String {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard let fileText = await Reader.fileText(url) else { return end(line, fail("couldn't read \(path)")) }
                return end(line, .init(ok: true, summary: "text of \(url.lastPathComponent):\n\(fileText)"))
            }
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
            let r = await Shell.run("/bin/zsh", ["-lc", cmd], timeout: 20)
            return end(line, .init(ok: r.status == 0, summary: "exit \(r.status)\(r.output.isEmpty ? "" : ": \(r.output.prefix(2000))")"))

        case "pdf":
            // iLovePDF-style jobs, done in the background with PDFKit; no app opens.
            guard let op = (action["op"] as? String)?.lowercased() else { return fail("pdf needs op") }
            let paths = (action["files"] as? [String]) ?? (action["file"] as? String).map { [$0] } ?? []
            let files = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let line = begin("PDF: \(op.replacingOccurrences(of: "_", with: " ")) \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")")
            do {
                return end(line, .init(ok: true, summary: try await Pdf.run(op, files: files, options: action)))
            } catch {
                return end(line, fail(error.localizedDescription))
            }

        case "media":
            // Video/audio jobs with AVFoundation: no time limit, and progress keeps the watchdog from stopping long exports.
            guard let op = (action["op"] as? String)?.lowercased() else { return fail("media needs op") }
            let paths = (action["files"] as? [String]) ?? (action["file"] as? String).map { [$0] } ?? []
            let files = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let title = "Video: \(op.replacingOccurrences(of: "_", with: " ")) \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")"
            let line = begin(title)
            do {
                let summary = try await Media.run(op, files: files, options: action) { [weak self] p in
                    guard let self, line < self.steps.count else { return }
                    self.lastProgress = Date()
                    self.steps[line].text = "\(title) · \(Int(p * 100))%"
                }
                if line < steps.count { steps[line].text = title }
                return end(line, .init(ok: true, summary: summary))
            } catch {
                return end(line, fail(error.localizedDescription))
            }

        case "email":
            // Sent by the Mail app in the background (draft:true opens it for the user to review instead).
            let list = { (key: String) in (action[key] as? [String]) ?? (action[key] as? String).map { [$0] } ?? [] }
            let to = list("to"), cc = list("cc")
            let files = list("files").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            guard !to.isEmpty, to.allSatisfy({ $0.contains("@") }) else { return fail("email needs to: real email addresses (recall or ask for them)") }
            if let missing = files.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) { return fail("no such file: \(missing.path)") }
            let draft = action["draft"] as? Bool ?? false
            let subject = (action["subject"] as? String) ?? files.first?.deletingPathExtension().lastPathComponent ?? ""
            // An address the user never gave (not in their request, what they selected, their answers or memory) may
            // come from a page or email trying to steer Clinqy: always confirm those, whatever the request said.
            let known = ([request, selectedText ?? ""] + userAnswers + Memory.facts).joined(separator: "\n").lowercased()
            let strangers = (to + cc).filter { !known.contains($0.lowercased()) }
            if !draft, !strangers.isEmpty {
                let reply = await askUser("Send this to \(strangers.joined(separator: ", "))? That address came from what I read, not from you.",
                                          options: ["Yes, send it", "No"])
                guard let reply, Safety.isYes(reply) else { return fail("the user didn't confirm sending to \(strangers.joined(separator: ", ")); don't send it") }
                userAnswers.append(strangers.joined(separator: " "))
            }
            if !draft, !(await confirmRisky("Send email")) { return fail("the user said not to send it") }
            let line = begin("\(draft ? "Draft" : "Email") \(to.joined(separator: ", "))\(files.isEmpty ? "" : " · \(files.count) attachment\(files.count == 1 ? "" : "s")")")
            let r = await Mailer.send(to: to, cc: cc, subject: subject, body: (action["body"] as? String) ?? "", attachments: files, draft: draft)
            return end(line, r.ok ? .init(ok: true, summary: draft ? "draft open in Mail for the user to review" : "sent from Mail to \(to.joined(separator: ", "))")
                                  : fail("Mail couldn't send: \(r.message.prefix(300))"))

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

        case "ask" where !reviewedForm && context.page != nil
                && (action["question"] as? String ?? "").range(of: #"(?i)\b(submit|apply|send (the |this |my )?(form|application))\b"#, options: .regularExpression) != nil:
            // Before "ready to submit?", show the user every answer on the form (and catch empty required ones).
            reviewedForm = true   // once per run, whatever happens
            let r = await reviewForm(context.page!)
            guard r.ok else { return await perform(action, context: &context) }   // no form found: just ask
            return .init(ok: false, summary: "NOT ASKED YET — the form review is on screen for the user:\n\(r.summary)\n"
                         + "If a required answer is missing or wrong, fix it first; otherwise ask your question again.")

        case "ask" where !checkedMemoryForAsk && Self.asksForPersonalDetails(action["question"] as? String ?? ""):
            // Before bothering the user for their own details, look in memory once; they may already be there.
            checkedMemoryForAsk = true
            let hits = Memory.search(action["question"] as? String ?? "")
            guard !hits.isEmpty else { return await perform(action, context: &context) }
            return .init(ok: false, summary: "NOT ASKED — you already remember this about the user (use it, and ask only for what's truly missing):\n"
                         + hits.prefix(15).map { "- \($0)" }.joined(separator: "\n"))

        case "ask" where qa != nil:
            return fail("this is an unattended test — nobody can answer; assert the missing information as a failed check and finish")

        case "assert":
            // QA: the model's verdict on an expectation, kept as a deterministic "text is visible" check.
            let text = (action["text"] as? String) ?? ""
            let pass = action["pass"] as? Bool ?? false
            let note = (action["note"] as? String) ?? ""
            let line = begin("Check “\(text.prefix(50))”")
            qa?.checks.append(.init(text: text, pass: pass, note: note))
            buddy.signal(pass)
            return end(line, .init(ok: true, summary: "recorded check: \(pass ? "PASS" : "FAIL") \(text)"))

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
            if sensitive { secrets.append(reply) } else { log("  user answered: \(reply.prefix(200))") }
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

        case "recall":
            let query = (action["query"] as? String) ?? ""
            let line = begin("Recall \(query.prefix(40))")
            let hits = Memory.search(query)
            return end(line, .init(ok: true, summary: hits.isEmpty ? "nothing remembered about that"
                                   : "remembered:\n" + hits.map { "- \($0)" }.joined(separator: "\n")))

        case "dictionary":
            // The app's own scripting vocabulary, for an applescript fallback.
            guard let app = context.app, Scripting.isScriptable(app) else { return fail("this app isn't scriptable") }
            let line = begin("Check \(app.cleanName ?? "the app")'s scripting")
            guard let dict = await Scripting.dictionary(for: app) else { return end(line, fail("couldn't read its dictionary")) }
            return end(line, .init(ok: true, summary: dict))

        case "look":
            return .init(ok: true, summary: "screenshot attached next turn", effect: .look)

        case "wait":
            let ms = min(5000, (action["ms"] as? Int) ?? 600)
            try? await Task.sleep(for: .milliseconds(ms))
            if let app = context.app { context.fingerprint = await AXEngine.fingerprintAsync(of: app) }
            return .init(ok: true, summary: "waited \(ms) ms")

        case "snap":
            // A step screenshot for a write-up: copied like ⌃⌘⇧4 (clipboard only, no file) and kept for paste_snaps.
            guard let app = context.app else { return fail("no app to screenshot") }
            let caption = (action["caption"] as? String) ?? "Step \(snaps.count + 1)"
            let line = begin("Screenshot: \(caption.prefix(40))")
            try? await Task.sleep(for: .milliseconds(300))   // let the last step finish drawing
            guard let png = await Screenshot.windowPNG(app: app) else { return end(line, fail("couldn't capture the window (Screen Recording permission?)")) }
            snaps.append((caption, png))
            let board = NSPasteboard.general
            board.clearContents()
            board.setData(png, forType: .png)
            return end(line, .init(ok: true, summary: "screenshot \(snaps.count) taken (\(caption.prefix(60).debugDescription)) and copied"))

        case "paste_snaps":
            // Into the document that has the caret: each caption, then its screenshot, in order.
            guard let app = context.app else { return fail("no app") }
            guard !snaps.isEmpty else { return fail("no screenshots taken yet; use snap first") }
            let line = begin("Paste \(snaps.count) screenshots")
            await Launcher.bringToFront(app)
            let board = NSPasteboard.general
            let saved = board.string(forType: .string)
            AXEngine.targetPid = app.processIdentifier
            defer { AXEngine.targetPid = nil }
            for (i, snap) in snaps.enumerated() {
                guard !Task.isCancelled else { break }
                board.clearContents()
                board.setString("Step \(i + 1): \(snap.caption)", forType: .string)
                AXEngine.press(0x09, flags: .maskCommand)
                try? await Task.sleep(for: .milliseconds(250))
                AXEngine.pressReturn()
                board.clearContents()
                board.setData(snap.png, forType: .png)
                AXEngine.press(0x09, flags: .maskCommand)
                try? await Task.sleep(for: .milliseconds(1800))   // Google Docs uploads the image
                AXEngine.pressReturn()
                AXEngine.pressReturn()
                try? await Task.sleep(for: .milliseconds(150))
            }
            board.clearContents()
            if let saved { board.setString(saved, forType: .string) }
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            return end(line, .init(ok: true, summary: "pasted \(snaps.count) captioned screenshots where the caret was"))

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
        lastTarget = .init(kind: "web", role: el.role, label: el.text)
        return (el, rect.intersection(web).isNull ? rect : rect.intersection(web))
    }

    private func refresh(_ context: inout ActionContext) async {
        guard let app = context.app else { return }
        let scan = await AXEngine.scan(app)
        context.elements = scan.elements
        context.fingerprint = scan.fingerprint
        // Keep the web page current too, so page actions in the same turn see what's actually there.
        if Launcher.isBrowser(app), BrowserBridge.shared.isConnected, let page = await BrowserBridge.shared.snapshot(for: app) {
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
        lastTarget = .init(kind: "ax", role: wanted.role, label: wanted.label)
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

    fileprivate func finish(ok: Bool, _ text: String) {
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
        if !isTest { recordStats(ok: ok, answer: text) }
        if !isTest { History.shared.add(.init(date: started, request: request, answer: text, ok: ok,
                                 steps: steps.map(\.text), app: targetApp?.cleanName, result: runResult,
                                 trace: trace.isEmpty ? nil : trace)) }
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

    fileprivate func log(_ text: String) {
        lastProgress = Date()
        var text = text
        for secret in secrets where secret.count >= 3 { text = text.replacingOccurrences(of: secret, with: "••••") }
        let line = String(format: "[%6.2fs] ", Date().timeIntervalSince(started)) + text
        if echo { print(line); fflush(stdout) }
        Self.writeLog(line)
    }

    /// Every run is also written to ~/Library/Logs/Clinqy/agent.log (for debugging and tests).
    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clinqy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent.log")
    }()

    static func writeLog(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        // Keep one old log (agent.log.1) once this one passes 5 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size]) as? Int, size > 5_000_000 {
            let old = logURL.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: logURL, to: old)
        }
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
            page = await BrowserBridge.shared.snapshot(for: app)
            // Still arriving (or nothing listed yet on a page that isn't blocked): give it a moment, once.
            if let p = page, p.ready == "loading" || (p.elements.isEmpty && p.problem == nil) {
                try? await Task.sleep(for: .milliseconds(700))
                page = await BrowserBridge.shared.snapshot(for: app) ?? page
            }
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
        Frontmost app: \(app.cleanName ?? "?")\(Launcher.isBrowser(app) ? " (browser)" : "")\(Scripting.isScriptable(app) && !Launcher.isBrowser(app) ? " (scriptable)" : "")
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
            if !page.messages.isEmpty { text += "\nMessages on the page: " + page.messages.map { "“\($0)”" }.joined(separator: " · ") }
            if page.above + page.below > 0 { text += "\nNot shown (scroll to reach): \(page.above) fields/buttons above, \(page.below) below." }
            if !page.text.isEmpty { text += "\nText on screen: \(page.text)" }
            if page.ready == "loading" { text += "\n(The page is still loading.)" }
            if let problem = page.problem { text += "\n(Couldn't read the page: \(problem). Use look and click by position, or read.)" }
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


// MARK: - Workflows: record, replay without a model, heal with one

struct QAContext {
    struct Check: Codable { let text: String; let pass: Bool; let note: String }
    let name: String
    var checks: [Check] = []
}

/// What a QA run produced (written as JSON for the `clinqy qa` command).
struct QAReport: Codable {
    let name: String
    let passed: Bool
    /// "replay" (no model), "learned" (first run, model), "healed" (replay fixed by the model)
    let mode: String
    let durationMs: Int
    let steps: [String]
    let checks: [QAContext.Check]
    let message: String
}

extension Agent {
    /// Adds a successful action to the trace in a replayable form.
    fileprivate func record(_ action: [String: Any]) {
        guard let kind = (action["do"] as? String)?.lowercased(),
              ["open_app", "open_url", "click", "type", "key", "scroll", "applescript", "assert"].contains(kind) else { return }
        var step = WorkflowStep(action: kind == "assert" ? "expect" : kind)
        step.name = action["name"] as? String
        step.url = action["url"] as? String
        step.text = action["text"] as? String
        step.keys = action["keys"] as? String
        step.dir = action["dir"] as? String
        step.script = action["script"] as? String
        step.submit = action["submit"] as? Bool
        if action["id"] != nil { step.target = lastTarget }
        if kind == "assert", action["pass"] as? Bool != true { return }   // only checks that held become expectations
        if kind == "click", step.target == nil { return }                 // position clicks can't be replayed reliably
        trace.append(step)
    }

    /// Replays a saved workflow with no model; if a step breaks, the model finishes the job and the workflow is updated.
    func runWorkflow(_ workflow: Workflow, params given: [String: String] = [:]) {
        guard !isRunning else { return }
        let params = (workflow.defaults ?? [:]).merging(given) { _, new in new }
        prepare("Workflow: \(workflow.name)", test: false)
        task = Task { await replayOrHeal(workflow, params: params) }
    }

    /// Runs a UI test: replays its compiled script (no model) or learns it (first run / --relearn), then writes a report.
    func runQA(name: String, test: String, compiled: URL, relearn: Bool, model: String?, report out: URL) {
        guard !isRunning else {
            Self.writeReport(QAReport(name: name, passed: false, mode: "none", durationMs: 0, steps: [], checks: [],
                                      message: "Clinqy is busy with another task"), to: out)
            return
        }
        prepare("QA: \(name)", test: true)
        qa = QAContext(name: name)
        modelOverride = model
        buddy.qaMode = true
        let started = Date()
        task = Task {
            var mode = "learned"
            if !relearn, let data = try? Data(contentsOf: compiled),
               let saved = try? JSONDecoder.iso8601.decode(Workflow.self, from: data) {
                mode = await replayOrHeal(saved, params: [:], qaTest: test) ? "healed" : "replay"
            } else {
                await run(Self.qaPrompt(name: name, test: test))
            }
            let finishedOK = phase == .done
            let checks = qa?.checks ?? []
            let passed = finishedOK && !checks.contains { !$0.pass }
            // Keep (or refresh) the compiled script when this run went through with the model.
            if finishedOK, mode != "replay", !trace.isEmpty {
                // A replay must start from the test's own page, freshly loaded: if the model skipped "Go to" because
                // the page was already open, the script would run on whatever an earlier test left behind.
                var steps = trace
                if let first = test.range(of: #"(?im)^\s*(?:go to|open|visit|navigate to)\s+(https?://\S+)"#, options: .regularExpression),
                   let url = test[first].range(of: #"https?://\S+"#, options: .regularExpression).map({ String(test[first][$0]) }),
                   steps.first?.action != "open_url" {
                    steps.insert(WorkflowStep(action: "open_url", url: url), at: 0)
                }
                let wf = Workflow(name: name, summary: "QA test", params: [], steps: steps, created: Date())
                try? FileManager.default.createDirectory(at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder.iso8601.encode(wf).write(to: compiled, options: .atomic)
            }
            Self.writeReport(QAReport(name: name, passed: passed, mode: mode, durationMs: Int(Date().timeIntervalSince(started) * 1000),
                                      steps: steps.map(\.text), checks: checks, message: answer), to: out)
            buddy.qaMode = false
            qa = nil
            modelOverride = nil
        }
    }

    static func writeReport(_ report: QAReport, to url: URL) {
        try? JSONEncoder.iso8601.encode(report).write(to: url, options: .atomic)
    }

    static func qaPrompt(name: String, test: String) -> String {
        """
        QA TEST “\(name)”. You are an automated UI tester. Carry out these steps exactly as written, in order:
        \(test)

        For every line that states an expectation (Expect / Check / Verify / Should…), look at the screen and report it
        with {"do":"assert","text":"<the expected text, as it would literally appear on screen>","pass":true|false,"note":"<what you saw>"}.
        Prefer exact on-screen text (a heading, label, value, title or URL), so the check can be repeated automatically.
        Nobody is watching: never ask anything. If a step can't be done, assert it as failed with a note, then finish.
        Finish with done:true and a one-line verdict.
        """
    }

    /// Returns true if the model had to step in.
    @discardableResult
    fileprivate func replayOrHeal(_ workflow: Workflow, params: [String: String], qaTest: String? = nil) async -> Bool {
        guard AXEngine.isTrusted else { finish(ok: false, "Turn on Accessibility for Clinqy."); return false }
        guard !Safety.screenLocked else { finish(ok: false, "The Mac is locked — unlock it and run again"); return false }
        var app = targetApp ?? NSWorkspace.shared.frontmostApplication
        phase = .acting
        buddy.mood = .acting
        log("replay “\(workflow.name)” · \(workflow.steps.count) steps, no model")
        for (i, step) in workflow.steps.enumerated() {
            guard !Task.isCancelled else { return false }
            narration = step.summary
            if step.action == "expect" {
                let want = step.action(params: params, id: nil)["text"] as? String ?? ""
                var pass = false
                for _ in 0..<5 {
                    if await Self.textVisible(want, app: app) { pass = true; break }
                    try? await Task.sleep(for: .milliseconds(600))
                }
                steps.append(Step(text: "Check “\(want.prefix(50))”", state: pass ? .ok : .failed))
                log("  \(pass ? "✓" : "✗") expect \(want)")
                buddy.signal(pass)
                if qa != nil {
                    qa?.checks.append(.init(text: want, pass: pass, note: pass ? "" : "not visible on screen"))
                    trace.append(step)
                    continue
                }
                if !pass { return await heal(workflow, from: i, reason: "expected “\(want)” isn't on screen", params: params, qaTest: qaTest) }
                continue
            }
            // Find the step's target on the current screen (UIs load at their own pace: retry a little).
            var obs = await Observation.capture(app)
            var id: String?
            if let target = step.target {
                for attempt in 0..<5 {
                    if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)); obs = await Observation.capture(app) }
                    id = Self.find(target, in: obs)
                    if id != nil { break }
                }
                guard id != nil else {
                    return await heal(workflow, from: i, reason: "couldn't find \(target.role) “\(target.label)”", params: params, qaTest: qaTest)
                }
            }
            var context = ActionContext(app: obs.app, elements: obs.elements, fingerprint: obs.fingerprint,
                                        page: obs.page, webArea: obs.webArea)
            lastTarget = nil
            let result = await perform(step.action(params: params, id: id), context: &context)
            guard result.ok else { return await heal(workflow, from: i, reason: result.summary, params: params, qaTest: qaTest) }
            trace.append(step)
            app = context.app
        }
        if var updated = Workflows.shared.all.first(where: { $0.id == workflow.id }) {
            updated.runs += 1
            Workflows.shared.update(updated)
        }
        finish(ok: true, qa != nil ? "Test finished (replayed, no model)" : "Done: \(workflow.name)")
        return false
    }

    /// A step broke: the model finishes from there, and the workflow is saved with the fixed steps.
    private func heal(_ workflow: Workflow, from index: Int, reason: String, params: [String: String], qaTest: String?) async -> Bool {
        log("  heal from step \(index + 1): \(reason)")
        steps.append(Step(text: "Step \(index + 1) changed (\(reason.prefix(60))) — adapting", state: .info))
        let remaining = workflow.steps[index...].enumerated().map { "\($0.offset + 1). \($0.element.summary)" }.joined(separator: "\n")
        var request = """
        You're continuing the saved workflow “\(workflow.name)”. Steps before this point already ran. It got stuck at: \
        \(workflow.steps[index].summary) — \(reason). Finish it from there, adapting to what's on screen now. Remaining steps:
        \(remaining)
        """
        if !params.isEmpty { request += "\nValues: " + params.map { "\($0.key) = \($0.value)" }.joined(separator: ", ") }
        if let qaTest { request = Self.qaPrompt(name: qa?.name ?? workflow.name, test: qaTest) + "\n\n" + request }
        phase = .thinking
        await run(request)
        // Only keep the healed version if it still does the whole job (a model that gave up mustn't shrink it).
        let doneSteps = workflow.steps.prefix(index).filter { $0.action != "expect" }.count
        let enough = trace.count > doneSteps && Double(trace.count) >= Double(workflow.steps.count) * 0.6
        if phase == .done, qa == nil, enough, var healed = Workflows.shared.all.first(where: { $0.id == workflow.id }) {
            healed.steps = trace
            healed.healedAt = Date()
            healed.runs += 1
            Workflows.shared.update(healed)
            log("  workflow updated with the fixed steps")
        }
        return true
    }

    /// The element on screen matching a saved target: exact role+label first, then the label alone, then containment.
    static func find(_ target: WorkflowStep.Target, in obs: Observation) -> String? {
        let want = target.label.lowercased()
        if target.kind == "web", let page = obs.page {
            let els = page.elements
            let hit = els.first { $0.role == target.role && $0.text.lowercased() == want }
                ?? els.first { $0.text.lowercased() == want }
                ?? els.first { $0.role == target.role && !want.isEmpty && $0.text.lowercased().contains(want) }
            return hit.map { "w\($0.index)" }
        }
        let els = obs.elements
        let i = els.firstIndex { $0.role == target.role && $0.label.lowercased() == want }
            ?? els.firstIndex { $0.label.lowercased() == want }
            ?? els.firstIndex { $0.role == target.role && !want.isEmpty && $0.label.lowercased().contains(want) }
        return i.map { "e\($0)" }
    }

    /// Deterministic check: does this text appear on screen (page text, element labels, window title)?
    static func textVisible(_ text: String, app: NSRunningApplication?) async -> Bool {
        let want = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty, let app else { return false }
        let obs = await Observation.capture(app)
        if obs.text.lowercased().contains(want) { return true }
        if let page = obs.page {
            if page.title.lowercased().contains(want) || page.url.lowercased().contains(want) { return true }
            if let r = try? await BrowserBridge.shared.perform("read", on: page), (r["text"] as? String ?? "").lowercased().contains(want) { return true }
        }
        return (await Reader.ocr(app))?.lowercased().contains(want) ?? false
    }
}

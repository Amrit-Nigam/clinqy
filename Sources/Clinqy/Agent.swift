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
    /// What the user copied in the last few minutes, when nothing was selected: "this" may mean it.
    struct Copied: Equatable { let text: String?; let files: [URL]; let age: TimeInterval }
    @Published var copied: Copied?
    /// Dry-run mode (sticky, from the command bar): the buddy shows every click and keystroke instead of doing it.
    @Published var dryRun = UserDefaults.standard.bool(forKey: "dryRun") {
        didSet { UserDefaults.standard.set(dryRun, forKey: "dryRun") }
    }
    /// This run is a dry run (the toggle, or a request starting "dry run:").
    private(set) var runDry = false
    var onStart: () -> Void = {}
    var onFinish: (_ answer: String, _ ok: Bool) -> Void = { _, _ in }
    /// Test mode: mirror progress to stdout with timings.
    var echo = false
    /// Test runs aren't saved to History and teach memory nothing.
    var isTest = false
    /// The run's last real step opened an app or page, so that's what the user wants to see at the end.
    private var openedLast = false
    /// A test run that still shows the review card before a form submit (answered via `clinqy://answer`).
    var reviewInTests = false
    /// A test run that still saves form answers to the job profile (tests/run.sh restores the profile after).
    var saveInTests = false

    private let buddy: Buddy
    private let hand: Hand
    fileprivate var task: Task<Void, Never>?
    private var session: ClaudeSession?
    fileprivate var started = Date()
    /// Whether this task already opened a browser tab (so later website visits reuse it).
    private var openedTab = false
    /// Step screenshots taken with snap, for paste_snaps. Kept across "continue"s of the same task (a write-up
    /// spans several runs); each is pasted once.
    private var snaps: [(caption: String, png: Data, pasted: Bool)] = []
    /// Runs this task continued on its own after running out of steps or stalling (see `finish`).
    private var autoContinues = 0
    /// The browser tab this task opened (the only tab it may navigate in place).
    private var ownedTab: Int?
    /// The user already said yes to a confirmation in this run.
    private var userConfirmed = false
    /// Names this run's folder of click traces; `clickCount` numbers them.
    private var runID = UUID().uuidString
    private var clickCount = 0
    /// Where the run started, for the replay cache (a similar request from the same place gets these steps as a hint).
    private var startPlace: (app: String?, url: String?, title: String?) = (nil, nil, nil)
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
    /// The last document this run read in full, kept in history so a follow-up ("now the answers") needn't find it again.
    private var readText: String?

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
        // Waiting on the user isn't a hang: say so in the log, and keep the buddy's bubble up until they answer.
        log("  waiting for your answer: \(sensitive ? "(hidden)" : String(text.prefix(120)))")
        buddy.bubble("need your input", for: 600)
        question = Question(text: text, options: options, sensitive: sensitive)
        onQuestion()
        let reply = await withCheckedContinuation { answerWaiter = $0 }
        buddy.bubble(nil)
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

    /// Before clicking a control on a web page: a form's final Submit shows the user every answer on the form and
    /// waits for Submit or Edit (instead of the plain question, so they're asked once); other consequential clicks get
    /// confirmRisky. nil = go ahead, else why not.
    private func approve(_ label: String, role: String, page: BrowserBridge.Page?) async -> String? {
        // Picking an option or ticking a box sends nothing, whatever its label says ("Send a notification to the
        // following SNS topic" is a choice in a form); only a control that acts needs the user's OK.
        guard Self.acts(role) else { return nil }
        if !userConfirmed, let page, Self.isFormSubmit(label), let ok = await reviewBeforeSubmit(page) {
            return ok ? nil : Self.editedReview
        }
        return await confirmRisky(label) ? nil
            : "the user said not to click \(label.prefix(40).debugDescription); stop and tell them where things stand"
    }

    /// A final summary that itself lists work still to do ("Steps 1–6 partly done … Still to do: …"), unless what's
    /// left needs the user (a login, a code, a confirmation link).
    nonisolated static func saysUnfinished(_ say: String) -> Bool {
        let unfinished = #"(?i)\b(still to do|still need to|remaining steps?|steps? (left|remaining)|left to do|not (yet )?(done|finished)|partly done|partially (done|complete)|next,? i('ll| will)|haven't (yet )?(done|finished|captured|added|started))\b"#
        let needsUser = #"(?i)\b(you need to|you'll need to|you have to|waiting (for|on) you|your (password|otp|code|login|approval|confirmation)|log ?in|sign ?in|confirm(ation)? (link|email)|click the (confirm|link))\b"#
        return say.range(of: unfinished, options: .regularExpression) != nil && say.range(of: needsUser, options: .regularExpression) == nil
    }

    /// Whether clicking an element of this role does something (a button, a link, a menu item), as opposed to
    /// choosing or ticking (radio, checkbox, option, tab) or focusing (a text box), which never needs a confirmation.
    nonisolated static func acts(_ role: String) -> Bool {
        let r = role.lowercased().replacingOccurrences(of: "ax", with: "", options: .anchored)
        return !["radio", "radiobutton", "checkbox", "switch", "option", "menuitemradio", "menuitemcheckbox", "tab",
                 "textbox", "textfield", "textarea", "searchfield", "combobox", "listbox", "row", "cell", "heading",
                 "statictext", "group", "radiogroup", "slider", "treeitem"].contains(r)
    }

    /// Why the step stopped when the user chose Edit on the review.
    private static var editedReview: String {
        "the user chose Edit on the review" + (UI.lastReviewNote.map { ": \"\($0)\". Make that change, then submit again" }
            ?? " without saying what; ask them what to change")
    }

    /// A form's final button ("Submit", "Submit application", "Send application"), not one that opens a form ("Easy Apply").
    nonisolated static func isFormSubmit(_ label: String) -> Bool {
        label.range(of: #"(?i)\bsubmit\b|^\s*(send|finish|complete) (my |the |your )?(application|form)\b"#, options: .regularExpression) != nil
    }

    /// Shows every answer on the page's form (question → answer) and waits for Submit or Edit. nil = no form here
    /// (or an unattended, dry or test run): the caller falls back to a plain confirmation.
    private func reviewBeforeSubmit(_ page: BrowserBridge.Page) async -> Bool? {
        guard qa == nil, !runDry, !isTest || reviewInTests,
              let r = try? await BrowserBridge.shared.perform("review", on: page, timeout: 8),
              let items = r["items"] as? [[String: Any]] else { return nil }
        let pairs = items.compactMap { i -> (String, String)? in
            guard let q = i["q"] as? String, !q.isEmpty else { return nil }
            return (q, i["answer"] as? String ?? "")
        }
        guard pairs.count >= 2 else { return nil }
        reviewedForm = true
        let ok = await UI.reviewBeforeSubmit(items: pairs, title: String((r["title"] as? String ?? page.title).prefix(70)))
        lastProgress = Date()
        if ok { userConfirmed = true }
        return ok
    }

    /// The user's reply to the current question (nil = they declined / cancelled).
    func answer(_ text: String?) {
        // A waiting review card takes the answer too (voice, `clinqy://answer`): "submit"/"yes" approves, anything
        // else is an edit to make first.
        if ReviewCenter.shared.pending != nil, answerWaiter == nil {
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let approve = t.range(of: #"(?i)^(submit|yes|ok|okay|go ahead|approve|send)\b"#, options: .regularExpression) != nil
            ReviewCenter.shared.decide(approve, note: approve ? nil : t)
            return
        }
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

    func submit(_ raw: String, test: Bool = false, auto: Bool = false) {
        if !auto { autoContinues = 0 }
        var request = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isRunning else { return }
        // "dry run: book a cab" rehearses just this request.
        var dry = dryRun
        if let r = request.range(of: #"(?i)^\(?(dry[ -]?run|rehearse|practice run)\)?[:,\s-]+"#, options: .regularExpression) {
            request.removeSubrange(r)
            dry = true
        }
        // "continue", "also make the answers": builds on the last task, even when typed or said after the follow-up mic closed.
        if continuation == nil, !test, let last = History.shared.entries.first,
           Date().timeIntervalSince(last.date) < 20 * 60, Router.isFollowUp(request) {
            continuation = last
        }
        let clear = { [weak self] in
            self?.selectedText = nil
            self?.annotation = nil
            self?.selectedFiles = []
            self?.copied = nil
            self?.continuation = nil
        }
        // A saved workflow that does exactly this: replay it with no model (the model only heals a broken step).
        if !test, !dry, let match = workflowFirst(request) {
            prepare(request, test: false)
            let params = (match.workflow.defaults ?? [:]).merging(match.params) { _, new in new }
            steps.append(Step(text: "Saved workflow “\(match.workflow.name.prefix(40))” — no model needed", state: .info))
            log("workflow-first: “\(match.workflow.name)” · params \(match.params)")
            task = Task {
                await replayOrHeal(match.workflow, params: params)
                clear()
            }
            return
        }
        prepare(request, test: test, dry: dry)
        task = Task {
            await run(request)
            clear()
        }
    }

    /// The saved workflow to replay for this request, when that's safe to do without the model: nothing selected,
    /// copied, circled or continued that the model would need to see, and not a question or a request about "this".
    private func workflowFirst(_ request: String) -> Router.Match? {
        guard Self.workflowFirstOn, selectedText == nil, selectedFiles.isEmpty, annotation == nil, continuation == nil,
              !Self.isQuestion(request), !Router.refersToContext(request), !Safety.micInUse else { return nil }
        return Router.match(request, in: Workflows.shared.all)
    }

    /// Saved workflows and runs that worked are replayed with no model when they fit exactly (WORKFLOW_FIRST=off stops it).
    static var workflowFirstOn: Bool { !["off", "0", "no", "false"].contains((Config.value("WORKFLOW_FIRST") ?? "on").lowercased()) }

    /// Resets per-run state; shared by requests, workflow replays and QA runs.
    fileprivate func prepare(_ request: String, test: Bool, dry: Bool = false) {
        isTest = test || echo
        runDry = dry
        started = Date()
        trace = []
        lastTarget = nil
        steps = []
        answer = ""
        input = ""
        narration = ""
        openedTab = false
        checkedMemoryForAsk = false
        lastFirst = ""
        shownFacts = []; visitedHosts = []; visitedApps = []
        pushedOn = 0
        profileOffered = []
        turnCount = 0; fastTurnCount = 0; lookCount = 0
        reviewedForm = false
        userAnswers = []
        if continuation == nil { snaps = [] }
        addedNotes = []
        readText = nil
        ownedTab = nil
        userConfirmed = false
        secrets = []
        runID = UUID().uuidString
        clickCount = 0
        startPlace = (nil, nil, nil)
        openedLast = false
        hand.beginRun(request: request)
        if !isTest { Task.detached(priority: .background) { Screenshot.pruneRuns() } }
        self.request = request
        runResult = nil
        phase = .thinking
        buddy.clearMark()
        onStart()
        startWatchdog()
        Replay.Recorder.shared.begin(request: request)
        Self.writeLog("=== \(dry ? "[dry run] " : "")\(request)\(selectedText.map { " [selection: \($0.count) chars]" } ?? "")\(selectedFiles.isEmpty ? "" : " [files: \(selectedFiles.map(\.lastPathComponent).joined(separator: ", "))]")\(annotation.map { " [circled: \(Int($0.rect.width))×\(Int($0.rect.height)) at \(Int($0.rect.minX)),\(Int($0.rect.minY))]" } ?? "")")
    }

    func cancel() {
        UI.cancelReview()
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
        var repeats = 0, sameRuns = 0
        // Loops already met with "change method" (a loop that comes back after that stops the run).
        var escalated: Set<String> = []
        var askedForAnswer = false
        var lastScreen = ""
        // What the model was last shown, so later turns can say only what changed (see screenText).
        var shown: Observation?
        var lastFullTurn = 0, lookedLastTurn = false
        let maxTurns = 50

        for turn in 0..<maxTurns {   // long forms take 30+ turns
            guard !Task.isCancelled else { return }
            if turn == maxTurns - 10 {
                message += "\n(\(turn) of \(maxTurns) steps used. If the current approach isn't getting closer, change it now; "
                    + "if the task can't be finished, finish with done:true and say where things stand.)"
            }
            let observeStart = Date()
            let obs = await Observation.capture(app)
            let observeMs = Int(Date().timeIntervalSince(observeStart) * 1000)
            if observeMs > 400 { log("  observe: \(observeMs) ms") }
            if turn == 0, continuation == nil, qa == nil {
                startPlace = (obs.app?.cleanName, obs.page?.url, obs.page?.title)
                // This exact request worked from here before, more than once, with nothing risky in it: replay its
                // steps with no model at all (the model only steps in if a step no longer fits the screen).
                if !isTest, !runDry, selectedText == nil, selectedFiles.isEmpty, annotation == nil, Self.workflowFirstOn,
                   let replay = ReplayCache.shared.replayable(request: request, app: obs.app?.cleanName, url: obs.page?.url, title: obs.page?.title) {
                    log("replay-first: this exact request worked here before — replaying \(replay.steps.count) steps, no model")
                    steps.append(Step(text: "Done exactly this before — replaying it, no model needed", state: .info))
                    session.close()
                    fast.close()
                    await replayOrHeal(replay, params: [:])
                    return
                }
                if let hint = ReplayCache.shared.hint(request: request, app: obs.app?.cleanName, url: obs.page?.url, title: obs.page?.title) {
                    message += hint
                    log("replay hint offered")
                }
            }
            // Know-how saved for the site or app the task is in now, the first time it gets there.
            let host = obs.page.map { Memory.bareHost($0.url) }.flatMap { $0.isEmpty ? nil : $0 }
            if let host { visitedHosts.insert(host) }
            if let name = obs.app?.cleanName { visitedApps.insert(name) }
            let notes = Memory.scoped(app: obs.app?.cleanName, host: host).filter { !shownFacts.contains($0) }
            if !notes.isEmpty {
                shownFacts.formUnion(notes)
                message += "\nNotes you saved for \(host ?? obs.app?.cleanName ?? "this app") (how to work it; follow them here):\n"
                    + notes.map { "- \($0)" }.joined(separator: "\n")
                log("  memory: \(notes.count) note\(notes.count == 1 ? "" : "s") for \(host ?? obs.app?.cleanName ?? "?")")
            }
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
                if image == nil, let blank = Screenshot.lastBlank { message += "\n" + blank.hint }
            }
            wantsLook = false
            // An unchanged screen is one line, not the whole list again (less to read, faster replies).
            let full = obs.text
            let screenUnchanged = full == lastScreen
            var screen = "Screen: unchanged since your last look."
            if !screenUnchanged || image != nil {
                // The whole list when the model may not have the last one in mind: the first turn, a screenshot (its
                // boxes carry e-ids), the turn after one, a failed step, another app or window, the fast helper's
                // turns, and every 6th turn; otherwise only what changed since.
                let fresh = turn == 0 || image != nil || lookedLastTurn || failures > 0 || turn - lastFullTurn >= 6
                    || !fast.leadHasContinuity
                screen = fresh ? full : Self.screenText(obs, since: shown) ?? full
                if screen == full { lastFullTurn = turn } else { log("  screen: changes only (\(screen.count) of \(full.count) chars)") }
            }
            lastScreen = full
            shown = obs
            lookedLastTurn = image != nil
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
            var context = ActionContext(app: obs.app, elements: obs.elements, fingerprint: obs.fingerprint,
                                        page: obs.page, webArea: obs.webArea)
            context.seen = obs.page
            context.identity = obs.app.flatMap(AXEngine.identity(of:))
            // The reply streams in: its first action starts as soon as it's written, while the model writes the rest
            // (a batch's first step no longer waits for the whole reply). EARLY_START=off turns it off.
            let (partials, sink) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let sent = message, failed = failures, shot = image
            let stream: @Sendable (String) -> Void = { text in _ = sink.yield(text) }
            let partial = Self.earlyStartOn ? stream : nil
            let replying = Task { @MainActor () throws -> String in
                defer { sink.finish() }
                return try await fast.reply(to: turnText, message: sent, image: shot, failures: failed, lead: session, partial: partial)
            }
            var early: (action: [String: Any], result: ActionResult, target: WorkflowStep.Target?)?
            for await text in partials {
                guard let first = Brain.firstAction(inPartial: text) else { continue }
                if Self.startsEarly(first), Self.canonical(first) != lastFirst, addedNotes.isEmpty, !Task.isCancelled {
                    phase = .acting
                    buddy.mood = .acting
                    log("  early start: \(FastLane.brief(first)) (while the model writes the rest)")
                    lastTarget = nil
                    let result = await perform(first, context: &context)
                    early = (first, result, lastTarget)
                }
                break
            }
            let reply: String
            do { reply = try await withTaskCancellationHandler { try await replying.value } onCancel: { replying.cancel() } } catch {
                if Task.isCancelled { return }
                return finish(ok: false, error.localizedDescription)
            }
            if Task.isCancelled { return }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log("turn \(turn) · \(ms) ms · \(fast.tag)\(reply.prefix(300))")
            Replay.Recorder.shared.turn(reply: reply, ms: ms)
            turnCount += 1
            if fast.tag.hasPrefix("fast") { fastTurnCount += 1 }
            if image != nil { lookCount += 1 }

            guard let json = Brain.json(from: reply) else {
                message = "Your last reply wasn't a JSON object. Reply with JSON only."
                    + (early.map { "\n(Its first step already ran: \(FastLane.brief($0.action)) → \($0.result.summary))" } ?? "")
                continue
            }
            let say = (json["say"] as? String) ?? ""
            // A bare action ({"do":"ask",…}) instead of the wrapper is still a clear intent.
            let actions = (json["actions"] as? [[String: Any]]) ?? (json["do"] is String ? [json] : [])
            let isDone = json["done"] as? Bool == true
            // The model saw the last failure and chose to do nothing (usually to finish): that's its answer to it,
            // so it no longer blocks finishing. Without this a failed step before a plain "done" loops to the step cap.
            if actions.isEmpty { failures = 0 }
            if !say.isEmpty, !isDone { narration = say }

            // A loop is the same actions three times with nothing changing (scrolling on through a page isn't one);
            // turns with no actions (thinking, finishing) never are. The first time, the actions aren't run again:
            // the model is told to change method, with a screenshot. Only the same loop after that stops the run.
            // The same step while the screen keeps changing is progress (Next through a wizard, pages of results):
            // only a long run of it (12) counts, and the step cap bounds the rest.
            let signature = actions.map { "\($0)" }.joined()
            let same = !actions.isEmpty && signature == lastSignature
            sameRuns = same ? sameRuns + 1 : 0
            repeats = same && (screenUnchanged || failures > 0) ? repeats + 1 : 0
            lastSignature = signature
            if !actions.isEmpty, escalated.contains(signature) && repeats >= 1 || ((repeats >= 2 || sameRuns >= 12) && escalated.count >= 2) {
                return finish(ok: false, "I kept trying the same thing, so I stopped")
            }
            if repeats >= 2 || sameRuns >= 12 {
                let why = repeats >= 2 ? "3× with nothing changing" : "\(sameRuns + 1)×"
                escalated.insert(signature)
                repeats = 0; sameRuns = 0
                wantsLook = true
                log("  loop: same actions \(why) — asking for another method")
                steps.append(Step(text: "Same step repeated — trying another way", state: .info))
                message = "Your last reply repeated the same actions again (\(actions.map(FastLane.brief).joined(separator: ", "))) "
                    + "and they aren't getting anywhere, so they were NOT run again. That approach failed: don't send it again. "
                    + "Use a different method, in this order: the keyboard (tab/shift+tab to reach the control, space or return to press it, "
                    + "arrows in lists, esc to close a popup), then the other id for it (its e-id from Accessibility instead of the w-id, or "
                    + "the reverse), then click by x/y on the screenshot attached now. If the goal can't be reached, finish with done:true and say what's blocking."
                    + (early.map { " (Only its first step had already started: \(FastLane.brief($0.action)) → \($0.result.summary))" } ?? "")
                continue
            }

            if !actions.isEmpty {
                phase = .acting
                buddy.mood = .acting
            }
            var results: [String] = []
            // Part of the batch didn't run because the page changed under it (not a failure, but not finished either).
            var cutShort = false
            // The action started early is this batch's first step; if the final reply doesn't start with it after all,
            // the model still hears that it ran.
            let earlyIsFirst = early.map { e in actions.first.map { Self.canonical($0) == Self.canonical(e.action) } ?? false } ?? false
            if let e = early, !earlyIsFirst {
                results.append("(already done while you were writing: \(FastLane.brief(e.action)) → \(e.result.summary))")
                if !e.result.ok { failures += 1 }
            }
            lastFirst = actions.first.map(Self.canonical) ?? ""
            for (i, action) in actions.enumerated() {
                guard !Task.isCancelled else { return }
                // The user added something mid-batch: the rest of this plan may be outdated, re-plan first.
                if !addedNotes.isEmpty {
                    results.append("(stopped before step \(i + 1): the user added something — see above)")
                    break
                }
                lastTarget = nil
                var action = action
                let kind = (action["do"] as? String ?? "").lowercased()
                // click/type/open_* already wait for the screen to settle; a wait stacked on top is mostly dead time.
                if kind == "wait", i > 0,
                   ["click", "type", "open_url", "open_app", "key"].contains(actions[i - 1]["do"] as? String ?? ""),
                   (action["ms"] as? Int ?? 600) > 1000 {
                    action["ms"] = 1000
                }
                // The ids the model gave point into the page list it was shown; if the page was listed again since
                // (a field appeared or went away), use the same element's id in the current list — never a neighbour's.
                if Self.isWebRef(action["id"]), let seen = context.seen, let now = context.page {
                    guard let n = Self.webIndex(action["id"]), let id = Self.rematch(n, from: seen, to: now) else {
                        let was = Self.webIndex(action["id"]).flatMap { n in seen.elements.first { $0.index == n } }
                        results.append("\(i + 1). (not done: the page changed after the steps above, and \(action["id"] ?? "?")"
                                       + "\(was.map { " (\($0.role) \($0.text.prefix(40).debugDescription))" } ?? "") isn't there anymore; "
                                       + "the rest of this batch was skipped — the fresh page is below)")
                        cutShort = true
                        break
                    }
                    if id != n {
                        log("    w\(n) is now w\(id) (the page re-listed)")
                        action["id"] = "w\(id)"
                    }
                }
                // Trailing look after page actions: the page list the next turn brings is exact and fresh, so a
                // screenshot adds time, not information. A look on its own is always honoured.
                if kind == "look", i > 0, Self.pageListSuffices(context, after: actions[..<i]) {
                    results.append("\(i + 1). look skipped — the fresh page list below shows the result (send look on its own "
                                   + "if you need pixels: pictures, canvas, iframes, a native dialog)")
                    continue
                }
                let result: ActionResult
                if i == 0, earlyIsFirst, let e = early {
                    result = e.result
                    lastTarget = e.target   // so the step is recorded with the element it acted on
                } else {
                    result = await perform(action, context: &context)
                }
                if result.ok, !runDry { record(action) }
                // Opening something was only a step if more work followed in it (see `keepsFrontApp`).
                if result.ok, ["click", "type", "key", "choose", "upload", "scroll", "applescript", "fill", "autofill"].contains((action["do"] as? String ?? "").lowercased()) {
                    openedLast = false
                }
                if case .look = result.effect { wantsLook = true }
                results.append("\(i + 1). \(result.summary)")
                if !result.ok { failures += 1; break }
                failures = 0
                // A click or key that brought another app forward (a link opening the browser, a share sheet): the rest
                // of the batch was planned for the old screen, so stop here; the next turn looks at the new app.
                if ["click", "key", "type"].contains(kind), !runDry, i + 1 < actions.count, let current = context.app,
                   let other = AXEngine.handoff(from: current), other.bundleIdentifier != Bundle.main.bundleIdentifier {
                    log("    \(other.cleanName ?? "another app") came to the front")
                    results.append("(\(other.cleanName ?? "another app") came to the front, so the rest of this batch was skipped — its screen is below)")
                    context.app = other
                    cutShort = true
                    break
                }
                // Forms re-render as they're filled (LinkedIn adds and drops fields): before the next step by w-id, list
                // the page again so it lands on the element the model meant, not whatever now sits at that index.
                if ["type", "choose", "click", "upload", "autofill"].contains(kind), context.page != nil, !runDry,
                   actions[(i + 1)...].contains(where: { Self.isWebRef($0["id"]) }) {
                    await relist(&context)
                }
            }
            app = context.app
            // A final reply may carry last actions; finish once they ran (unless one failed).
            if isDone, failures == 0, !addedNotes.isEmpty || cutShort {
                message = "Results:\n" + results.joined(separator: "\n")
                    + (cutShort ? "\n(You were about to finish, but not all of your last steps ran.)" : "\n(You were about to finish, but the user added something.)")
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
            if isDone, failures == 0, pushedOn < 2, Self.saysUnfinished(say) {
                pushedOn += 1
                log("  not done yet: “\(say.prefix(80))” — carrying on")
                message = (results.isEmpty ? "" : "Results:\n" + results.joined(separator: "\n") + "\n")
                    + "You were about to finish, but your own summary says work remains (\"\(say.prefix(200))\"). The user wants the "
                    + "whole task done without having to say continue: do the remaining steps now. Finish only when everything is "
                    + "done, or when something truly needs the user (say exactly what)."
                continue
            }
            if isDone, failures == 0 {
                finish(ok: true, say.isEmpty ? "Done" : say)
                if !runDry, !isTest {
                    // Credit the remembered facts this run put to work, so they rank higher next time.
                    let output = (steps.map(\.text) + trace.compactMap(\.text) + [say]).joined(separator: "\n")
                    Memory.noteUsed(Memory.used(among: shownFacts, output: output, apps: visitedApps, hosts: visitedHosts))
                }
                if !runDry { await learn(from: session) }
                return
            }
            if actions.isEmpty { results.append("(no actions taken)") }
            message = "Results:\n" + results.joined(separator: "\n")
        }
        finish(ok: false, "Ran out of steps, so I stopped. Last done: \(steps.last?.text ?? "nothing"). Check the screen before retrying.")
    }

    private var checkedMemoryForAsk = false
    /// The last turn's first action (canonical JSON): the same one again isn't started early, since a repeat may be
    /// a loop the turn's checks stop.
    private var lastFirst = ""

    /// Streamed replies start their first action before the model has finished writing (EARLY_START=off stops it).
    static var earlyStartOn: Bool { !["off", "0", "no", "false"].contains((Config.value("EARLY_START") ?? "on").lowercased()) }

    /// Steps worth starting while the model is still writing: ones that act on the screen, not questions, waits,
    /// looks or anything sent outside the screen (email, shell, scripts, schedules).
    nonisolated static func startsEarly(_ action: [String: Any]) -> Bool {
        ["click", "type", "choose", "scroll", "key", "open_url", "open_app", "autofill", "upload", "read", "review"]
            .contains((action["do"] as? String ?? "").lowercased())
    }

    nonisolated static func canonical(_ action: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: action, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "\(action)"
    }

    /// Memory facts this run was shown (up front, as notes for a site or app, or recalled): the ones the run then used
    /// rank higher next time.
    private var shownFacts: Set<String> = []
    /// Sites and apps this run worked in (for crediting scoped notes, and telling learning where it was).
    private var visitedHosts: Set<String> = [], visitedApps: Set<String> = []
    /// Times this run was told to carry on after finishing with work left (see `saysUnfinished`).
    private var pushedOn = 0
    /// Questions the profile already answered this run (the next time the model asks one, it's asked for real).
    private var profileOffered: Set<String> = []
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

    /// Fills every visible field, dropdown and radio group the job profile answers, in this one action (each still a
    /// real, checked type / choose / click), and tells the model what's left. Never submits anything.
    private func autofill(context: inout ActionContext) async -> ActionResult {
        guard let page = context.page else { return fail("autofill needs a web page") }
        let profile = Profile.current
        let plan = FormFill.plan(page) { Profile.answer(for: $0, in: profile) }
        log("  autofill: \(plan.steps.count) to fill, \(plan.open.count) open")
        var filled: [String] = [], failed: [String] = []
        for step in plan.steps {
            guard !Task.isCancelled, addedNotes.isEmpty else { break }
            var action = step.action
            // Forms re-render as they're filled: aim at the same field in the latest listing.
            if let n = Self.webIndex(action["id"]), let now = context.page {
                guard let id = Self.rematch(n, from: page, to: now) else { failed.append("\(step.question) (the field went away)"); continue }
                action["id"] = "w\(id)"
            }
            lastTarget = nil
            let r = await perform(action, context: &context)
            if r.ok {
                filled.append("\(step.question) → \(step.answer.prefix(60))")
                if !runDry { record(action) }
            } else {
                failed.append("\(step.question): \(r.summary.replacingOccurrences(of: "FAILED: ", with: "").prefix(120))")
            }
            if context.page != nil, !runDry { await relist(&context) }
        }
        var summary = filled.isEmpty ? "nothing on screen that the profile answers" : "filled \(filled.count) from the profile:\n"
            + filled.map { "- \($0)" }.joined(separator: "\n")
        if !failed.isEmpty { summary += "\ncouldn't fill (do these yourself):\n" + failed.map { "- \($0)" }.joined(separator: "\n") }
        if !plan.open.isEmpty {
            summary += "\nnot in the profile (fill from memory/resume, or ask the user once; remember_answer what they say):\n"
                + plan.open.map { "- \($0)" }.joined(separator: "\n")
        }
        if plan.uploads > 0 { summary += "\n\(plan.uploads) upload field\(plan.uploads == 1 ? "" : "s") here: upload the resume yourself." }
        if let now = context.page, now.below > 0 { summary += "\n\(now.below) more fields/buttons below: scroll, then autofill again." }
        // A partial fill is still progress; only "nothing done and something broke" is a failure.
        return filled.isEmpty && !failed.isEmpty ? fail(summary) : .init(ok: true, summary: summary)
    }

    /// Requests whose point is what ends up on screen ("open Spotify", "show me my calendar", "search …"): the app
    /// they end in stays in front instead of the user's previous one coming back.
    nonisolated static func keepsFrontApp(_ request: String) -> Bool {
        request.range(of: #"(?i)^\s*(please |can you |could you )?(open|launch|start|switch to|go to|take me to|show( me)?|play|search|find|look up|google|navigate|bring up|pull up)\b"#,
                      options: .regularExpression) != nil
    }

    /// A request that may lead to an application form (where the job-application profile applies).
    static func mayMeetForms(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(appl(y|ication)|job|internship|intern|form|fill|resume|cv|role|position|opening|hiring|linkedin|naukri|greenhouse|lever|workday)"#,
                   options: .regularExpression) != nil
    }

    /// "Submit with your resume attached?", "Should I go ahead?": asks for a decision, not for details.
    nonisolated static func isConfirmation(_ text: String) -> Bool {
        // Only the question itself: "(I won't submit the form yet)" after it isn't what's being asked.
        let question = text.firstIndex(of: "?").map { String(text[...$0]) } ?? text
        // "What/Who should I put for …?" asks for a detail, not for a go-ahead.
        if question.range(of: #"(?i)\b(what|which|who|whom|where|when|how much|how many)\b.*\bshould i (put|enter|use|write|fill|type|say|give|choose|select|answer|add|list|mention)\b"#,
                          options: .regularExpression) != nil { return false }
        return question.range(of: #"(?i)\b(submit|send it|should i|shall i|go ahead|ready to|confirm|okay to|ok to)\b"#, options: .regularExpression) != nil
    }

    /// The profile's answer to an ask that's a single form question it covers, as (question, answer).
    static func profileAnswer(for action: [String: Any]) -> (String, String)? {
        guard let q = action["question"] as? String, !isConfirmation(q), action["sensitive"] as? Bool != true,
              q.filter({ $0 == "?" }).count <= 1 else { return nil }
        // Only the question itself: a side remark after it ("…? I'll enter your name as …") isn't what's asked.
        let asked = q.firstIndex(of: "?").map { String(q[...$0]) } ?? q
        guard let a = Profile.answer(for: asked) else { return nil }
        // A multiple-choice question takes the profile's answer only when it is one of the choices.
        let options = (action["options"] as? [String] ?? []).map { $0.lowercased() }
        if !options.isEmpty, !options.contains(where: { $0.contains(a.lowercased()) || a.lowercased().contains($0) }) { return nil }
        return (q, a)
    }

    /// A question for the user's own details (name, email, phone, college…), which memory may already hold.
    nonisolated static func asksForPersonalDetails(_ question: String) -> Bool {
        // Confirmations ("Submit with your resume attached?") aren't requests for details.
        if isConfirmation(question) { return false }
        // "your (full) name", "your phone number": the detail right after "your" — not any "you … name" in a sentence
        // ("Which session did you attend? (I'll use the name …)" asks for a choice, not for a detail).
        return question.range(of: #"(?i)\byour\s+(\w+\s+){0,2}?(name|e-?mail|phone|mobile|number|college|university|cgpa|gpa|degree|graduat\w*|linkedin|github|portfolio|address|city|gender|birth|dob|age|skills?|stack|experience|resume|cv)\b"#,
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
    /// places) and know-how for the sites and apps it worked in, so next time is faster. The model sees only the
    /// facts closest to this task (not the whole memory) and answers with edits — add, update, remove — so memory
    /// stays one clean line per thing instead of piling up near-duplicates. Runs in the background once the user
    /// already has their answer.
    private func learn(from session: ClaudeSession) async {
        guard !Task.isCancelled, !isTest else { return }
        let about = ([request] + steps.suffix(25).map(\.text) + [answer]).joined(separator: "\n")
        let near = Memory.relevant(to: about, app: targetApp?.cleanName, limit: 30).facts
        let places = (visitedHosts.sorted() + visitedApps.sorted()).joined(separator: ", ")
        let prompt = """
        The task is finished. Update what you remember from what this task revealed. Worth keeping: lasting facts \
        about the user — people and where to reach them (which app/chat), preferences (seats, airlines, food, tone), \
        usual apps, home/work city, frequent places, accounts or usernames — and know-how for a site or app that \
        cost you steps here and would save them next time (where something lives, a trick that worked, the name an \
        app must be opened with). Never passwords, card numbers, OTPs, one-off details, job applications (the \
        application tracker holds those) or what merely happened to be on screen.
        Places this task worked in: \(places.isEmpty ? "(none)" : places)
        Related things you already remember (numbered):
        \(near.isEmpty ? "(nothing yet)" : near.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        Reply with JSON only: {"ops":[…]}, each op one of
          {"add":"<short fact>","scope":"site:<host>" | "app:<App name>" | null}   something new; scope only for know-how that matters just there
          {"update":<n>,"to":"<fact n, corrected or with the new detail>"}         fact n changed or gained a detail
          {"remove":<n>,"why":"<what this task showed>"}                            fact n is no longer true
        {"ops":[]} if nothing is new.
        """
        guard let reply = try? await session.send(prompt), let json = Brain.json(from: reply) else { return }
        var ops = json["ops"] as? [[String: Any]] ?? []
        if let legacy = json["facts"] as? [String] { ops += legacy.map { ["add": $0] } }
        let line = { (v: Any?) -> String? in
            guard let t = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count < 240 else { return nil }
            return t
        }
        let fact = { (v: Any?) -> String? in
            guard let n = (v as? NSNumber)?.intValue ?? Int(v as? String ?? ""), n >= 1, n <= near.count else { return nil }
            return near[n - 1]
        }
        var removed = 0
        for op in ops {
            if let new = line(op["add"]) {
                if let known = Memory.nearDuplicate(of: new) {
                    log("🧠 already known: \(known.prefix(80))")
                    continue
                }
                Memory.add(new, scope: Memory.Scope(op["scope"] as? String))
                log("🧠 remembered: \(new)\((op["scope"] as? String).map { " [\($0)]" } ?? "")")
            } else if let old = fact(op["update"]), let new = line(op["to"]), new != old {
                // A rewrite keeps every email, link and number unless it's clearly the same fact with a new value.
                let sameSubject = Set(Memory.words(old).map(Memory.stem)).intersection(Memory.words(new).map(Memory.stem)).count >= 2
                guard MemoryTidy.safe(before: [old], after: [new], removed: []) || sameSubject && !Memory.details(new).isEmpty else {
                    log("🧠 update skipped (it would drop details): \(old.prefix(60))")
                    continue
                }
                if Memory.update(old, to: new) { log("🧠 updated: \(old) → \(new)") }
            } else if let old = fact(op["remove"]), removed < 2, !Memory.isProfile(old) {
                // The old line stays in the log, so a wrong removal can be put back.
                if Memory.remove(old) {
                    removed += 1
                    log("🧠 forgot (\((op["why"] as? String ?? "superseded").prefix(60))): \(old)")
                }
            }
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
        // Only when the request points at it: a copied password or key shouldn't ride along with every request.
        if selectedText == nil, selectedFiles.isEmpty, let copied,
           Router.refersToContext(request) || request.range(of: #"(?i)\b(clipboard|copied|paste|pasted)\b"#, options: .regularExpression) != nil {
            let when = Clipboard.describeAge(copied.age)
            if let t = copied.text {
                text += "\nClipboard (the user copied this \(when); nothing is selected, so \"this\", \"it\", \"that\" usually mean it — "
                    + "but only if the request fits it, e.g. \"translate this\", \"reply to this\", \"add this to my tracker\"):\n\"\"\"\n\(t.prefix(4000))\n\"\"\""
            }
            if !copied.files.isEmpty {
                text += "\nFiles on the clipboard (copied \(when); \"this\"/\"these\" may mean them):\n" + copied.files.map { "- \($0.path)" }.joined(separator: "\n")
            }
        }
        if runDry {
            text += "\nDRY RUN: the user wants to see what you'd do without anything happening. Clicks, typing, keys, choosing, "
                + "uploads, emails, file/calendar changes and scripts are only shown on screen, not done — the screen won't change "
                + "after them. Opening apps/websites, scrolling, reading and looking do happen. Plan the whole task as if each "
                + "shown step worked, go as far as you can, then finish with done:true and a short summary of the plan."
        }
        if let circled = annotation {
            let r = circled.rect
            text += "\nThe user circled an area on screen before asking (\"this\", \"here\", \"that\" usually mean it): "
                + "x \(Int(r.minX))–\(Int(r.maxX)), y \(Int(r.minY))–\(Int(r.maxY)) in screen points. It's the yellow loop on the first screenshot."
        }
        if let earlier = continuation {
            if let task = earlier.task, task != earlier.request {
                text += "\n\nThe task this is all part of (the user's own instructions, still in force until everything is done):\n\(task)"
            }
            text += """

            This continues an earlier task (\(earlier.date.formatted(date: .abbreviated, time: .shortened))):
            Earlier request: \(earlier.request)
            What happened: \(earlier.steps.suffix(12).joined(separator: "; "))
            Earlier result: \(earlier.answer)\(earlier.result.map { "\nEarlier output: \($0.plain.prefix(1500))" } ?? "")
            """
            if let doc = earlier.readText {
                text += "\nThe document the earlier task read (use this; don't open it again unless it's cut off):\n\(doc)"
            }
            if !earlier.ok {
                text += "\nThe earlier task didn't finish. Pick up where it stopped (check what's already on screen, e.g. a half-typed message) instead of starting over."
            }
        }
        let skills = Skills.shared.promptText
        if !skills.isEmpty {
            text += "\nSkills the user taught you (follow the matching one's steps when a request fits; ask for any missing parameters):\n" + skills
            if let hint = Router.skillHint(request, names: Skills.shared.all.map(\.name)) {
                text += "\n(This request looks like the skill “\(hint)”: use its steps unless it clearly doesn't fit.)"
            }
        }
        // Only the memory that matters for this request (plus core facts); the rest is one recall away.
        let context = [request, targetApp?.cleanName ?? "", selectedText ?? "", continuation?.request ?? ""].joined(separator: " ")
        let (facts, omitted) = Memory.relevant(to: context, app: targetApp?.cleanName)
        shownFacts.formUnion(facts)
        let profile = facts.filter(Memory.isProfile), other = facts.filter { !Memory.isProfile($0) }
        text += "\nThe user's profile (their own details: fill forms with these and never ask for them; the latest line wins if two disagree):\n"
            + "- Full name: \(NSFullUserName())\n" + profile.map { "- \($0)" }.joined(separator: "\n")
        if !other.isEmpty { text += "\nOther things you remember about the user:\n" + other.map { "- \($0)" }.joined(separator: "\n") }
        if omitted > 0 { text += "\n(\(omitted) more remembered facts not shown — use recall if you need something about the user that isn't here.)" }
        // The job-application profile, for requests that may meet a form (it's long, and nothing else needs it).
        if Self.mayMeetForms(context) {
            let jobProfile = Profile.promptBlock
            if !jobProfile.isEmpty { text += "\n" + jobProfile }
        }
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
        /// The page list the model's w-ids refer to (what it was shown this turn); `page` may be a newer listing.
        var seen: BrowserBridge.Page?
        /// The app's process as scanned: a pid alone can be reused by a relaunch.
        var identity: AXEngine.ProcessIdentity?
    }

    struct ActionResult {
        enum Effect { case none, look }
        let ok: Bool
        let summary: String
        var effect: Effect = .none
    }

    fileprivate func perform(_ action: [String: Any], context: inout ActionContext) async -> ActionResult {
        let kind = (action["do"] as? String ?? "").lowercased()
        if runDry, let shown = await rehearse(kind, action, context: &context) { return shown }
        switch kind {
        case "open_app":
            guard let name = action["name"] as? String else { return fail("open_app needs a name") }
            let line = begin("Open \(name)")
            guard let app = await hand.openApp(named: name) else { return end(line, fail("Couldn't find an app called \(name)")) }
            context.app = app
            openedLast = true
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
            // Ask this browser, not whichever one has the extension too (Arc and Chrome both connected).
            let before = context.app.map(Launcher.isBrowser) == true ? await bridge.activeTab(in: context.app) : nil
            let emptyTab = before.map { Self.isNewTabPage($0.url) } ?? false
            // Each site gets its own tab ("open github and wikipedia" = two tabs); staying on the same site in our
            // own tab (youtube.com → a YouTube search) reuses it.
            let host = { (u: String) in (URL(string: u)?.host ?? "").replacingOccurrences(of: "www.", with: "") }
            let sameSite = before.map { host($0.url) == host(url.absoluteString) && !host($0.url).isEmpty } ?? false
            let reuse = before != nil && (emptyTab || (before?.id == ownedTab && sameSite))
            let browser = await hand.openURL(url, current: context.app, newTab: !reuse)
            openedTab = true
            if let before, let after = await bridge.activeTab(in: browser ?? context.app) {
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
            openedLast = true
            registerNavigationUndo(line, label: "Leave \(url.host ?? raw)", closing: reuse ? nil : ownedTab, app: context.app)
            return end(line, .init(ok: true, summary: "opened \(url.absoluteString) in \(context.app?.cleanName ?? "the browser")"))

        case "click" where Self.isWebRef(action["id"]):
            guard let (el, rect) = await liveWebTarget(action["id"], &context) else { return fail(goneMessage(action["id"])) }
            let line = begin("Click \(el.text.prefix(32))")
            let submits = Self.isFormSubmit(el.text) || Safety.needsConfirmation(label: el.text, request: request) != nil
            if let why = await approve(el.text, role: el.role, page: context.page) { return end(line, fail(why)) }
            if let app = context.app { await Launcher.bringToFront(app) }
            let urlBefore = el.role == "link" ? await BrowserBridge.shared.activeTab(in: context.app)?.url : nil
            // A real mouse click, like a person: many sites (Google Forms, React apps) ignore script clicks. Each way of
            // clicking is checked for an effect before the next is tried: mouse, then a click through the page, then
            // (for toggles, tabs and options, whose state shows whether it took) focus + a key. A site where the mouse
            // keeps doing nothing gets the page click first.
            let page = context.page!
            let host = Clicks.host(page.url)
            let state = { (try? await BrowserBridge.shared.perform("state", on: page, ["index": el.index]))?["sig"] as? String }
            let before = await state()
            // Did it do anything? Unknown (the state couldn't be read) counts as yes, as a person wouldn't click twice.
            let tookEffect = { () async -> Bool in
                guard let before else { return true }
                for k in 0..<4 {
                    if await state() != before { return true }
                    if k < 3 { try? await Task.sleep(for: .milliseconds(120)) }
                }
                return false
            }
            // Where it is now, once it has stopped moving, and a spot on it that isn't covered: the listed position goes
            // stale when a popup re-lays out, and a mouse click that misses lands on the backdrop (LinkedIn's Easy Apply
            // then closes and asks to save the application).
            var point = CGPoint(x: rect.midX, y: rect.midY), mouse = true
            if let spot = try? await BrowserBridge.shared.perform("locate", on: page, ["index": el.index]),
               let web = context.webArea, let hit = spot["hit"] as? Bool {
                func d(_ k: String) -> Double? { (spot[k] as? NSNumber)?.doubleValue }
                let sx = web.width / page.viewport.width, sy = web.height / page.viewport.height
                let px = d("px") ?? ((d("x") ?? 0) + (d("w") ?? 0) / 2), py = d("py") ?? ((d("y") ?? 0) + (d("h") ?? 0) / 2)
                point = CGPoint(x: web.minX + px * sx, y: web.minY + py * sy)
                mouse = hit && web.contains(point)
            }
            // Something of another app's over that spot (a notification, a popup): click through the page instead.
            let pid = context.app?.processIdentifier ?? 0
            if mouse, let why = Hand.hitMismatch(at: point, pid: pid, window: nil) {
                log("    \(why) — clicking through the page")
                mouse = false
            }
            var order = mouse ? ["mouse", "script"] : ["script"]
            if mouse, Clicks.prefersScript(host) { order = ["script", "mouse"] }
            var method = "", worked = false, tries = 0, mouseTried = false, mouseWorked = false, scriptWorked = false
            for way in order {
                tries += 1
                method = way
                if way == "mouse" {
                    mouseTried = true
                    traceClick(point, in: context.app)
                    await hand.click(at: point)
                } else {
                    do { _ = try await BrowserBridge.shared.perform("click", on: page, ["index": el.index]) }
                    catch { return end(line, fail(error.localizedDescription)) }
                }
                worked = await tookEffect()
                if way == "mouse" { mouseWorked = worked } else { scriptWorked = worked }
                if worked { break }
            }
            let keyable: Set<String> = ["checkbox", "radio", "switch", "tab", "option", "menuitemcheckbox", "menuitemradio", "treeitem"]
            if !worked, !submits, keyable.contains(el.role),
               (try? await BrowserBridge.shared.perform("focusFor", on: page, ["index": el.index]))?["focused"] as? Bool == true {
                tries += 1
                method = "key"
                hand.press(["checkbox", "switch", "menuitemcheckbox", "radio"].contains(el.role) ? "space" : "return")
                worked = await tookEffect()
            }
            Clicks.note(host, mouseTried: mouseTried, mouseWorked: mouseWorked, scriptWorked: scriptWorked)
            log(Clicks.line(kind: "web", place: host, method: method, worked: worked, tries: tries))
            buddy.clearHighlight()
            if submits {
                // Sent: undoing the typing that went into it would only confuse the page.
                StepUndo.shared.clear()
            } else if ["checkbox", "switch"].contains(el.role), line < steps.count {
                let index = el.index
                StepUndo.shared.register(step: steps[line].id, kind: .toggle, label: "Click “\(el.text.prefix(30))” back") {
                    (try? await BrowserBridge.shared.perform("click", on: page, ["index": index])) != nil
                }
            } else if let urlBefore, let now = await BrowserBridge.shared.activeTab(in: context.app)?.url, now != urlBefore {
                registerNavigationUndo(line, label: "Go back from \(URL(string: now)?.host ?? "that page")", closing: nil, app: context.app)
            }
            return end(line, .init(ok: true, summary: "clicked \(el.role) \(el.text.prefix(60).debugDescription) on the page"
                                   + (worked ? "" : " (nothing on the page visibly changed, even after trying other ways to click it)")))

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
            // A site with its own upload button (no field until it's clicked) gets the file through that button's
            // request for one; failing that, the Mac file picker it opens is driven like a person would.
            guard let path = (action["file"] ?? action["path"]) as? String else { return fail("upload needs file") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url) else { return fail("can't read \(url.path)") }
            guard data.count < 15_000_000 else { return fail("\(url.lastPathComponent) is too big to upload this way (\(data.count / 1_000_000) MB)") }
            var target: (BrowserBridge.PageElement, CGRect)?
            if Self.isWebRef(action["id"]) {
                guard let found = await liveWebTarget(action["id"], &context) else { return fail(goneMessage(action["id"])) }
                target = found
            }
            let page = context.page!
            let index = target?.0.index ?? -1
            let line = begin("Upload \(url.lastPathComponent)")
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let args: [String: Any] = ["index": index, "name": url.lastPathComponent, "type": type, "data": data.base64EncodedString()]
            var why = ""
            do {
                let r = try await BrowserBridge.shared.perform("upload", on: page, args, timeout: 20)
                guard r["ok"] as? Bool == true else { return end(line, fail("the page didn't take the file")) }
                try? await Task.sleep(for: .milliseconds(800))   // sites upload/parse it (Greenhouse fills fields from a resume)
                return end(line, .init(ok: true, summary: "attached \(url.lastPathComponent) to the upload field (now holds: \((r["files"] as? [String] ?? []).joined(separator: ", ")))"))
            } catch {
                why = error.localizedDescription
            }
            guard let (el, rect) = target else {
                return end(line, fail("\(why) — give the id of the site's upload button (upload goes through it), or click it if it opens its own picker (Google Forms uses Google Drive)"))
            }
            if let r = try? await BrowserBridge.shared.perform("uploadVia", on: page, args, timeout: 20), r["ok"] as? Bool == true {
                try? await Task.sleep(for: .milliseconds(800))
                log("    upload: through the page's own button")
                return end(line, .init(ok: true, summary: "attached \(url.lastPathComponent) through \(el.text.prefix(40).debugDescription) (now holds: \((r["files"] as? [String] ?? []).joined(separator: ", ")))"))
            }
            if let app = context.app, let done = await uploadThroughPicker(url, at: CGPoint(x: rect.midX, y: rect.midY), app: app) {
                return end(line, done)
            }
            return end(line, fail("\(why). Clicking \(el.text.prefix(40).debugDescription) didn't ask for a file or open the Mac file picker — "
                                  + "if it opened the site's own menu or picker (Google Drive, Dropbox…), choose its \"from this device\" option there"))

        case "review" where context.page != nil:
            return await reviewForm(context.page!)

        case "autofill" where context.page != nil:
            return await autofill(context: &context)

        case "choose" where Self.isWebRef(action["id"]):
            // A dropdown in one step: open it with a real click (type to filter if it's a search box), find the
            // option by its text, click it, then check the field shows it. Works for native selects, Google Forms
            // listboxes and React-style comboboxes (Greenhouse, Lever…).
            guard let want = (action["option"] ?? action["text"]) as? String, !want.isEmpty else { return fail("choose needs option") }
            guard let (el, rect) = await liveWebTarget(action["id"], &context), let page = context.page, let app = context.app,
                  let web = context.webArea else { return fail(goneMessage(action["id"])) }
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
            if let why = await hand.click(at: CGPoint(x: rect.midX, y: rect.midY), pid: app.processIdentifier) { return end(line, fail(why)) }
            if el.editable {
                // A search-as-you-type box: typing narrows the list to the option.
                try? await Task.sleep(for: .milliseconds(150))
                AXEngine.targetPid = app.processIdentifier
                await hand.enterText(want, codeEditor: false)
                AXEngine.targetPid = nil
            }
            var option: [String: Any]?
            var lastError: Error?
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(200))
                do { option = try await BrowserBridge.shared.perform("findOption", on: page, ["text": want, "index": el.index], timeout: 6) }
                catch { lastError = error }
                if option?["found"] as? Bool == true { break }
            }
            if option?["found"] as? Bool != true, let lastError { log("    findOption: \(lastError.localizedDescription)") }
            let picked: String
            if let option, option["found"] as? Bool == true,
               let x = (option["x"] as? NSNumber)?.doubleValue, let y = (option["y"] as? NSNumber)?.doubleValue,
               let w = (option["w"] as? NSNumber)?.doubleValue, let h = (option["h"] as? NSNumber)?.doubleValue {
                let px = (option["px"] as? NSNumber)?.doubleValue ?? x + w / 2, py = (option["py"] as? NSNumber)?.doubleValue ?? y + h / 2
                let sx = web.width / page.viewport.width, sy = web.height / page.viewport.height
                if let why = await hand.click(at: CGPoint(x: web.minX + px * sx, y: web.minY + py * sy), pid: app.processIdentifier) {
                    hand.press("esc")
                    return end(line, fail(why))
                }
                picked = option["text"] as? String ?? want
                log(Clicks.line(kind: "option", place: Clicks.host(page.url), method: "mouse", worked: true, tries: 1))
            } else if let viaKeys = await chooseWithKeys(want, el: el, page: page) {
                // No list the page shows as options (or not the one wanted): the arrow keys walk the dropdown's choices.
                picked = viaKeys
                log(Clicks.line(kind: "option", place: Clicks.host(page.url), method: "key", worked: true, tries: 2))
            } else {
                hand.press("esc")
                log(Clicks.line(kind: "option", place: Clicks.host(page.url), method: "none", worked: false, tries: 2))
                let seen = (option?["options"] as? [String]) ?? []
                return end(line, fail("no option like \(want.debugDescription)\(seen.isEmpty ? " appeared" : "; the options are: " + seen.joined(separator: " | "))"))
            }
            try? await Task.sleep(for: .milliseconds(350))
            let now = await current()
            buddy.clearHighlight()
            if !now.isEmpty, !AXEngine.similar(now, picked), !now.lowercased().contains(picked.lowercased()) {
                return end(line, fail("clicked \(picked.debugDescription) but the field shows \(now.debugDescription)"))
            }
            return end(line, .init(ok: true, summary: "chose \(picked.debugDescription)\(now.isEmpty ? "" : " (field shows \(now.debugDescription))")"))

        case "type" where Self.isWebRef(action["id"]):
            guard let text = action["text"] as? String else { return fail("type needs text") }
            guard let (el, rect) = await liveWebTarget(action["id"], &context), let page = context.page, let app = context.app
            else { return fail(goneMessage(action["id"])) }
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
            if let why = await hand.click(at: CGPoint(x: rect.midX, y: rect.midY), pid: app.processIdentifier) { return end(line, fail(why)) }
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
            let old = (try? await BrowserBridge.shared.perform("value", on: page, ["index": el.index]))?["value"] as? String ?? ""
            if !old.isEmpty {
                _ = try? await BrowserBridge.shared.perform("fill", on: page, ["index": el.index, "text": ""])
            }
            let active = try? await BrowserBridge.shared.perform("activeValue", on: page)
            let isCode = active?["code"] as? Bool ?? false
            buddy.setTyping(true)
            AXEngine.targetPid = app.processIdentifier
            await hand.enterText(text, codeEditor: isCode)
            AXEngine.targetPid = nil
            buddy.setTyping(false)
            // A password field took secure input: never set it behind the user's back either.
            if let why = hand.refusal { return end(line, fail(why)) }
            // Keys queue up in the browser; wait until the field shows them before moving on (or focus could
            // move to the next field while this one's last keys are still in flight).
            var value: String?
            for _ in 0..<12 {
                value = (try? await BrowserBridge.shared.perform("value", on: page, ["index": el.index]))?["value"] as? String
                if let v = value, AXEngine.similar(v, text) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // (A code editor's field isn't its text: setting it would corrupt the editor.)
            if !isCode, let value, !AXEngine.similar(value, text) || value.count > text.count + 3 {
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
            if action["submit"] as? Bool != true, line < steps.count {
                let index = el.index
                StepUndo.shared.register(step: steps[line].id, kind: .text, label: old.isEmpty ? "Clear “\(el.text.prefix(30))”" : "Put back the earlier text in “\(el.text.prefix(30))”") {
                    (try? await BrowserBridge.shared.perform("fill", on: page, ["index": index, "text": old])) != nil
                }
            }
            let editor = (active?["editorKind"] as? String).map { " (a \($0) code editor: it may re-indent)" } ?? ""
            return end(line, .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into \(el.role) \(el.text.prefix(40).debugDescription)\(editor)\(action["submit"] as? Bool == true ? " and pressed Return" : "")"))

        case "type" where action["id"] == nil && context.page != nil:
            guard let text = action["text"] as? String, let page = context.page, let app = context.app else { return fail("type needs text") }
            let line = begin("Type “\(text.prefix(40))”")
            await Launcher.bringToFront(app)
            let before = try? await BrowserBridge.shared.perform("activeValue", on: page)
            guard before?["editable"] as? Bool == true else {
                let result = await typeOutsidePage(text, submit: action["submit"] as? Bool == true, app: app,
                                                   pageFocused: before?["hasFocus"] as? Bool ?? false, context: &context)
                buddy.clearHighlight()
                return end(line, result)
            }
            if let existing = before?["value"] as? String, !existing.isEmpty {
                AXEngine.targetPid = app.processIdentifier
                AXEngine.selectAll()
                AXEngine.targetPid = nil
                try? await Task.sleep(for: .milliseconds(60))
            }
            let editor = before?["editorKind"] as? String
            buddy.setTyping(true)
            AXEngine.targetPid = app.processIdentifier
            // Document editors (Google Docs) take the caret into an iframe: paste the whole text at once there.
            if before?["frame"] as? Bool == true { AXEngine.paste(text) }
            else { await hand.enterText(text, codeEditor: before?["code"] as? Bool ?? false) }
            AXEngine.targetPid = nil
            buddy.setTyping(false)
            if let why = hand.refusal { return end(line, fail(why)) }
            if let value = (try? await BrowserBridge.shared.perform("activeValue", on: page))?["value"] as? String,
               !AXEngine.similar(value, text) || value.count > text.count + 3 {
                let r = try? await BrowserBridge.shared.perform("fillActive", on: page, ["text": text])
                // A code editor can't be set directly (it would corrupt it): what it shows is the result.
                if r?["skipped"] as? Bool == true, let shows = r?["value"] as? String, !AXEngine.similar(shows, text) {
                    buddy.clearHighlight()
                    return end(line, fail("the \(editor ?? "code") editor shows \(shows.prefix(200).debugDescription), not the text typed "
                                          + "(auto-indent or auto-closed brackets?). Fix what differs rather than typing it all again"))
                }
            }
            if action["submit"] as? Bool == true {
                try? await Task.sleep(for: .milliseconds(120))
                hand.press("return")
                try? await Task.sleep(for: .milliseconds(500))
            }
            buddy.clearHighlight()
            let into = editor.map { "the focused code editor (\($0))" } ?? "the focused field"
            return end(line, .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into \(into)\(action["submit"] as? Bool == true ? " and pressed Return" : "")"))

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
                guard let fileText = await Reader.fileText(url) else {
                    let sandboxed = url.path.contains("/Library/Containers/") || url.path.contains("/Library/Group Containers/")
                    return end(line, fail("couldn't read \(path)" + (sandboxed ? " — it's inside another app's sandbox, which can't be read or copied by path. Open it in Preview and use read with no path (it copies all its text)" : "")))
                }
                readText = "\(url.lastPathComponent):\n\(fileText)"
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
            // A document whose file is out of reach (a PDF from WhatsApp's sandbox opened in Preview): copy all its text
            // instead of reading it a screenful at a time.
            if short(text), let app = context.app,
               app.bundleIdentifier == "com.apple.Preview" || AXEngine.documentURL(of: app) != nil {
                await Launcher.bringToFront(app)
                if let all = AXEngine.copiedAll(of: app), !short(all) {
                    text = String(all.prefix(12_000))
                    source = "the document (all its text)"
                }
            }
            if short(text), let app = context.app, let seen = await Reader.ocr(app) {
                text = seen
                source = "the screen (text recognition)"
            }
            guard let text, !text.isEmpty else { return end(line, fail("couldn't read any text here; try look")) }
            if !source.hasPrefix("the screen") { readText = "\(source):\n\(text)" }
            return end(line, .init(ok: true, summary: "text from \(source):\n\(text)"))

        case "click" where action["id"] == nil && action["x"] == nil && action["text"] is String:
            // By the text it shows, found on the window with text recognition: for apps whose buttons and rows the
            // Accessibility tree doesn't show (WhatsApp, Electron and Catalyst apps, canvases), steadier than x/y guesses.
            guard let app = context.app, let want = (action["text"] as? String)?.trimmingCharacters(in: .whitespaces), !want.isEmpty else {
                return fail("click needs an id, a text or x/y")
            }
            let line = begin("Click “\(want.prefix(32))”")
            if let why = staleApp(context) { return end(line, fail(why)) }
            if let why = await approve(want, role: "button", page: context.page) { return end(line, fail(why)) }
            await Launcher.bringToFront(app)
            guard let boxes = await Reader.textBoxes(app, want: want) else { return end(line, fail("can't read the window (Screen Recording permission?)")) }
            let key = { (t: String) in t.lowercased().folding(options: .diacriticInsensitive, locale: nil).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            let w = key(want)
            // Exactly that text first, then a line that holds it as words; top to bottom, left to right.
            var hits = boxes.filter { key($0.text) == w }
            if hits.isEmpty {
                hits = boxes.filter { (" " + key($0.text) + " ").contains(" " + w + " ") }
            }
            hits.sort { abs($0.rect.minY - $1.rect.minY) > 6 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
            // The same spot found twice (the part and its whole line): keep one.
            var spots: [(text: String, rect: CGRect)] = []
            for h in hits where !spots.contains(where: { $0.rect.intersects(h.rect) }) { spots.append(h) }
            let nth = max(1, (action["nth"] as? NSNumber)?.intValue ?? 1)
            guard spots.count >= nth else {
                let near = boxes.map(\.text).filter { AXEngine.similar($0, want) }.prefix(5)
                return end(line, fail("no text \(want.debugDescription) on the window\(near.isEmpty ? "" : "; similar: " + near.map(\.debugDescription).joined(separator: ", "))"))
            }
            let spot = spots[nth - 1]
            let point = CGPoint(x: spot.rect.midX, y: spot.rect.midY)
            await buddy.travel(to: point, framing: spot.rect)
            traceClick(point, in: app)
            let fingerprint = await AXEngine.fingerprintAsync(of: app)
            if let why = await hand.click(at: point, pid: app.processIdentifier) { return end(line, fail(why)) }
            let didChange = await changed(app, from: fingerprint, ms: 600)
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            buddy.clearHighlight()
            log(Clicks.line(kind: "text", place: app.cleanName ?? "", method: "real", worked: didChange, tries: 1))
            let more = spots.count > nth ? " (\(spots.count) places show it; this was #\(nth) from the top — add \"nth\" for another)" : ""
            return end(line, .init(ok: true, summary: "clicked the text \(spot.text.debugDescription)\(more)\(didChange ? "" : " (no visible change)")"))

        case "click" where action["id"] == nil:
            // By position on the last screenshot, for things with no element (canvas, custom-drawn UI, text links).
            guard let x = (action["x"] as? NSNumber)?.doubleValue, let y = (action["y"] as? NSNumber)?.doubleValue,
                  let p = Screenshot.screenPoint(x: x, y: y) else { return fail("click needs an id, or x/y on the last screenshot") }
            let line = begin("Click")
            if let why = staleApp(context) { return end(line, fail(why)) }
            if let app = context.app { await Launcher.bringToFront(app) }
            traceClick(p, in: context.app)
            if let why = await hand.click(at: p, pid: context.app?.processIdentifier) { return end(line, fail(why)) }
            try? await Task.sleep(for: .milliseconds(450))
            if let app = context.app { context.fingerprint = await AXEngine.fingerprintAsync(of: app) }
            return end(line, .init(ok: true, summary: "clicked at (\(Int(x)), \(Int(y))) on the screenshot"))

        case "click":
            guard let app = context.app else { return fail("no app") }
            guard let el = await resolve(action["id"], context: &context) else { return fail("element \(action["id"] ?? "?") isn't on screen anymore") }
            let line = begin("Click \(el.shortLabel)")
            if let why = staleApp(context) { return end(line, fail(why)) }
            if let why = await approve(el.label, role: el.role, page: nil) { return end(line, fail(why)) }
            await Launcher.bringToFront(app)
            traceClick(el.center, in: app)
            if let why = await hand.click(el, in: app, fingerprint: context.fingerprint) { return end(line, fail(why)) }
            let didChange = await changed(app, from: context.fingerprint, ms: 600)
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            log(Clicks.line(kind: "ax", place: app.cleanName ?? "", method: hand.lastMethod, worked: didChange, tries: hand.lastMethod == "real" ? 2 : 1))
            buddy.clearHighlight()
            if Self.isFormSubmit(el.label) || Safety.needsConfirmation(label: el.label, request: request) != nil {
                StepUndo.shared.clear()   // sent: putting back what was typed into it would only confuse
            } else if el.role == "AXCheckBox" || el.role == "AXSwitch", line < steps.count {
                let element = el.element
                StepUndo.shared.register(step: steps[line].id, kind: .toggle, label: "Click “\(el.shortLabel)” back") {
                    await Task.detached { AXEngine.axPress(element) }.value
                }
            }
            return end(line, .init(ok: true, summary: "clicked \(el.describe)\(didChange ? "" : " (no visible change)")"))

        case "type":
            guard let app = context.app else { return fail("no app") }
            guard let text = action["text"] as? String else { return fail("type needs text") }
            let submit = action["submit"] as? Bool ?? false
            let line = begin("Type “\(text.prefix(40))”")
            await Launcher.bringToFront(app)
            if let why = staleApp(context) { return end(line, fail(why)) }
            var target = "the focused field"
            if action["id"] != nil {
                guard let el = await resolve(action["id"], context: &context) else { return end(line, fail("element \(action["id"] ?? "?") isn't on screen anymore")) }
                if let why = await hand.focus(el, in: app) { return end(line, fail(why)) }
                target = el.describe
            }
            // What the field held, to put back on undo (never for a password field).
            let field = Self.focusedElement(of: app)
            let old = field.flatMap { Safety.isSecureField($0) ? nil : Self.axValue($0) }
            guard await hand.type(text, in: app) else {
                return end(line, fail(hand.refusal ?? "the text didn't land in \(target) (field shows \((AXEngine.focusedValueShown(of: app) ?? "nothing").prefix(60).debugDescription))"))
            }
            if !submit, let field, let old, line < steps.count {
                StepUndo.shared.register(step: steps[line].id, kind: .text, label: old.isEmpty ? "Clear \(target)" : "Put back the earlier text in \(target)") {
                    AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, old as CFString) == .success
                }
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
            guard hand.press(keys) else { return end(line, fail(hand.refusal ?? "unknown key \(keys)")) }
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
            // A glob that matches nothing stays as typed (so `ls a/*.pem b/*.pem` still lists what exists) instead of
            // zsh aborting the whole line with "no matches found".
            let r = await Shell.run("/bin/zsh", ["-lc", "setopt no_nomatch 2>/dev/null\n" + cmd], timeout: 20)
            let hint = r.status == 0 ? "" : Self.shellHint(r.output)
            return end(line, .init(ok: r.status == 0, summary: "exit \(r.status)\(r.output.isEmpty ? "" : ": \(r.output.prefix(2000))")\(hint)"))

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

        case "ask" where !reviewedForm && !userConfirmed && context.page != nil
                && (action["question"] as? String ?? "").range(of: #"(?i)\b(submit|apply|send (the |this |my )?(form|application))\b"#, options: .regularExpression) != nil:
            // "Ready to submit?" is answered by the review: every answer on the form, with Submit or Edit.
            reviewedForm = true   // once per run, whatever happens
            let line = begin("Review before submitting")
            guard let ok = await reviewBeforeSubmit(context.page!) else { return await perform(action, context: &context) }   // no form: just ask
            return end(line, ok ? .init(ok: true, summary: "the user checked every answer on the form and approved submitting: submit now, without asking again")
                                : fail(Self.editedReview))

        case "ask" where qa == nil && !profileOffered.contains(action["question"] as? String ?? "") && Self.profileAnswer(for: action) != nil:
            // Standard application answers (CTC, notice period, links…) and earlier form answers are in the profile.
            // Once per question: if it doesn't fit, asking again goes through.
            let (q, a) = Self.profileAnswer(for: action)!
            profileOffered.insert(q)
            log("  profile answers “\(q.prefix(60))”")
            return .init(ok: false, summary: "NOT ASKED — the job-application profile already answers this: \(q) → \(a). Use it.")

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
            // An answer to an application form's question is kept for the next application that asks it (never a code).
            if !sensitive, !isTest || saveInTests, qa == nil, context.page != nil, Self.mayMeetForms(request), !Self.isConfirmation(text),
               text.range(of: #"(?i)\b(otp|code|password|passcode|pin|cvv)\b"#, options: .regularExpression) == nil,
               reply.count < 300, !Safety.isYes(reply) {
                Profile.remember(question: text, answer: reply)
            }
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
            shownFacts.formUnion(hits.prefix(5))
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

        case "wait" where action["for"] is String:
            return await waitFor(action["for"] as! String, gone: action["gone"] as? Bool == true,
                                 seconds: min(30, max(1, (action["timeout"] as? NSNumber)?.doubleValue ?? 10)), context: &context)

        case "wait":
            let ms = min(5000, (action["ms"] as? Int) ?? 600)
            guard let app = context.app, ms >= 1500 else {
                try? await Task.sleep(for: .milliseconds(ms))
                if let app = context.app { context.fingerprint = await AXEngine.fingerprintAsync(of: app) }
                return .init(ok: true, summary: "waited \(ms) ms")
            }
            // Most long waits are "let it load": they end once it has — the screen changed and then held still for
            // 0.8 s. A screen that never changes gets the full wait (then it's for something outside, like an email).
            let started = Date()
            var last = await AXEngine.fingerprintAsync(of: app)
            var changed = false, stillSince = Date()
            while Date().timeIntervalSince(started) * 1000 < Double(ms), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let now = await AXEngine.fingerprintAsync(of: app)
                if now != last { changed = true; stillSince = Date(); last = now }
                else if changed, Date().timeIntervalSince(stillSince) >= 0.8 { break }
            }
            context.fingerprint = last
            let waited = Int(Date().timeIntervalSince(started) * 1000)
            return .init(ok: true, summary: waited < ms - 200 ? "waited \(waited) ms (the screen settled)" : "waited \(ms) ms")

        case "snap":
            // A step screenshot for a write-up: copied like ⌃⌘⇧4 (clipboard only, no file) and kept for paste_snaps.
            guard let app = context.app else { return fail("no app to screenshot") }
            let caption = (action["caption"] as? String) ?? "Step \(snaps.count + 1)"
            let line = begin("Screenshot: \(caption.prefix(40))")
            try? await Task.sleep(for: .milliseconds(300))   // let the last step finish drawing
            guard let png = await Screenshot.windowPNG(app: app) else { return end(line, fail("couldn't capture the window (Screen Recording permission?)")) }
            snaps.append((caption, png, false))
            if snaps.count > 60 { snaps.removeFirst(snaps.count - 60) }
            let board = NSPasteboard.general
            board.clearContents()
            board.setData(png, forType: .png)
            return end(line, .init(ok: true, summary: "screenshot \(snaps.count) taken (\(caption.prefix(60).debugDescription)) and copied"))

        case "paste_snaps":
            // Into the document that has the caret: each caption, then its screenshot, in order.
            guard let app = context.app else { return fail("no app") }
            let todo = snaps.indices.filter { !snaps[$0].pasted }
            guard !todo.isEmpty else {
                return fail(snaps.isEmpty ? "no screenshots taken yet; use snap first" : "all \(snaps.count) screenshots are already pasted; snap new steps first")
            }
            let line = begin("Paste \(todo.count) screenshots")
            await Launcher.bringToFront(app)
            let board = NSPasteboard.general
            let saved = board.string(forType: .string)
            AXEngine.targetPid = app.processIdentifier
            defer { AXEngine.targetPid = nil }
            for i in todo {
                guard !Task.isCancelled else { break }
                let snap = snaps[i]
                snaps[i].pasted = true
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
            return end(line, .init(ok: true, summary: "pasted \(todo.count) captioned screenshots where the caret was (steps \(todo.first! + 1)–\(todo.last! + 1))"))

        case "remember":
            guard let fact = action["fact"] as? String else { return fail("remember needs fact") }
            Memory.add(fact, scope: Memory.Scope(action["scope"] as? String))
            steps.append(Step(text: "Remembered: \(fact)", state: .info))
            return .init(ok: true, summary: "saved")

        case "extract":
            // Structured data out of the page's tables, a CSV, or a document/screen's text for the model to structure.
            let line = begin("Extract data")
            if let path = (action["path"] ?? action["file"]) as? String {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                if ["csv", "tsv"].contains(url.pathExtension.lowercased()), let rows = Tables.readDelimited(url) {
                    return end(line, .init(ok: true, summary: "\(url.lastPathComponent): \(rows.count) rows\n"
                        + rows.prefix(500).map { $0.joined(separator: " | ") }.joined(separator: "\n")))
                }
                guard let text = await Reader.fileText(url) else { return end(line, fail("couldn't read \(path)")) }
                return end(line, .init(ok: true, summary: "text of \(url.lastPathComponent) (pick out the rows/fields yourself):\n\(text.prefix(12000))"))
            }
            if let page = context.page {
                let tables = (try? await BrowserBridge.shared.perform("tables", on: page, timeout: 8))?["tables"] as? [[String: Any]] ?? []
                if !tables.isEmpty {
                    return end(line, .init(ok: true, summary: "\(tables.count) table\(tables.count == 1 ? "" : "s") on \(page.title.prefix(60).debugDescription):\n"
                        + Tables.describe(tables).prefix(15000)))
                }
                let text = (try? await BrowserBridge.shared.perform("read", on: page))?["text"] as? String ?? page.text
                return end(line, .init(ok: true, summary: "no tables on the page; its text (pick out the rows yourself):\n\(text.prefix(12000))"))
            }
            if let app = context.app, let doc = await Reader.documentText(of: app) {
                return end(line, .init(ok: true, summary: "text of \(doc.name) (pick out the rows/fields yourself):\n\(doc.text.prefix(12000))"))
            }
            if let app = context.app, let seen = await Reader.ocr(app) {
                return end(line, .init(ok: true, summary: "text on screen (pick out the rows yourself):\n\(seen.prefix(12000))"))
            }
            return end(line, fail("nothing to extract from here; give path, or open the page/file first"))

        case "table":
            // Rows written out: a CSV file, a new Numbers/Excel document, or the clipboard for pasting into cells.
            guard let raw = action["rows"] as? [[Any]], !raw.isEmpty else { return fail("table needs rows: [[\"header\", …], [\"value\", …]]") }
            let rows = raw.map { $0.map { v in (v as? String) ?? (v as? NSNumber)?.stringValue ?? (v is NSNull ? "" : "\(v)") } }
            let to = (action["to"] as? String ?? "csv").lowercased()
            let line = begin("Table → \(to) (\(rows.count) rows)")
            do {
                let summary = try await Tables.save(rows, to: to, path: action["path"] as? String, title: action["title"] as? String,
                                                    append: action["append"] as? Bool ?? false)
                if to == "numbers" || to == "excel" {
                    try? await Task.sleep(for: .milliseconds(1200))
                    context.app = NSWorkspace.shared.frontmostApplication
                    await refresh(&context)
                }
                return end(line, .init(ok: true, summary: summary))
            } catch { return end(line, fail(error.localizedDescription)) }

        case "event", "calendar":
            let op = (action["op"] as? String ?? "create").lowercased()
            let line = begin(op == "create" || op == "add" ? "Calendar: \((action["title"] as? String ?? "event").prefix(40))" : "Calendar: \(op)")
            if op == "delete" || op == "remove", !(await confirmRisky("Delete event")) { return end(line, fail("the user said not to delete it")) }
            do { return end(line, .init(ok: true, summary: try await Events.event(action))) }
            catch { return end(line, fail(error.localizedDescription)) }

        case "reminder":
            let op = (action["op"] as? String ?? "create").lowercased()
            let line = begin(op == "create" || op == "add" ? "Reminder: \((action["title"] as? String ?? "").prefix(40))" : "Reminders: \(op)")
            do { return end(line, .init(ok: true, summary: try await Events.reminder(action))) }
            catch { return end(line, fail(error.localizedDescription)) }

        case "files":
            return await files(action)

        case "tab":
            return await tab(action, context: &context)

        case "menu":
            guard let path = action["path"] as? String, let app = context.app else { return fail("menu needs path (\"File > Export…\") and an app in front") }
            let line = begin("Menu: \(path.prefix(40))")
            if let why = staleApp(context) { return end(line, fail(why)) }
            await Launcher.bringToFront(app)
            let r = await Task.detached { AXEngine.pressMenu(path, in: app) }.value
            try? await Task.sleep(for: .milliseconds(300))
            await refresh(&context)
            return end(line, r.ok ? .init(ok: true, summary: r.note) : fail(r.note))

        case "window":
            guard let app = context.app else { return fail("no app") }
            let op = (action["op"] as? String ?? "").lowercased()
            let num = { (k: String) in (action[k] as? NSNumber)?.doubleValue }
            let what: AXEngine.WindowAction
            switch op {
            case "move":
                guard let x = num("x"), let y = num("y") else { return fail("window move needs x and y (screen points)") }
                what = .move(CGPoint(x: x, y: y))
            case "resize":
                guard let w = num("w") ?? num("width"), let h = num("h") ?? num("height") else { return fail("window resize needs w and h") }
                what = .resize(CGSize(width: w, height: h))
            case "minimize": what = .minimize
            case "restore": what = .restore
            case "fullscreen": what = .fullscreen(action["on"] as? Bool ?? true)
            case "close": what = .close
            case "raise": what = .raise
            default: return fail("window op: move, resize, minimize, restore, fullscreen, close or raise")
            }
            let line = begin("Window: \(op)")
            if let why = staleApp(context) { return end(line, fail(why)) }
            let title = action["title"] as? String
            let r = await Task.detached { AXEngine.window(what, in: app, titled: title) }.value
            await refresh(&context)
            return end(line, r.ok ? .init(ok: true, summary: r.note) : fail(r.note))

        case "schedule":
            guard let task = action["request"] as? String, !task.isEmpty, let when = action["when"] as? String else {
                return fail("schedule needs request and when")
            }
            let line = begin("Schedule: \(task.prefix(40))")
            guard let summary = Scheduler.add(request: task, phrase: when) else {
                return end(line, fail("couldn't read \(when.debugDescription) as a time; say it like \"at 9am\", \"tomorrow 8:30\", "
                                      + "\"in 20 minutes\", \"every weekday at 9\" or \"every hour\""))
            }
            return end(line, .init(ok: true, summary: summary + " (Clinqy runs it then, if the Mac is awake)"))

        case "remember_answer":
            guard let q = action["question"] as? String, let a = action["answer"] as? String, !q.isEmpty, !a.isEmpty else {
                return fail("remember_answer needs question and answer")
            }
            if !isTest || saveInTests { Profile.remember(question: q, answer: a) }
            steps.append(Step(text: "Saved answer: \(q.prefix(40))", state: .info))
            return .init(ok: true, summary: "saved for future forms")

        default:
            return fail("unknown action \(kind.debugDescription)")
        }
    }

    /// Why acting on the app the model saw would be wrong now: it quit, or its pid belongs to a new process.
    private func staleApp(_ context: ActionContext) -> String? {
        guard let id = context.identity, !AXEngine.isSameProcess(id) else { return nil }
        return "\(context.app?.cleanName ?? "the app") quit or restarted since the last look; look again"
    }

    /// Marks where a click is about to land on the latest screenshot (runs/<run>/step<N>.jpg), for chasing misclicks.
    private func traceClick(_ point: CGPoint, in app: NSRunningApplication?) {
        guard !isTest, !runDry, let app else { return }
        clickCount += 1
        let (n, id) = (clickCount, runID)
        Task { await Screenshot.saveClickTrace(app: app, point: point, step: n, runID: id) }
    }

    /// Undo for a step that navigated: close the tab it opened, else go back in the tab.
    private func registerNavigationUndo(_ line: Int, label: String, closing tab: Int?, app: NSRunningApplication?) {
        guard !runDry, line < steps.count else { return }
        StepUndo.shared.register(step: steps[line].id, kind: .navigation, label: label) {
            let bridge = BrowserBridge.shared
            if let tab { return (try? await bridge.closeTab(tab, in: app)) != nil }
            guard let current = await bridge.activeTab(in: app) else { return false }
            return await bridge.tabCommand("goBack", on: current, ["tabId": current.id]) != nil
        }
    }

    /// The app's focused element (to read, or later restore, a native field's text).
    private static func focusedElement(of app: NSRunningApplication) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// Finder jobs without Finder: Spotlight search, listing, renaming/moving (undoable), sorting a folder, trash.
    private func files(_ action: [String: Any]) async -> ActionResult {
        let op = (action["op"] as? String ?? "find").lowercased()
        let path = { (s: String) in URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        let list = { (key: String) in ((action[key] as? [String]) ?? (action[key] as? String).map { [$0] } ?? []).map(path) }
        let folder = (action["folder"] as? String).map(path)
        switch op {
        case "find", "search":
            let query = action["query"] as? String
            let line = begin("Find files\(query.map { ": \($0.prefix(30))" } ?? "")")
            let hits = await Files.find(query: query, kind: action["kind"] as? String, from: action["from"] as? String,
                                        days: (action["days"] as? NSNumber)?.intValue, folder: folder,
                                        limit: min(50, (action["limit"] as? NSNumber)?.intValue ?? 20))
            return end(line, .init(ok: true, summary: hits.isEmpty ? "no files match (try fewer words, another kind, or more days)"
                                   : "\(hits.count) files, newest first:\n" + hits.map(Files.describe).joined(separator: "\n")))

        case "list":
            guard let folder else { return fail("files list needs folder") }
            let line = begin("List \(folder.lastPathComponent)")
            do { return end(line, .init(ok: true, summary: try Files.list(folder, sort: (action["sort"] as? String ?? "date").lowercased(), limit: 60))) }
            catch { return end(line, fail(error.localizedDescription)) }

        case "rename", "move":
            var pairs: [(URL, URL)] = []
            if op == "rename" {
                for r in action["renames"] as? [[String: Any]] ?? [] {
                    guard let from = (r["from"] as? String).map(path), let to = r["to"] as? String, !to.isEmpty else { continue }
                    pairs.append((from, to.contains("/") ? path(to) : from.deletingLastPathComponent().appendingPathComponent(to)))
                }
            } else {
                guard let dest = (action["to"] as? String).map(path) else { return fail("files move needs to (a folder)") }
                pairs = list("files").map { ($0, dest.appendingPathComponent($0.lastPathComponent)) }
            }
            guard !pairs.isEmpty else { return fail(op == "rename" ? "files rename needs renames: [{\"from\": path, \"to\": new name}]" : "files move needs files") }
            let line = begin("\(op == "rename" ? "Rename" : "Move") \(pairs.count) file\(pairs.count == 1 ? "" : "s")")
            do {
                let (done, skipped) = try Files.apply(pairs)
                return end(line, .init(ok: !done.isEmpty, summary: "\(op == "rename" ? "renamed" : "moved") \(done.count): "
                    + done.prefix(30).map { "\($0.0.lastPathComponent) → \($0.1.path)" }.joined(separator: "; ")
                    + (skipped.isEmpty ? "" : ". Skipped: " + skipped.joined(separator: "; ")) + ". (files undo puts them back)"))
            } catch { return end(line, fail(error.localizedDescription)) }

        case "organize", "sort", "tidy":
            let target = folder ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let apply = action["apply"] as? Bool ?? false
            let line = begin("\(apply ? "Sort" : "Plan sorting") \(target.lastPathComponent)")
            do {
                let plan = try Files.organizePlan(target)
                guard !plan.isEmpty else { return end(line, .init(ok: true, summary: "nothing to sort in \(target.path)")) }
                let groups = Dictionary(grouping: plan) { $0.1.deletingLastPathComponent().lastPathComponent }
                    .map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
                guard apply else {
                    return end(line, .init(ok: true, summary: "plan for \(target.path) (\(plan.count) files into subfolders): \(groups). "
                                           + "Nothing moved yet — confirm with the user, then files organize with apply:true."))
                }
                let (done, skipped) = try Files.apply(plan)
                return end(line, .init(ok: true, summary: "sorted \(done.count) files in \(target.path) into \(groups)"
                                       + (skipped.isEmpty ? "" : ". Skipped: " + skipped.prefix(10).joined(separator: "; ")) + ". (files undo puts them back)"))
            } catch { return end(line, fail(error.localizedDescription)) }

        case "undo":
            let line = begin("Undo the last file changes")
            do { return end(line, .init(ok: true, summary: try Files.undo())) } catch { return end(line, fail(error.localizedDescription)) }

        case "trash", "delete":
            let urls = list("files")
            guard !urls.isEmpty else { return fail("files trash needs files") }
            let line = begin("Move \(urls.count) to Trash")
            guard await confirmRisky("Move to Trash") else { return end(line, fail("the user said not to delete them")) }
            return end(line, .init(ok: true, summary: await Files.trash(urls)))

        case "reveal", "show":
            let urls = list("files").filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return fail("files reveal needs files that exist") }
            let line = begin("Show in Finder")
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return end(line, .init(ok: true, summary: "selected \(urls.count) in a Finder window"))

        default:
            return fail("files op: find, list, rename, move, organize, undo, trash or reveal")
        }
    }

    /// Browser tabs: list them, bring one to the front, close one Clinqy opened, or read one without switching to it.
    private func tab(_ action: [String: Any], context: inout ActionContext) async -> ActionResult {
        let op = (action["op"] as? String ?? "list").lowercased()
        let id = (action["id"] as? NSNumber)?.intValue ?? (action["id"] as? String).flatMap { Int($0.filter(\.isNumber)) }
        let bridge = BrowserBridge.shared
        guard bridge.isConnected else { return fail("the browser extension isn't connected") }
        let app = context.app.flatMap { Launcher.isBrowser($0) ? $0 : nil }
        if op != "list", id == nil { return fail("tab \(op) needs id (from tab list)") }
        do {
            switch op {
            case "list":
                let tabs = try await bridge.tabs(in: app)
                return .init(ok: true, summary: tabs.isEmpty ? "no tabs" : "tabs in the front window:\n" + BrowserBridge.describe(tabs))
            case "switch":
                let line = begin("Switch tab")
                try await bridge.switchTab(id!, in: app)
                try? await Task.sleep(for: .milliseconds(400))
                await refresh(&context)
                return end(line, .init(ok: true, summary: "tab \(id!) is in front: \(context.page?.title.prefix(80) ?? "")"))
            case "close":
                let line = begin("Close tab")
                try await bridge.closeTab(id!, in: app)
                try? await Task.sleep(for: .milliseconds(300))
                await refresh(&context)
                return end(line, .init(ok: true, summary: "closed tab \(id!)"))
            case "look", "read":
                let line = begin("Read another tab")
                guard let page = await bridge.snapshot(tab: id!, in: app) else { return end(line, fail("couldn't read tab \(id!)")) }
                return end(line, .init(ok: true, summary: "tab \(id!) (read only — switch to it to act on it): \(page.title)\nURL: \(page.url)\n"
                                       + Observation.pageList(page) + (page.text.isEmpty ? "" : "\nText on screen: \(page.text.prefix(4000))")))
            default:
                return fail("tab op: list, switch, close or look")
            }
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// Waits until `text` shows (or, with gone, stops showing) in the page's text, the window's elements or title,
    /// polling cheaply; text recognition on the screen is the last resort, every few polls. "Gone" must hold on two
    /// checks at least half a second apart: pages re-render, and a spinner that blinks out for a frame isn't done.
    private func waitFor(_ text: String, gone: Bool, seconds: Double, context: inout ActionContext) async -> ActionResult {
        let want = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty, let app = context.app else { return fail("wait needs for:\"<text>\" and an app in front") }
        let line = begin(gone ? "Wait for “\(text.prefix(30))” to go" : "Wait for “\(text.prefix(30))”")
        let started = Date()
        if context.page == nil {
            return end(line, await watchFor(text, gone: gone, seconds: seconds, app: app, context: &context))
        }
        // A long wait is progress, not a stuck step (a slow final text recognition included).
        let beat = Task { [weak self] in
            while !Task.isCancelled {
                self?.lastProgress = Date()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { beat.cancel() }
        // The page itself wakes us the moment the text shows (or goes): no ¼-second polling. Text in embedded frames,
        // the window's own controls and pictures of text aren't seen there, so a miss still gets the checks below
        // (quickly: the time is spent). An extension without waitText just falls through to them.
        if let page = context.page,
           let r = try? await BrowserBridge.shared.perform("waitText", on: page, ["text": text, "gone": gone, "ms": Int(seconds * 1000)],
                                                           timeout: seconds + 3),
           r["met"] as? Bool == true {
            await refresh(&context)
            let took = String(format: "%.1f", Date().timeIntervalSince(started))
            return end(line, .init(ok: true, summary: "\(text.debugDescription) \(gone ? "is gone" : "shows") (after \(took) s)"))
        }
        var goneSince: Date?
        while true {
            guard !Task.isCancelled else { return end(line, fail("cancelled")) }
            // The page's own text is enough while polling; text recognition on a whole browser window takes
            // seconds, so it's only the last word (at the timeout, or to confirm a "gone").
            let useOCR = Date().timeIntervalSince(started) >= seconds
            let seen = await Self.shows(want, app: app, page: context.page, ocr: useOCR)
            if gone {
                if seen { goneSince = nil }
                else if let since = goneSince, Date().timeIntervalSince(since) >= 0.5 {
                    // Settled: one last look with text recognition, which also sees pictures of text.
                    if !(await Self.shows(want, app: app, page: context.page, ocr: true)) { break }
                    goneSince = nil
                } else if goneSince == nil { goneSince = Date() }
            } else if seen { break }
            if Date().timeIntervalSince(started) >= seconds, goneSince == nil {   // (a pending "gone" gets its re-check)
                await refresh(&context)
                // Most misses are the wording ("Application sent" for "Application submitted"): show what's closest.
                var near = ""
                if !gone, let page = context.page, let r = try? await BrowserBridge.shared.perform("read", on: page) {
                    let close = Self.closest(to: text, in: (r["title"] as? String ?? "") + "\n" + (r["text"] as? String ?? ""))
                    if !close.isEmpty { near = "; closest on the page: " + close.map { "“\($0)”" }.joined(separator: ", ") }
                }
                return end(line, fail("after \(Int(seconds)) s \(text.debugDescription) \(gone ? "still shows" : "hasn't appeared")\(near); look at what's there instead"))
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await refresh(&context)
        let took = String(format: "%.1f", Date().timeIntervalSince(started))
        return end(line, .init(ok: true, summary: "\(text.debugDescription) \(gone ? "is gone" : "shows") (after \(took) s)"))
    }

    /// Up to three lines of `text` sharing the most words with `want` (at least a third of them), for a wait that missed.
    nonisolated static func closest(to want: String, in text: String) -> [String] {
        let words = { (s: String) in Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }) }
        let target = words(want)
        guard !target.isEmpty else { return [] }
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "·" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 && $0.count <= 160 }
        var seen = Set<String>()
        return lines.compactMap { line -> (String, Double)? in
            let share = Double(words(line).intersection(target).count) / Double(target.count)
            return share >= 0.34 ? (line, share) : nil
        }.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0.lowercased()).inserted }.prefix(3).map { String($0.prefix(80)) }
    }

    /// waitFor outside a web page: the app's own Accessibility notifications wake the check (Watch), so nothing is
    /// re-read on a timer. A "gone" must still hold half a second later; text recognition is the last word either way.
    private func watchFor(_ text: String, gone: Bool, seconds: Double, app: NSRunningApplication,
                          context: inout ActionContext) async -> ActionResult {
        let started = Date()
        // Watch can sit quietly for the whole timeout: that's waiting, not a stuck step.
        let beat = Task { [weak self] in
            while !Task.isCancelled {
                self?.lastProgress = Date()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { beat.cancel() }
        var met = false
        while !Task.isCancelled {
            let left = seconds - Date().timeIntervalSince(started)
            guard left > 0 else { break }
            guard await Watch.until(app: app, text: text, gone: gone, timeout: left) else { break }
            if !gone { met = true; break }
            try? await Task.sleep(for: .milliseconds(500))
            if !Watch.contains(pid: app.processIdentifier, text.lowercased()) { met = true; break }
        }
        if Task.isCancelled { return fail("cancelled") }
        // Pictures of text (and apps that don't publish their text) only show to text recognition.
        let onScreen = { (await Reader.ocr(app))?.lowercased().contains(text.lowercased()) ?? false }
        if !met, !gone { met = await onScreen() } else if met, gone, await onScreen() { met = false }
        await refresh(&context)
        guard met else {
            return fail("after \(Int(seconds)) s \(text.debugDescription) \(gone ? "still shows" : "hasn't appeared"); look at what's there instead")
        }
        return .init(ok: true, summary: "\(text.debugDescription) \(gone ? "is gone" : "shows") (after \(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
    }

    /// Whether the text shows in the page (title, listed elements, text) or the app's window, or — with ocr — on screen.
    private static func shows(_ want: String, app: NSRunningApplication, page: BrowserBridge.Page?, ocr: Bool) async -> Bool {
        if let page, let r = try? await BrowserBridge.shared.perform("read", on: page),
           ((r["title"] as? String ?? "") + "\n" + (r["text"] as? String ?? "")).lowercased().contains(want) { return true }
        let scan = await AXEngine.scan(app)
        if scan.window.lowercased().contains(want) || scan.focused.lowercased().contains(want)
            || scan.elements.contains(where: { $0.label.lowercased().contains(want) }) { return true }
        return ocr ? (await Reader.ocr(app))?.lowercased().contains(want) ?? false : false
    }

    /// What a failed shell step's error means and what to do instead (the raw zsh/cp messages led to retries).
    static func shellHint(_ output: String) -> String {
        if output.contains("/Library/Containers/") || output.contains("/Library/Group Containers/"),
           output.contains("Operation not permitted") || output.contains("Permission denied") {
            return "\n→ That file is inside another app's sandbox (~/Library/Containers), which can't be read or copied by path. "
                + "Open it in its app and read with no path (in Preview, read copies all its text), or have the app save/export a copy "
                + "to ~/Downloads and use that."
        }
        if output.contains("no matches found") || (output.contains("No such file or directory") && output.contains("*")) {
            return "\n→ The pattern matched no files. Check the folder exists and what's in it (ls -la \"<folder>\"), or search with "
                + "files find (name words + kind) instead of guessing a folder."
        }
        if output.contains("No such file or directory") {
            return "\n→ Check the path: quote paths with spaces (\"~/Downloads/resume stuff/a.pdf\" won't expand ~ inside quotes — "
                + "use \"$HOME/Downloads/resume stuff/a.pdf\"), and ls the folder or use files find to get the exact name."
        }
        return ""
    }

    /// Dry run: instead of acting, mark the target and say what would happen. nil = this action is safe to really do
    /// (opening, scrolling, reading, asking, anything that only looks).
    private func rehearse(_ kind: String, _ action: [String: Any], context: inout ActionContext) async -> ActionResult? {
        let lookOnly: Set<String> = ["open_app", "open_url", "scroll", "look", "read", "wait", "recall", "dictionary", "ask", "show",
                                     "point", "mark", "review", "assert", "extract"]
        let readOps: [String: Set<String>] = ["event": ["list", "find", "search", "free", "busy"], "calendar": ["list", "find", "search", "free", "busy"],
                                              "reminder": ["list"], "files": ["find", "search", "list", "reveal", "show"],
                                              "application": ["find", "check", "list", "show"], "pdf": ["info"], "media": ["info"],
                                              "tab": ["list", "look", "read"]]
        let op = (action["op"] as? String ?? "").lowercased()
        if lookOnly.contains(kind) || readOps[kind]?.contains(op) == true { return nil }
        if kind == "files", op == "organize" || op == "sort" || op == "tidy", action["apply"] as? Bool != true { return nil }   // only plans

        let text = (action["text"] as? String).map { "“\($0.prefix(40))”" } ?? ""
        var what: String
        switch kind {
        case "click": what = "click"
        case "type": what = "type \(text)"
        case "choose": what = "choose “\((action["option"] as? String ?? "").prefix(40))”"
        case "upload": what = "upload \(((action["file"] as? String) ?? "").split(separator: "/").last ?? "a file")"
        case "key": what = "press \(action["keys"] as? String ?? "?")"
        case "email": what = "email \((action["to"] as? [String] ?? []).joined(separator: ", "))"
        case "event", "calendar": what = "add “\(action["title"] as? String ?? "")” to the calendar at \(action["start"] as? String ?? "?")"
        case "reminder": what = "\(op.isEmpty ? "add" : op) reminder “\(action["title"] as? String ?? "")”"
        case "table": what = "write \((action["rows"] as? [Any])?.count ?? 0) rows to \(action["to"] as? String ?? "csv")"
        case "applescript", "shell": what = "run a \(kind == "shell" ? "command" : "script")"
        default: what = "\(kind)\(op.isEmpty ? "" : " \(op)")"
        }
        var rect: CGRect?
        var name: String?
        if action["id"] != nil {
            if Self.isWebRef(action["id"]), let (el, r) = webTarget(action["id"], context) { rect = r; name = el.text }
            else if !Self.isWebRef(action["id"]), let el = await resolve(action["id"], context: &context) { rect = el.frame; name = el.shortLabel }
            else { return fail("element \(action["id"] ?? "?") isn't on screen") }
        } else if kind == "click", let x = (action["x"] as? NSNumber)?.doubleValue, let y = (action["y"] as? NSNumber)?.doubleValue,
                  let p = Screenshot.screenPoint(x: x, y: y) {
            rect = CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36)
        } else if kind == "click", let shown = action["text"] as? String {
            name = shown
        }
        let target = name.map { " · \($0.prefix(30))" } ?? ""
        let line = begin("Would \(what)\(target)")
        if let rect {
            await buddy.mark(rect, label: String(("would " + what).prefix(24)))
            try? await Task.sleep(for: .milliseconds(700))   // long enough to see each one
        } else {
            buddy.bubble("would \(what)", for: 2)
            try? await Task.sleep(for: .milliseconds(500))
        }
        hand.lingerBeforeHome = 3.5
        return end(line, .init(ok: true, summary: "DRY RUN — not done: would \(what)\(target). The screen didn't change; plan the next step as if it had worked."))
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

    /// `webTarget`, checked against the live page first: when the page re-rendered the element past what the extension
    /// can re-find, the page is listed again and the same element used (by identity, else the same role with a
    /// similar name, nearest to where it was). nil = it's really gone.
    private func liveWebTarget(_ ref: Any?, _ context: inout ActionContext) async -> (BrowserBridge.PageElement, CGRect)? {
        guard let (el, rect) = webTarget(ref, context), let page = context.page else { return nil }
        // Couldn't ask (an older extension, a busy page): carry on as before.
        guard (try? await BrowserBridge.shared.perform("alive", on: page, ["index": el.index]))?["ok"] as? Bool == false else { return (el, rect) }
        await relist(&context)
        guard let now = context.page else { return nil }
        let far = { (e: BrowserBridge.PageElement) in hypot(e.rect.midX - el.rect.midX, e.rect.midY - el.rect.midY) }
        let index = Self.rematch(el.index, from: page, to: now)
            ?? now.elements.filter { $0.role == el.role && AXEngine.similar($0.text, el.text) }.min { far($0) < far($1) }?.index
        guard let index, let found = webTarget("w\(index)", context) else {
            log("    w\(el.index) (\(el.role) \(el.text.prefix(40).debugDescription)) is gone and nothing like it is listed now")
            return nil
        }
        log("    w\(el.index) was re-rendered: acting on w\(index) (\(found.0.role) \(found.0.text.prefix(40).debugDescription))")
        return found
    }

    /// Picks a dropdown's option with the keyboard, as a person would when the list can't be clicked: focus it, then
    /// arrow down through the choices until the highlighted one matches, and press Return. The choice's text, or nil
    /// (the dropdown doesn't follow the arrow keys, or the end of the list came first).
    private func chooseWithKeys(_ want: String, el: BrowserBridge.PageElement, page: BrowserBridge.Page) async -> String? {
        guard (try? await BrowserBridge.shared.perform("focusFor", on: page, ["index": el.index]))?["focused"] as? Bool == true else { return nil }
        var last = "", repeats = 0
        for k in 0..<60 {
            hand.press("down")
            try? await Task.sleep(for: .milliseconds(70))
            guard let r = try? await BrowserBridge.shared.perform("activeOption", on: page, ["index": el.index, "want": want]) else { return nil }
            let text = r["text"] as? String ?? ""
            if text.isEmpty { if k >= 2 { return nil }; continue }   // nothing highlights: not a keyboard list
            if ((r["score"] as? NSNumber)?.doubleValue ?? 0) >= 0.5 {
                hand.press("return")
                return text
            }
            repeats = text == last ? repeats + 1 : 0
            if repeats >= 2 { return nil }   // the bottom of the list
            last = text
        }
        return nil
    }

    /// The last way to upload: click the site's button for real, and when the Mac's Open panel comes up, go to the
    /// file with cmd+shift+g like a person would. nil = no panel opened.
    private func uploadThroughPicker(_ file: URL, at point: CGPoint, app: NSRunningApplication) async -> ActionResult? {
        guard await hand.click(at: point, pid: app.processIdentifier) == nil else { return nil }
        let panelUp = { Self.dialogInFront(app) || (Self.systemFocus().map { $0.pid != app.processIdentifier } ?? false) }
        var up = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            if panelUp() { up = true; break }
        }
        guard up else { return nil }
        log("    upload: through the Mac file picker")
        try? await Task.sleep(for: .milliseconds(300))
        hand.press("cmd+shift+g")
        try? await Task.sleep(for: .milliseconds(600))
        AXEngine.paste(file.path)
        try? await Task.sleep(for: .milliseconds(300))
        hand.press("return")   // go to the file
        try? await Task.sleep(for: .milliseconds(900))
        hand.press("return")   // open it
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(200))
            if !panelUp() {
                try? await Task.sleep(for: .milliseconds(600))
                return .init(ok: true, summary: "chose \(file.lastPathComponent) in the Mac file picker the site opened (check the page shows it)")
            }
        }
        return .init(ok: false, summary: "FAILED: the Mac file picker is still open after going to \(file.path); look at it (the file may be greyed out "
                     + "because the site doesn't accept that type)")
    }

    private func goneMessage(_ ref: Any?) -> String {
        "page element \(ref ?? "?") isn't on the page any more and nothing like it is listed now (the page changed); look again"
    }

    private func refresh(_ context: inout ActionContext) async {
        guard let app = context.app else { return }
        let scan = await AXEngine.scan(app)
        context.elements = scan.elements
        context.fingerprint = scan.fingerprint
        context.identity = AXEngine.identity(of: app)
        // Keep the web page current too, so page actions in the same turn see what's actually there.
        if Launcher.isBrowser(app), BrowserBridge.shared.isConnected, let page = await BrowserBridge.shared.snapshot(for: app) {
            adopt(page, into: &context)
            context.webArea = await Task.detached { AXEngine.webAreaFrame(of: app) }.value ?? page.estimatedArea
        } else {
            context.page = nil
        }
    }

    /// Lists the page again mid-turn (cheaper than a full refresh: no Accessibility scan).
    private func relist(_ context: inout ActionContext) async {
        guard let app = context.app, let old = context.page, let page = await BrowserBridge.shared.snapshot(for: app) else { return }
        if Self.signatures(old) != Self.signatures(page) {
            log("    page re-listed: \(old.elements.count) → \(page.elements.count) elements")
        }
        adopt(page, into: &context)
    }

    /// A new listing replaces the extension's index list, so the fields typed this turn move to their new indices.
    private func adopt(_ page: BrowserBridge.Page, into context: inout ActionContext) {
        if let old = context.page {
            context.typedFields = context.typedFields.compactMap { index, text in Self.rematch(index, from: old, to: page).map { ($0, text) } }
        }
        context.page = page
    }

    static func webIndex(_ ref: Any?) -> Int? {
        guard let ref = ref as? String, isWebRef(ref) else { return nil }
        return Int(ref.dropFirst())
    }

    /// What identifies a page element across listings: the extension's key (role, name, question, frame — the same
    /// thing its stable ids follow), else role, name and question. Never its value.
    static func signature(_ el: BrowserBridge.PageElement) -> String {
        if !el.key.isEmpty { return el.key }
        var q = ""
        if el.extra.hasPrefix("in “"), let close = el.extra.range(of: "”") { q = String(el.extra[..<close.upperBound]) }
        return "\(el.role)|\(el.text)|\(q)"
    }

    static func signatures(_ page: BrowserBridge.Page) -> [String] { page.elements.map(signature) }

    /// The index in `now` of the element listed as `index` in `seen`: the same index if it's still the same element
    /// (the usual case: the extension keeps ids stable), else the nearest one with the same identity (nil = it's gone;
    /// the batch then stops before the step instead of the extension failing it as "isn't on the page now").
    static func rematch(_ index: Int, from seen: BrowserBridge.Page, to now: BrowserBridge.Page) -> Int? {
        guard let old = seen.elements.first(where: { $0.index == index }) else { return nil }
        let want = signature(old)
        if let same = now.elements.first(where: { $0.index == index }), signature(same) == want { return index }
        let far = { (e: BrowserBridge.PageElement) in hypot(e.rect.midX - old.rect.midX, e.rect.midY - old.rect.midY) }
        return now.elements.filter { signature($0) == want }.min { far($0) < far($1) }?.index
    }

    /// Whether the page list alone shows what the model needs after these actions (a trailing look adds nothing):
    /// the browser is still in front with a readable page, and every step so far stayed inside the page.
    private static func pageListSuffices(_ context: ActionContext, after prior: ArraySlice<[String: Any]>) -> Bool {
        guard let page = context.page, page.problem == nil, page.elements.count >= 6,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == context.app?.processIdentifier else { return false }
        let inPage: Set<String> = ["scroll", "wait", "review", "read", "extract", "recall", "remember", "show", "application", "autofill"]
        return prior.allSatisfy { isWebRef($0["id"]) || inPage.contains(($0["do"] as? String ?? "").lowercased()) }
    }

    /// The screen as changes since `before` (what the model was shown last turn), or nil when it has to be listed in
    /// full: another app or window, another page or tab, ids that moved, or too much changed to read as a diff.
    static func screenText(_ obs: Observation, since before: Observation?) -> String? {
        // In a browser the window title is the page's, so the page diff alone decides (it refuses another tab or address).
        guard let before, let app = obs.app, before.app?.processIdentifier == app.processIdentifier,
              before.window == obs.window || (obs.page != nil && before.page != nil),
              before.dialog?.title == obs.dialog?.title else { return nil }
        if let page = obs.page {
            guard let prev = before.page, let diff = BrowserBridge.diff(previous: prev, current: page) else { return nil }
            return obs.render(pageDiff: diff)
        }
        guard before.page == nil, let diff = ScreenDiff.listingUpdate(from: before.elements, to: obs.elements) else { return nil }
        return obs.render(elementsDiff: diff)
    }

    /// Looks an element up by id; if the screen changed since it was listed, finds the same role+label again.
    private func resolve(_ ref: Any?, context: inout ActionContext) async -> UIElementInfo? {
        guard let app = context.app, let ref = ref as? String,
              let wanted = AXEngine.lookup(ref, in: context.elements) else { return nil }
        lastTarget = .init(kind: "ax", role: wanted.role, label: wanted.label)
        if await AXEngine.fingerprintAsync(of: app) == context.fingerprint { return wanted }
        // The screen moved on. The same element is usually still alive (maybe shifted); else find its twin.
        if let frame = AXEngine.liveFrame(of: wanted.element), frame.width > 2, frame.height > 2 {
            return UIElementInfo(id: wanted.id, role: wanted.role, label: wanted.label, frame: frame, element: wanted.element,
                                 ref: wanted.ref, value: wanted.value, inDialog: wanted.inDialog)
        }
        await refresh(&context)
        if let twin = AXEngine.twin(of: wanted, in: context.elements) { return twin }
        let near = { (e: UIElementInfo) in hypot(e.frame.midX - wanted.frame.midX, e.frame.midY - wanted.frame.midY) }
        return context.elements.first { $0.role == wanted.role && $0.label == wanted.label }
            ?? context.elements.first { $0.label == wanted.label }
            ?? context.elements.filter { $0.role == wanted.role && near($0) < 40 }.min { near($0) < near($1) }
    }

    /// `type` with no id while no page text box has the caret: the keys belong to something the page can't see.
    /// A native text field (a sheet, the address bar, the file picker's "Go to folder" box, which lives in a helper
    /// process) takes them through the system and is checked through Accessibility; a focused page control that
    /// isn't a text box (a listbox, a date part, an editor surface) or a dialog in front takes plain keystrokes, as a
    /// person's typing would. With nothing focused at all it fails, rather than set off the page's key shortcuts.
    private func typeOutsidePage(_ text: String, submit: Bool, app: NSRunningApplication, pageFocused: Bool,
                                 context: inout ActionContext) async -> ActionResult {
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        // A sheet opened by the step before (cmd+shift+g) takes a moment to take focus.
        var focus = Self.systemFocus()
        for _ in 0..<8 where !(focus.map { textRoles.contains($0.role) } ?? false) {
            try? await Task.sleep(for: .milliseconds(80))
            focus = Self.systemFocus()
        }
        let pressed = submit ? " and pressed Return" : ""
        let send = { [hand] (pid: pid_t?) async in
            AXEngine.targetPid = pid
            if text.count > 80 { AXEngine.paste(text) } else { await hand.enterText(text) }
            if submit {
                try? await Task.sleep(for: .milliseconds(120))
                AXEngine.pressReturn()
                try? await Task.sleep(for: .milliseconds(500))
            }
            AXEngine.targetPid = nil
        }
        defer { buddy.setTyping(false) }
        if let f = focus, textRoles.contains(f.role) {
            // Keys for a helper process's panel go through the system stream; the browser's own fields get them directly.
            let own = f.pid == app.processIdentifier
            buddy.setTyping(true)
            if !(Self.axValue(f.element) ?? "").isEmpty {
                AXEngine.targetPid = own ? app.processIdentifier : nil
                AXEngine.selectAll()
                AXEngine.targetPid = nil
                try? await Task.sleep(for: .milliseconds(60))
            }
            await send(own ? app.processIdentifier : nil)
            // Keys that went astray: set the field's value directly (native fields accept that).
            if !submit, let now = Self.axValue(f.element), !AXEngine.similar(now, text) {
                AXUIElementSetAttributeValue(f.element, kAXValueAttribute as CFString, text as CFString)
            }
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            return .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into the focused \(f.role.dropFirst(2)) "
                         + "(\(own ? "outside the page" : "a system dialog"))\(pressed)")
        }
        // A page control that isn't a text box has focus: type-ahead keys are what it takes.
        if pageFocused, let page = await BrowserBridge.shared.snapshot(for: app),
           let el = page.elements.first(where: { $0.extra.range(of: #"(^| )focused( |$)"#, options: .regularExpression) != nil }) {
            adopt(page, into: &context)
            buddy.setTyping(true)
            await send(app.processIdentifier)
            return .init(ok: true, summary: "sent the keys \(text.prefix(60).debugDescription) to the focused \(el.role) \(el.text.prefix(40).debugDescription) "
                         + "(not a text box, so the result isn't checked)\(pressed)")
        }
        // The page lost focus to a dialog or sheet with no text field focused (a file picker's list): typing is what a
        // person would do there ("/" or "~" opens its Go-to-folder box; letters jump to a file).
        if !pageFocused, Self.dialogInFront(app) || (focus.map { $0.pid != app.processIdentifier } ?? false) {
            buddy.setTyping(true)
            await send(nil)
            context.fingerprint = await AXEngine.fingerprintAsync(of: app)
            return .init(ok: true, summary: "typed \(text.prefix(60).debugDescription) into the dialog in front (no text field in it had focus; "
                         + "check it took)\(pressed)")
        }
        return fail("nothing here can take the text: no text box on the page or in a dialog has focus. Type with the field's id, "
                    + "or click the field first (look if it isn't listed)")
    }

    /// The element with keyboard focus anywhere on the Mac (it can belong to a helper process, like the file picker,
    /// which neither the page nor the browser's own tree shows). Never Clinqy's own windows.
    private static func systemFocus() -> (element: AXUIElement, role: String, pid: pid_t)? {
        let system = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = ref as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return (element, role as? String ?? "", pid)
    }

    private static func axValue(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Whether the app's front window is a dialog, or has a sheet over it (Open/Save panels, alerts).
    private static func dialogInFront(_ app: NSRunningApplication) -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        func get(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
            var ref: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success ? ref : nil
        }
        guard let w = get(root, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else { return false }
        let window = w as! AXUIElement
        if ["AXDialog", "AXSystemDialog", "AXFloatingWindow"].contains(get(window, kAXSubroleAttribute) as? String ?? "") { return true }
        let children = get(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.contains { get($0, kAXRoleAttribute) as? String == "AXSheet" }
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
        hand.keepFrontApp = openedLast || Self.keepsFrontApp(request)
        hand.endRun()
        Replay.Recorder.shared.end(ok: ok)
        if !isTest { recordStats(ok: ok, answer: text) }
        if !isTest {
            // A run that worked becomes a hint for similar requests from the same place; one that was offered a hint
            // and failed counts against it.
            if ok, !runDry, !trace.isEmpty, !request.hasPrefix("Workflow:"), !request.hasPrefix("Correction for") {
                ReplayCache.shared.record(request: request, trace: trace, app: startPlace.app ?? targetApp?.cleanName,
                                          url: startPlace.url, title: startPlace.title, redact: secrets)
            } else {
                ReplayCache.shared.outcome(ok: ok)
            }
        }
        if !isTest { History.shared.add(.init(date: started, request: runDry ? "Dry run: \(request)" : request, answer: text, ok: ok,
                                 steps: steps.map(\.text), app: targetApp?.cleanName, result: runResult,
                                 trace: trace.isEmpty ? nil : trace, readText: readText.map { String($0.prefix(8_000)) },
                                 task: continuation.map { $0.task ?? $0.request })) }
        session = nil
        onFinish(text, ok)
        // Out of steps or stalled on one step isn't the end of the task: carry on by itself (a few times), with the
        // history as context, instead of waiting for the user to type "continue". Only Stop really stops.
        if !ok, !isTest, !runDry, qa == nil, autoContinues < 3,
           text.hasPrefix("Ran out of steps") || text.hasPrefix("I got stuck on") {
            autoContinues += 1
            log("auto-continue \(autoContinues)/3 after: \(text.prefix(60))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.isRunning else { return }
                self.submit("continue", auto: true)
            }
        }
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
    var page: BrowserBridge.Page? = nil
    var webArea: CGRect? = nil
    var window = ""
    var focused = ""
    var dialog: (kind: String, title: String)? = nil

    /// Everything, as listed on a turn that shows the whole screen.
    @MainActor var text: String { render() }

    /// The screen for the model. `elementsDiff` / `pageDiff` stand in for the element or page list when the model
    /// still has the previous one in context (changes since then, ids unchanged).
    @MainActor
    func render(elementsDiff: String? = nil, pageDiff: String? = nil) -> String {
        guard let app else { return "No app is frontmost." }
        // With the page covered by the extension, list only the browser's own controls from Accessibility.
        let controls = elements.filter { e in webArea.map { !$0.contains(CGPoint(x: e.frame.midX, y: e.frame.midY)) } ?? true }
        let list = AXEngine.listing(controls, budget: 8000)
        var text = """
        Frontmost app: \(app.cleanName ?? "?")\(Launcher.isBrowser(app) ? " (browser)" : "")\(Scripting.isScriptable(app) && !Launcher.isBrowser(app) ? " (scriptable)" : "")
        Window: \(window.isEmpty ? "(none)" : window)
        """
        if let dialog { text += "\nDialog: a \(dialog.kind) is open\(dialog.title.isEmpty ? "" : ": “\(dialog.title)”") — its controls are listed first" }
        text += "\nFocused: \(focused)\n"
        if let elementsDiff {
            text += "Element changes since your last look (e-ids unchanged; + new, - gone, ~ changed):\n\(elementsDiff.isEmpty ? "(none)" : elementsDiff)"
        } else {
            text += "\(page != nil ? "Browser controls" : "Elements"):\n\(list.isEmpty ? "(none readable — ask to look)" : list)"
        }
        if let page {
            text += "\n\nWeb page (via extension; use w-ids for anything on the page): \(page.title)\nURL: \(page.url)\n"
                + "Scroll: \(Int(page.scrollY)) of \(Int(page.scrollMax))"
            if let pageDiff {
                text += "\nPage changes since your last look (w-ids unchanged; + new, - gone, ~ changed):\n\(pageDiff.isEmpty ? "(none)" : pageDiff)"
            } else {
                text += (page.headings.isEmpty ? "" : "\nHeadings: " + page.headings.joined(separator: " | "))
                    + "\n" + Self.pageList(page)
                if !page.messages.isEmpty { text += "\nMessages on the page: " + page.messages.map { "“\($0)”" }.joined(separator: " · ") }
            }
            if page.above + page.below > 0 { text += "\nNot shown (scroll to reach): \(page.above) fields/buttons above, \(page.below) below." }
            if let panes = BrowserBridge.paneSummary(page) { text += "\nScrolled out of view \(panes)." }
            if !page.text.isEmpty { text += "\nText on screen: \(page.text)" }
            if page.ready == "loading" { text += "\n(The page is still loading.)" }
            if let problem = page.problem { text += "\n(Couldn't read the page: \(problem). Use look and click by position, or read.)" }
        } else if Launcher.isBrowser(app) {
            text += "\n(Browser extension not connected: page content comes from Accessibility only.)"
        }
        return text
    }

    /// A page's element list, as the model reads it.
    static func pageList(_ page: BrowserBridge.Page) -> String {
        let items = page.elements.map { "w\($0.index) \($0.role): \($0.text)\($0.extra.isEmpty ? "" : " [\($0.extra)]")" }
        return "Page elements (visible part):\n" + (items.isEmpty ? "(none)" : items.joined(separator: "\n"))
    }

    /// Reads the frontmost app's UI off the main thread, so the buddy never stutters while we look.
    @MainActor
    static func capture(_ preferred: NSRunningApplication?) async -> Observation {
        let front = NSWorkspace.shared.frontmostApplication
        let app = (front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front) ?? preferred
        guard let app else { return Observation(app: nil, elements: [], fingerprint: 0) }
        // The Accessibility scan, the page listing and the page's frame don't depend on each other: all at once
        // (in a browser that's the slowest two overlapping instead of adding up).
        async let scanning = AXEngine.scan(app)

        // In a browser with the extension: the real page, element by element.
        var page: BrowserBridge.Page?
        var webArea: CGRect?
        if Launcher.isBrowser(app), BrowserBridge.shared.isConnected {
            async let area = Task.detached(priority: .userInitiated) { AXEngine.webAreaFrame(of: app) }.value
            page = await BrowserBridge.shared.snapshot(for: app)
            // Still arriving (or nothing listed yet on a page that isn't blocked): give it a moment, once.
            if let p = page, p.ready == "loading" || (p.elements.isEmpty && p.problem == nil) {
                try? await Task.sleep(for: .milliseconds(700))
                page = await BrowserBridge.shared.snapshot(for: app) ?? page
            }
            if page != nil { webArea = await area ?? page?.estimatedArea }
            if webArea == nil { page = nil }
        }
        let scan = await scanning
        return Observation(app: app, elements: scan.elements, fingerprint: scan.fingerprint, page: page, webArea: webArea,
                           window: scan.window, focused: scan.focused, dialog: scan.dialog)
    }
}

extension AXEngine {
    struct Scan: @unchecked Sendable {
        let elements: [UIElementInfo]
        let fingerprint: Int
        let window: String
        let focused: String
        var dialog: (kind: String, title: String)?
    }

    static func scan(_ app: NSRunningApplication) async -> Scan {
        await Task.detached(priority: .userInitiated) {
            enableManualAccessibility(app)
            let focus = focusSummary(of: app)
            return Scan(elements: elements(of: app, limit: 150), fingerprint: fingerprint(of: app),
                        window: focus.window, focused: focus.focused, dialog: dialog(of: app))
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

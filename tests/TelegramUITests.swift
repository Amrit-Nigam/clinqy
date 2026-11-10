import Foundation

/// Pure Telegram copilot logic: escaping, card rendering per state, button layouts, callback routing, splitting,
/// edit coalescing, photo pacing, retry rules and reply routing.
@main
struct TelegramUITests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        if ok { print("PASS \(what)") } else { failures += 1; print("FAIL: \(what)") }
    }
    static func blocking(_ work: @escaping @Sendable () async -> Data?) -> Data? {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: Data?
        Task { out = await work(); done.signal() }
        done.wait()
        return out
    }
    static func texts(_ rows: [[TGButton]]) -> [[String]] { rows.map { $0.map(\.text) } }
    static func flat(_ rows: [[TGButton]]) -> [TGButton] { rows.flatMap { $0 } }

    /// Telegram's allowed HTML: any `<` not starting one of these tags is rejected by the Bot API.
    static func invalidHTML(_ html: String) -> String? {
        let allowed = ["b", "strong", "i", "em", "u", "ins", "s", "strike", "del", "a", "code", "pre", "span", "tg-spoiler", "blockquote"]
        let chars = Array(html)
        var i = 0
        while i < chars.count {
            if chars[i] == "<" {
                guard let end = chars[i...].firstIndex(of: ">") else { return "unterminated tag at \(i)" }
                var inner = String(chars[(i + 1)..<end])
                let closing = inner.hasPrefix("/")
                if closing { inner.removeFirst() }
                let name = inner.prefix { $0.isLetter || $0.isNumber || $0 == "-" }.lowercased()
                guard allowed.contains(name) else { return "disallowed tag <\(inner)>" }
                if name == "span", !closing, !inner.contains("class=\"tg-spoiler\"") { return "span without tg-spoiler" }
                if name == "a", !closing, !inner.hasPrefix("a href=\"") { return "a without href" }
                i = end + 1
            } else { i += 1 }
        }
        return nil
    }
    static func checkHTML(_ html: String, _ what: String) {
        if let problem = invalidHTML(html) { failures += 1; print("FAIL: \(what) — \(problem): \(html.prefix(200))") }
    }

    static func main() {
        setbuf(stdout, nil)
        // Escaping.
        check(TelegramHTML.escape("a < b && c > \"d\"") == "a &lt; b &amp;&amp; c &gt; &quot;d&quot;", "HTML escapes < > & and quotes")
        check(TelegramHTML.escape("<b>x</b>") == "&lt;b&gt;x&lt;/b&gt;", "user text can't inject tags")
        check(TelegramHTML.escape("👩🏽‍💻 → “ok”") == "👩🏽‍💻 → “ok”", "Unicode passes through untouched")
        check(TelegramHTML.bold("1 < 2") == "<b>1 &lt; 2</b>", "bold escapes its content")
        check(TelegramHTML.link("https://example.com/?a=1&b=2", "x") == "<a href=\"https://example.com/?a=1&amp;b=2\">x</a>", "link escapes its href")
        check(TelegramHTML.link("javascript:alert(1)", "x") == "x" && TelegramHTML.link("file:///etc/passwd") == "file:///etc/passwd", "only http(s) becomes a link")

        // Splitting.
        let emoji = String(repeating: "👩🏽‍💻", count: 1000)
        let emojiChunks = TelegramHTML.chunks(emoji, limit: 3800)
        check(emojiChunks.joined() == emoji && emojiChunks.allSatisfy { $0.utf16.count <= 3800 } && emojiChunks.count > 1, "splitting keeps grapheme clusters and the limit")
        let amps = String(repeating: "&", count: 5000)
        let ampChunks = TelegramHTML.chunks(amps, limit: 4000)
        check(ampChunks.allSatisfy { $0.utf16.count <= 4000 && !$0.hasSuffix("&amp") && $0.hasSuffix("&amp;") }, "escaped entities are never cut in half")
        check(ampChunks.joined() == TelegramHTML.escape(amps), "escaped chunks rejoin exactly")
        let lines = (0..<400).map { "Line \($0) with some text" }.joined(separator: "\n")
        let lineChunks = TelegramHTML.chunks(lines, limit: 1000)
        check(lineChunks.dropLast().allSatisfy { $0.hasSuffix("text") } && lineChunks.allSatisfy { $0.utf16.count <= 1000 }, "splitting prefers line boundaries")
        check(TelegramHTML.chunks("") == [""] && TelegramHTML.chunks("hi") == ["hi"], "short text is one chunk")

        // Titles and time.
        check(TelegramText.title("Apply to this job with my profile and also write a thoughtful cover letter mentioning my experience\nhttps://jobs.example.com/1").count <= 60, "title ≤ 60 characters")
        check(TelegramText.title("https://example.com/path") == "example.com", "link-only task titled by host")
        check(TelegramText.title("read this\n\nFiles attached by the user in Telegram (this/these/the image refer to these local files):\n- \"/tmp/a.pdf\"") == "read this", "attachment boilerplate is not the title")
        check(TelegramText.elapsed(5) == "<1m" && TelegramText.elapsed(185) == "3m" && TelegramText.elapsed(3_900) == "1h 05m", "elapsed has minute granularity")
        check(TelegramText.clip("abcdef", 4) == "abc…", "clip adds an ellipsis")

        // Card per state.
        var m = RunCardModel(shortID: "ab12cd34", title: "Fill the <signup> form", phase: .working)
        m.elapsed = 125; m.step = 4; m.action = "Typing the email & password fields"
        m.checklist = [.init(title: "Open the form", complete: true), .init(title: "Fill details", complete: true), .init(title: "Upload CV", complete: false), .init(title: "Review", complete: false)]
        let working = RunCard.render(m)
        check(working.hasPrefix("⚙️ <b>Working</b> · 2m · step 4"), "working header: emoji, phase, elapsed, step")
        check(working.contains("<b>Fill the &lt;signup&gt; form</b>") && working.contains("email &amp; password"), "card escapes the title and action")
        check(working.contains("2/4 done") && working.contains("✓ Open the form") && working.contains("… Upload CV") && working.contains("○ Review"), "checklist progress ✓/…/○")
        check(working.contains("<i>Background · #ab12cd34</i>"), "origin footer")
        check(texts(RunCard.keyboard(m)) == [["⏸ Pause", "📸 Screenshot", "⏹ Stop"]], "Working → Pause · Screenshot · Stop")

        var waiting = m; waiting.phase = .waiting; waiting.action = "Which city?"; waiting.note = "No answer in 10 min → I'll skip this step."
        waiting.options = ["Delhi", "Mumbai"]; waiting.questionKey = "q1"
        let waitingHTML = RunCard.render(waiting)
        check(waitingHTML.contains("🙋 <b>Waiting for you</b>") && waitingHTML.contains("❓ Which city?") && waitingHTML.contains("⏱ No answer in 10 min"), "waiting card shows the question and its default")
        let waitingKeys = RunCard.keyboard(waiting)
        check(texts(waitingKeys) == [["1. Delhi"], ["2. Mumbai"], ["⏭ Skip", "🖥 Open on Mac"]], "Waiting → answers first, then Skip · Open on Mac")
        check(waitingKeys[0][0].data == "a:q1:0" && waitingKeys[2][0].data == "c:ab12cd34:skip", "answer and skip callback data")

        var secret = m; secret.phase = .waitingPrivate; secret.action = "Bank password?"
        let secretHTML = RunCard.render(secret)
        check(!secretHTML.contains("Bank password") && secretHTML.contains("answer it on your Mac"), "private question text never reaches the card")
        check(texts(RunCard.keyboard(secret)) == [["🖥 Open on Mac", "⏹ Stop"]], "private wait offers only Open on Mac and Stop")

        var paused = m; paused.phase = .paused
        check(texts(RunCard.keyboard(paused)) == [["▶️ Resume", "🖐 Take over", "⏹ Stop"]], "Paused → Resume · Take over · Stop")
        check(RunCard.render(paused).contains("⏸ <b>Paused</b>"), "paused card")
        var taken = m; taken.phase = .takenOver
        check(texts(RunCard.keyboard(taken)) == [["↩️ Hand back", "🖥 Open on Mac", "⏹ Stop"]], "Taken over → Hand back")

        var done = m; done.phase = .done; done.outcome = "Submitted the form. Confirmation at https://example.com/ok"; done.link = "https://example.com/ok"
        let doneKeys = RunCard.keyboard(done)
        check(texts(doneKeys) == [["📄 Result", "📸 Screenshot", "🔁 Run again"], ["🔗 Open link"]], "Done → Result · Screenshot · Run again · Open link")
        check(doneKeys[1][0].url == "https://example.com/ok" && doneKeys[1][0].json["url"] == "https://example.com/ok" && doneKeys[1][0].json["callback_data"] == nil, "Open link is a URL button")
        let doneHTML = RunCard.render(done)
        check(doneHTML.hasPrefix("✅ <b>Done</b>") && doneHTML.contains("✓ Upload CV") == false && doneHTML.contains("○ Upload CV"), "finished checklist shows no in-progress mark")
        var unconfirmed = done; unconfirmed.phase = .doneUnconfirmed; unconfirmed.link = "javascript:x"
        check(RunCard.render(unconfirmed).hasPrefix("⚠️ <b>Done — one item I couldn't confirm</b>"), "unconfirmed finish is ⚠️, not failure")
        check(texts(RunCard.keyboard(unconfirmed)) == [["📄 Result", "📸 Screenshot", "🔁 Run again"]], "no Open link for non-web links")
        var failed = done; failed.phase = .failed; failed.canRunAgain = false; failed.link = nil
        check(RunCard.render(failed).hasPrefix("❌ <b>Couldn't finish</b>") && texts(RunCard.keyboard(failed)) == [["📄 Result", "📸 Screenshot"]], "failed card; Run again hidden once used")
        var mirrored = m; mirrored.source = "Scheduled"; mirrored.background = false
        check(RunCard.render(mirrored).contains("Normal · from Scheduled · #ab12cd34"), "mirrored card says where it came from")
        var queued = m; queued.phase = .queued; queued.action = nil
        check(RunCard.render(queued).contains("Waiting for a free task slot") && texts(RunCard.keyboard(queued)) == [["📸 Screenshot", "⏹ Stop"]], "queued card")

        // Caption limit: a long card still fits 1024 and stays valid.
        var long = m
        long.checklist = (0..<40).map { .init(title: "Outcome number \($0) with a long descriptive title <x>", complete: $0 < 10) }
        long.action = String(repeating: "Doing & checking <things> ", count: 80)
        long.parts = (0..<20).map { "Child job \($0) — Working on a long page title" }
        let caption = RunCard.render(long, limit: RunCard.captionLimit)
        check(caption.utf16.count <= 1024 && caption.contains("<b>Working</b>") && !caption.contains("<x>"), "long card fits a caption without raw tags")
        check(caption.components(separatedBy: "<b>").count == caption.components(separatedBy: "</b>").count, "trimmed card keeps balanced tags")
        check(RunCard.render(long).contains("+") , "hidden items are counted")
        for phase in CardPhase.allCases {
            var any = long; any.phase = phase; any.outcome = String(repeating: "result ", count: 400)
            check(RunCard.render(any, limit: 1024).utf16.count <= 1024, "every phase fits a caption: \(phase.rawValue)")
        }
        check(CardPhase.from(ended: true, ok: true, stopped: false, unconfirmed: true, paused: false, takenOver: false, question: false, sensitive: false, running: false) == .doneUnconfirmed, "unconfirmed phase")
        check(CardPhase.from(ended: false, ok: true, stopped: false, unconfirmed: false, paused: true, takenOver: false, question: true, sensitive: false, running: true) == .paused, "a pause outranks a question")
        check(CardPhase.from(ended: true, ok: false, stopped: true, unconfirmed: false, paused: true, takenOver: false, question: false, sensitive: false, running: false) == .stopped, "finished outranks pause")

        // Question message.
        let question = QuestionMessage.render(shortID: "ab12cd34", title: "Order", text: "Cancel <the> order?", sensitive: false,
                                              note: "No answer in 10 min → I'll choose “No”.", paused: false, options: ["Yes", "No"])
        check(question.contains("Cancel &lt;the&gt; order?") && question.contains("1. Yes\n2. No") && question.contains("⏱ No answer in 10 min → I'll choose “No”."), "question shows numbered options and the default")
        check(question.contains("reply to this message"), "question explains free-text replies")
        let privateQuestion = QuestionMessage.render(shortID: "a", title: "t", text: "OTP code?", sensitive: true, note: nil, paused: false, options: [])
        check(!privateQuestion.contains("OTP") && privateQuestion.contains("on your Mac"), "private question stays on the Mac")
        check(QuestionMessage.render(shortID: "a", title: "t", text: "q", sensitive: false, note: "n", paused: true, options: []).contains("no default will be chosen"), "paused question has no default")
        let qKeys = QuestionMessage.keyboard(shortID: "ab12cd34", key: "k", options: (0..<12).map { "Option \($0)" }, sensitive: false)
        check(qKeys.count == 9 && qKeys.last.map { $0.map(\.text) } == ["⏭ Skip", "🖥 Open on Mac"], "up to 8 options then Skip · Open on Mac")
        check(flat(qKeys).allSatisfy { ($0.data ?? "").utf8.count <= 64 }, "callback data within 64 bytes")
        check(QuestionMessage.render(shortID: "a", title: "t", text: String(repeating: "long ", count: 600), sensitive: false, note: nil, paused: false, options: [], limit: 1024).utf16.count <= 1024, "question caption fits")

        // Callback data.
        check(CallbackData.parse("c:ab12cd34:pause") == .control("ab12cd34", .pause), "control callback parses")
        check(CallbackData.parse("a:k1:3") == .answer("k1", 3), "answer callback parses")
        check(CallbackData.parse("c:ab12cd34:explode") == nil && CallbackData.parse("a:k:-1") == nil && CallbackData.parse("x") == nil && CallbackData.parse("c::stop") == nil, "unknown callbacks are rejected")
        check(CallbackData.parse(String(repeating: "c", count: 70)) == nil, "oversized callback data rejected")
        for action in CardAction.allCases { check(CallbackData.parse(CallbackData.control("ab12cd34", action)) == .control("ab12cd34", action), "round trip \(action.rawValue)") }
        check(CardAction.stop.needsLiveRun && CardAction.pause.needsLiveRun && !CardAction.result.needsLiveRun && !CardAction.again.needsLiveRun, "stale controls are told the run finished")
        check(TapToast.control(.pause, changed: false, state: "Paused") == "Already paused" && TapToast.control(.pause, changed: true, state: "Paused") == "Paused", "double tap toasts are idempotent")

        // Edit coalescing.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var coalescer = EditCoalescer(minInterval: 3)
        check(coalescer.request(at: t0) == .now, "first edit goes now")
        check(coalescer.request(at: t0) == .merged, "requests while one is pending merge")
        coalescer.flushed(at: t0, sent: true)
        check(coalescer.request(at: t0.addingTimeInterval(1)) == .after(2), "next edit waits out the interval")
        check(coalescer.request(at: t0.addingTimeInterval(1.5)) == .merged, "burst merges into the scheduled edit")
        coalescer.flushed(at: t0.addingTimeInterval(3), sent: true)
        check(coalescer.request(at: t0.addingTimeInterval(10)) == .now, "after a quiet period edits go now")
        coalescer.flushed(at: t0.addingTimeInterval(10), sent: false)
        check(coalescer.lastEdit == t0.addingTimeInterval(3), "skipped (unchanged) flushes don't consume the interval")
        var burst = EditCoalescer(minInterval: 3); var sent = 0
        for i in 0..<100 {
            let now = t0.addingTimeInterval(Double(i) * 0.1)
            if burst.request(at: now) != .merged { sent += 1 }
            if i % 30 == 29 { burst.flushed(at: now, sent: true) }
        }
        check(sent <= 4, "100 updates in 10 s become at most 4 edits")

        // Card photo pacing.
        let k1 = CardPhotoPolicy.key(phase: .working, step: 3, checked: 1)
        check(CardPhotoPolicy.shouldCapture(now: t0, last: nil, lastKey: nil, key: k1), "first meaningful state is captured")
        check(!CardPhotoPolicy.shouldCapture(now: t0.addingTimeInterval(60), last: t0, lastKey: k1, key: k1), "unchanged state is never re-captured")
        let k2 = CardPhotoPolicy.key(phase: .working, step: 4, checked: 1)
        check(!CardPhotoPolicy.shouldCapture(now: t0.addingTimeInterval(5), last: t0, lastKey: k1, key: k2), "changes within 20 s wait")
        check(CardPhotoPolicy.shouldCapture(now: t0.addingTimeInterval(25), last: t0, lastKey: k1, key: k2), "a change after 20 s is captured")
        let image = Data("png".utf8)
        check(!CardPhotoPolicy.shouldUpload(image, lastDigest: CardPhotoPolicy.digest(image)) && CardPhotoPolicy.shouldUpload(Data("other".utf8), lastDigest: CardPhotoPolicy.digest(image)), "identical image isn't uploaded again")

        // Retry rules.
        check(TelegramRetry.delay(method: "sendMessage", status: 429, retryAfter: 7, attempt: 1) == 7, "429 waits retry_after")
        check(TelegramRetry.delay(method: "sendMessage", status: 429, retryAfter: 600, attempt: 1) == 60, "retry_after is capped")
        check(TelegramRetry.delay(method: "sendMessage", status: 429, retryAfter: 1, attempt: 3) == nil, "attempts are bounded")
        check(TelegramRetry.delay(method: "sendMessage", status: nil, retryAfter: nil, attempt: 1) == nil, "an unknown send outcome is never resent")
        check(TelegramRetry.delay(method: "editMessageText", status: nil, retryAfter: nil, attempt: 1) == 1 && TelegramRetry.delay(method: "editMessageText", status: 502, retryAfter: nil, attempt: 2) == 2, "idempotent edits back off on network/5xx")
        check(TelegramRetry.delay(method: "editMessageText", status: 400, retryAfter: nil, attempt: 1) == nil, "400 is not retried")
        check(TelegramRetry.isNotModified("Bad Request: message is not modified: specified new message content and reply markup are exactly the same"), "not-modified is success")
        check(TelegramRetry.isGone("Bad Request: message to edit not found") && !TelegramRetry.isGone("Bad Request: chat not found"), "deleted card detected")

        // Results.
        let answer = "Done — one item I couldn't confirm: submission. The form looked sent. Screenshot: /Users/me/Library/Clinqy/snap 1.png"
        check(ResultText.isUnconfirmed(answer) && ResultText.screenshotPath(answer) == "/Users/me/Library/Clinqy/snap 1.png", "unconfirmed answer and its screenshot path")
        check(ResultText.withoutScreenshotPath(answer).hasSuffix("looked sent.") && ResultText.screenshotPath("Done.") == nil, "local path removed from the message")
        let resultHTML = ResultText.render(phase: .doneUnconfirmed, title: "Send form", shortID: "ab12cd34", summary: answer, links: ["https://example.com/a?x=1&y=2"], limit: 1024)
        check(resultHTML.hasPrefix("⚠️ <b>Done — one item I couldn't confirm</b>") && resultHTML.contains("href=\"https://example.com/a?x=1&amp;y=2\"") && !resultHTML.contains("/Users/me"), "result message: ⚠️, link, no local path")
        check(ResultText.render(phase: .done, title: "t", shortID: "a", summary: String(repeating: "x ", count: 3000), links: [], limit: 1024).utf16.count <= 1024, "result caption fits")
        check(TelegramLinks.extract(["See https://a.com/x, and (https://b.com/y).", "https://a.com/x", nil]) == ["https://a.com/x", "https://b.com/y"], "links extracted once, without punctuation")
        check(ResultText.oneLiner("First line\nsecond") == "First line", "one-liner result")

        // Commands and quick replies.
        check(TelegramCommands.menu.allSatisfy { $0.0.range(of: #"^[a-z0-9_]{1,32}$"#, options: .regularExpression) != nil && (1...256).contains($0.1.count) }, "setMyCommands entries are valid")
        check(TelegramCommands.help.count < 900, "help is concise")
        let quick = QuickReplies.build(recent: ["check email", "/runs", "open calculator", "check email", "line\nbreak", "check email"], workflows: ["Morning report"])
        check(quick == ["Morning report", "check email", "open calculator"], "quick replies: workflows, then frequent, no commands")
        check(QuickReplies.build(recent: (0..<20).map { "task \($0)" }, workflows: []).count == 6, "quick replies are capped")

        // Steering phrases.
        check(Steering.command("Stop") == .stop && Steering.command("please stop it") == .stop && Steering.command("pause now") == .pause, "stop / pause phrases")
        check(Steering.command("continue") == .resume && Steering.command("keep going!") == .resume, "continue phrases")
        check(Steering.command("stop at the second page") == nil && Steering.command("continue with the cheaper flight") == nil, "instructions are not controls")

        // Reply routing.
        let a = UUID(), b = UUID()
        func reply(_ run: UUID, ended: Bool = false, toQuestion: Bool = false, current: Bool = true, waiting: Bool = false, mirrored: Bool = false) -> MessageRoute.ReplyFacts {
            .init(run: run, ended: ended, toQuestion: toQuestion, current: current, waiting: waiting, mirrored: mirrored)
        }
        func decide(_ text: String, forceNew: Bool = false, explicitNew: Bool = false, reply: MessageRoute.ReplyFacts? = nil, waiting: [UUID] = [],
                    selected: (id: UUID, ended: Bool, mirrored: Bool, recent: Bool)? = nil) -> MessageRoute.Decision {
            MessageRoute.decide(text: text, forceNew: forceNew, explicitNew: explicitNew, reply: reply, waitingOwned: waiting,
                                selected: selected, followUpPhrase: text.lowercased().hasPrefix("also") || text.lowercased().hasPrefix("continue"))
        }
        check(decide("use the blue one", reply: reply(a)) == .context(a), "reply to a card adds context to that run")
        check(decide("stop", reply: reply(a, mirrored: true)) == .control(a, .stop), "“stop” replied to a Mac run's card stops that run")
        check(decide("pause", reply: reply(a)) == .control(a, .pause) && decide("continue", reply: reply(a)) == .control(a, .resume), "pause / continue on the replied-to run")
        check(decide("Mumbai", reply: reply(a, toQuestion: true, waiting: true)) == .answer(a), "reply to the question answers it")
        check(decide("stop", reply: reply(a, toQuestion: true, waiting: true)) == .answer(a), "“stop” replied to a question is its answer")
        check(decide("Mumbai", reply: reply(a, waiting: true)) == .answer(a), "reply to a waiting run's card answers it")
        check(decide("stop", reply: reply(a, waiting: true)) == .control(a, .stop), "but “stop” on its card stops it")
        check(decide("Mumbai", reply: reply(a, toQuestion: true, current: false, waiting: true)) == .questionEnded, "old question replies are refused")
        check(decide("now do it for March", reply: reply(a, ended: true)) == .newTask(followUp: a), "reply to a finished card is a follow-up task")
        check(decide("yes", waiting: [a]) == .answer(a), "one waiting Telegram run gets the plain answer")
        check(decide("yes", waiting: [a, b]) == .ambiguous, "two waiting runs: ask which")
        check(decide("background: read https://x.com", explicitNew: true, waiting: [a]) == .newTask(followUp: nil), "a new task never answers a question")
        check(decide("/new also check mail", forceNew: true, waiting: [a], selected: (a, false, false, false)) == .newTask(followUp: nil), "/new always starts fresh")
        check(decide("also attach the PDF", selected: (a, false, false, false)) == .context(a), "follow-up phrase steers the selected Telegram run")
        check(decide("also attach the PDF", selected: (a, false, true, false)) == .newTask(followUp: nil), "unscoped messages never steer a run started elsewhere")
        check(decide("also send it to Bob", selected: (a, true, false, true)) == .newTask(followUp: a), "follow-up of a recent finished run carries context")
        check(decide("also send it to Bob", selected: (a, true, false, false)) == .newTask(followUp: nil), "stale runs don't leak context")
        check(decide("book a table") == .newTask(followUp: nil), "plain message starts a task")

        // Every rendered HTML string must use only Telegram-allowed tags, whatever the dynamic text contains.
        check(invalidHTML("<1m") != nil && invalidHTML("<b>x</b> &lt;1m") == nil && invalidHTML("<script>") != nil, "validator rejects stray < and accepts allowed tags")
        check(TelegramHTML.plain(RunCard.render(RunCardModel(shortID: "x", title: "a<b & \"c\"", phase: .working))).contains("a<b & \"c\""), "plain fallback decodes entities and drops tags")
        check(TelegramRetry.isParseError("Bad Request: can't parse entities: Unsupported start tag \"1m\" at byte offset 12"), "parse errors are recognised")
        let nasty = ["Plain", "a < b > c & d", "\"quoted\" <b>bold</b>", "<1m", "x</i><a href=\"javascript:1\">y", "&amp; &lt;"]
        for phase in CardPhase.allCases {
            for elapsedSeconds in [0.0, 30, 60, 3600] {
                for text in nasty {
                    var card = RunCardModel(shortID: "ab12cd34", title: text, phase: phase)
                    card.elapsed = elapsedSeconds; card.step = 3; card.action = text; card.note = text; card.outcome = text
                    card.source = text; card.options = [text, "B"]; card.questionKey = "q1"; card.link = "https://example.com/?a=1&b=2"
                    card.parts = [text]; card.partsSummary = text
                    card.checklist = [.init(title: text, complete: true), .init(title: text, complete: false)]
                    for limit in [RunCard.textLimit, RunCard.captionLimit, 120] {
                        checkHTML(RunCard.render(card, limit: limit), "card \(phase) @\(elapsedSeconds)s limit \(limit) text \(text)")
                    }
                }
            }
        }
        for text in nasty {
            for sensitive in [false, true] {
                for limit in [RunCard.textLimit, RunCard.captionLimit, 100] {
                    checkHTML(QuestionMessage.render(shortID: "ab12cd34", title: text, text: text, sensitive: sensitive, note: text, paused: false, options: [text, "<x>"], limit: limit), "question \(text)")
                    checkHTML(QuestionMessage.render(shortID: "ab12cd34", title: text, text: text, sensitive: sensitive, note: nil, paused: true, options: [], limit: limit), "question paused \(text)")
                }
            }
            for phase in CardPhase.allCases {
                for limit in [RunCard.textLimit, RunCard.captionLimit, 80] {
                    checkHTML(ResultText.render(phase: phase, title: text, shortID: "ab12cd34", summary: text, links: ["https://example.com/?a=1&b=<2>", text], extra: text, limit: limit), "result \(phase) \(text)")
                }
            }
        }

        for host in ["localhost", "app.localhost", "mac.local", "127.0.0.1", "10.1.2.3", "172.20.0.1", "192.168.1.5", "169.254.1.1", "0.0.0.0",
                     "[::1]", "::1", "fe80::1", "fd00::1", "intranet", "::ffff:127.0.0.1", "localhost."] {
            check(!TelegramLinks.isPublicHost(host), "host \(host) is not public")
        }
        for host in ["example.com", "sub.example.co.uk", "8.8.8.8", "172.32.0.1", "[2606:4700::1111]"] {
            check(TelegramLinks.isPublicHost(host), "host \(host) is public")
        }
        check(TelegramLinks.button("http://localhost:3000/x") == nil, "localhost URL gets no button")
        check(TelegramLinks.button("https://example.com/a") == "https://example.com/a", "public URL gets a button")
        var local = RunCardModel(shortID: "ab12cd34", title: "t", phase: .done); local.link = "http://localhost:3000/"
        check(!flat(RunCard.keyboard(local)).contains { $0.url != nil }, "done keyboard has no URL button for localhost")
        check(RunCard.render(local, limit: RunCard.textLimit).contains("localhost:3000"), "localhost link still shown as text")
        local.link = "https://example.com/"
        check(flat(RunCard.keyboard(local)).contains { $0.url != nil }, "done keyboard keeps URL button for public link")
        check(TelegramKeyboardFallback.shouldRetryWithoutURLButtons(status: 400, description: "Bad Request: wrong HTTP URL specified"), "400 wrong URL retries")
        check(TelegramKeyboardFallback.shouldRetryWithoutURLButtons(status: 400, description: "Bad Request: inline keyboard button URL 'x' is invalid"), "400 button URL retries")
        check(!TelegramKeyboardFallback.shouldRetryWithoutURLButtons(status: 429, description: "wrong HTTP URL"), "429 does not retry")
        check(!TelegramKeyboardFallback.shouldRetryWithoutURLButtons(status: 400, description: "chat not found"), "unrelated 400 does not retry")
        let kb = TGButton.markup([[.callback("A", "a"), .url("L", "http://x.y")], [.url("L2", "http://x.y")]])
        let stripped = TelegramKeyboardFallback.strippingURLButtons(kb)
        check((stripped?["inline_keyboard"] as? [[[String: String]]])?.map { $0.map { $0["text"] ?? "" } } == [["A"]], "stripping keeps callbacks, drops URL buttons and empty rows")
        check(TelegramKeyboardFallback.strippingURLButtons(TGButton.markup([[.callback("A", "a")]])) == nil, "no URL buttons means no retry markup")

        check(RunCardFacts.action(narration: "", stage: "Clicking chat") == "Clicking chat", "card action falls back to the record stage")
        check(RunCardFacts.action(narration: "Typing", stage: "old") == "Typing", "card action prefers live narration")
        check(RunCardFacts.action(narration: nil, stage: "  ") == nil, "blank action is nil")
        check(RunCardFacts.waitingOnRecord(state: "waiting", ended: false) && !RunCardFacts.waitingOnRecord(state: "waiting", ended: true), "record waiting flips the card to waiting")
        check(CardPhase.from(ended: false, ok: true, stopped: false, unconfirmed: false, paused: false, takenOver: false, question: RunCardFacts.waitingOnRecord(state: "waiting", ended: false), sensitive: false, running: RunCardFacts.runningOnRecord(state: "running")) == .waiting, "waiting beats working with no worker reference")
        check(CardPhase.from(ended: false, ok: true, stopped: false, unconfirmed: false, paused: false, takenOver: false, question: false, sensitive: false, running: RunCardFacts.runningOnRecord(state: "running")) == .working, "running record shows working without a worker")

        // Back-references to the task the chat just finished.
        check(FollowUpRouting.reference("Submit it") == .init(rerun: false, mode: nil), "“Submit it” refers back")
        check(FollowUpRouting.reference("yes do it") == .init(rerun: false, mode: nil), "“yes do it” refers back")
        check(FollowUpRouting.reference("do it") != nil && FollowUpRouting.reference("go ahead") != nil, "go-aheads refer back")
        check(FollowUpRouting.reference("Apply it in arc") == .init(rerun: false, mode: .browser("Arc")), "“Apply it in arc” continues in Arc")
        check(FollowUpRouting.reference("foreground") == .init(rerun: true, mode: .foreground), "a bare “foreground” re-runs in front")
        check(FollowUpRouting.reference("in arc") == .init(rerun: true, mode: .browser("Arc")), "“in arc” re-runs in Arc")
        check(FollowUpRouting.reference("do it in chrome") == .init(rerun: true, mode: .browser("Google Chrome")), "“do it in chrome” re-runs in Chrome")
        check(FollowUpRouting.reference("Try again in the foreground") == .init(rerun: true, mode: .foreground), "retry in foreground re-runs")
        check(FollowUpRouting.reference("book a table for two at 8") == nil, "a self-contained task is not a back-reference")
        check(FollowUpRouting.reference("submit the expense report for March") == nil, "a named target is not a back-reference")
        check(FollowUpRouting.reference("https://x.com/job apply it") == nil, "a new URL is a new task")
        check(FollowUpRouting.reference("search for flights to Delhi") == nil, "words containing “arc” don't pick Arc")
        let now = Date()
        let older = FollowUpRouting.Prior(request: "https://saarthi.example/job/1 apply", outcome: "Form filled, not submitted", finishedAt: now.addingTimeInterval(-20 * 60), stopped: false)
        let newer = FollowUpRouting.Prior(request: "https://jobs.example/2", outcome: "Stopped", finishedAt: now.addingTimeInterval(-5 * 60), stopped: true)
        let stale = FollowUpRouting.Prior(request: "old", outcome: "", finishedAt: now.addingTimeInterval(-31 * 60), stopped: false)
        check(FollowUpRouting.pick([older, newer, stale], now: now) == newer, "the newest recent task is continued")
        check(FollowUpRouting.pick([stale], now: now) == nil, "tasks older than 30 minutes are not continued")
        let context = FollowUpRouting.context(for: older, now: now)
        check(context.contains("Page: https://saarthi.example/job/1") && context.contains("Form filled, not submitted") && context.contains("20 min ago"), "context carries request, URL and outcome")
        check(FollowUpRouting.request("in arc", reference: .init(rerun: true, mode: .browser("Arc")), prior: older).hasPrefix(older.request), "a bare browser reply repeats the request")
        check(FollowUpRouting.request("Submit it", reference: .init(rerun: false, mode: nil), prior: older) == "Submit it", "a continuation keeps the user's words")
        check(!FollowUpRouting.background(.init(rerun: true, mode: .browser("Arc")), default: true), "Arc runs in front")
        check(!FollowUpRouting.background(.init(rerun: true, mode: .foreground), default: true) && FollowUpRouting.background(.init(rerun: false, mode: nil), default: true), "mode follows the reply")

        // Completion photo: saved → final (pre-cleanup) → live → card thumbnail; a stopped run gets none.
        let saved = Data("saved".utf8), final = Data("final".utf8), live = Data("live".utf8), card = Data("card".utf8)
        check(CompletionPhoto.pick(saved: saved, final: final, live: live, card: card, stopped: false, limit: 100) == saved, "saved unconfirmed screenshot first")
        check(CompletionPhoto.pick(saved: nil, final: final, live: live, card: card, stopped: false, limit: 100) == final, "pre-cleanup capture before a late live capture")
        check(CompletionPhoto.pick(saved: nil, final: nil, live: live, card: card, stopped: false, limit: 100) == live, "live capture next")
        check(CompletionPhoto.pick(saved: nil, final: Data(), live: nil, card: card, stopped: false, limit: 100) == card, "failed captures fall back to the card thumbnail")
        check(CompletionPhoto.pick(saved: nil, final: Data(repeating: 1, count: 200), live: nil, card: card, stopped: false, limit: 100) == card, "oversized capture is skipped")
        check(CompletionPhoto.pick(saved: nil, final: final, live: live, card: card, stopped: true, limit: 100) == nil, "stopped runs get no final view")
        check(CompletionPhoto.fallback([nil, Data(), card, live], limit: 100) == card, "fallback skips empty candidates, keeps order")
        check(CompletionPhoto.fallback([Data(repeating: 1, count: 200), nil], limit: 100) == nil, "no usable thumbnail: none")
        check(CompletionPhoto.pick(saved: nil, final: nil, live: nil, card: CompletionPhoto.fallback([nil, live], limit: 100), stopped: false, limit: 100) == live, "queued thumbnail used when the card has none")
        let fast = blocking { await CompletionPhoto.capture(timeout: 1) { final } }
        check(fast == final, "capture returns a prompt result")
        let started = Date()
        let slow = blocking { await CompletionPhoto.capture(timeout: 0.2) { try? await Task.sleep(nanoseconds: 3_000_000_000); return final } }
        check(slow == nil && Date().timeIntervalSince(started) < 1.5, "a hung capture times out to nil")
        check(CompletionPhoto.pick(saved: nil, final: slow, live: nil, card: card, stopped: false, limit: 100) == card, "timed-out capture falls back to the card thumbnail")
        check(CompletionPhoto.layout(photo: final, fullText: "Done") == .photoWithCaption, "short result is the photo's caption")
        check(CompletionPhoto.layout(photo: final, fullText: String(repeating: "x", count: 1100)) == .photoThenText, "long result: photo, then text")
        check(CompletionPhoto.layout(photo: nil, fullText: "Done") == .textOnly, "no image: text only")

        print(failures == 0 ? "All Telegram UI tests passed." : "\(failures) Telegram UI test(s) failed.")
        if failures > 0 { exit(1) }
    }
}

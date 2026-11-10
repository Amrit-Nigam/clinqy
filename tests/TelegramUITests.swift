import Foundation

/// Pure Telegram copilot logic: escaping, card rendering per state, button layouts, callback routing, splitting,
/// edit coalescing, photo pacing, retry rules and reply routing.
@main
struct TelegramUITests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        if ok { print("PASS \(what)") } else { failures += 1; print("FAIL: \(what)") }
    }
    static func texts(_ rows: [[TGButton]]) -> [[String]] { rows.map { $0.map(\.text) } }
    static func flat(_ rows: [[TGButton]]) -> [TGButton] { rows.flatMap { $0 } }

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

        print(failures == 0 ? "All Telegram UI tests passed." : "\(failures) Telegram UI test(s) failed.")
        if failures > 0 { exit(1) }
    }
}

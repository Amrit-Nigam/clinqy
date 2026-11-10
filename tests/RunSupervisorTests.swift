import Foundation

/// Pure run-registry logic: pause state machine, persistence across relaunch, question timeouts and safe defaults.
@main
struct RunSupervisorTests {
    @MainActor static var failures = 0
    @MainActor static func check(_ ok: Bool, _ what: String) {
        if ok { print("PASS \(what)") } else { failures += 1; print("FAIL: \(what)") }
    }

    @MainActor static func main() async {
        setbuf(stdout, nil)
        // State machine.
        check(RunControl.running.apply(.pause) == .init(state: .paused), "running → pause")
        check(RunControl.running.apply(.resume) == nil && RunControl.running.apply(.handBack) == nil, "resume/hand back need a paused run")
        check(RunControl.paused.apply(.resume) == .init(state: .running), "paused → resume without re-observe")
        check(RunControl.running.apply(.takeOver) == .init(state: .takenOver, reveal: true), "take over pauses and releases the target")
        check(RunControl.paused.apply(.takeOver)?.reveal == true, "paused run can be taken over")
        check(RunControl.takenOver.apply(.handBack) == .init(state: .running, reobserve: true), "hand back re-observes")
        check(RunControl.takenOver.apply(.resume)?.reobserve == true, "resume after take over also re-observes")
        check(RunControl.takenOver.apply(.pause) == nil, "pausing a taken-over run changes nothing")

        // Safe defaults: never approve pay/send/delete/post/submit, never claim an outcome.
        let t = QuestionPolicy.defaultTimeout
        check(QuestionPolicy.defaultAnswer(options: ["Yes, go ahead", "No"], sensitive: false, timeout: t) == .option("No"), "risky confirm defaults to No")
        check(QuestionPolicy.defaultAnswer(options: ["Go ahead", "Not now"], sensitive: false, timeout: t) == .option("Not now"), "mic prompt defaults to Not now")
        check(QuestionPolicy.defaultAnswer(options: ["Submit", "Edit"], sensitive: false, timeout: t) == .text(QuestionPolicy.skipText(timeout: t)), "form review never auto-submits")
        check(QuestionPolicy.defaultAnswer(options: ["Yes, that happened", "No, it did not happen"], sensitive: false, timeout: t).reply?.hasPrefix("[") == true, "user_confirms default asserts no outcome")
        check(QuestionPolicy.defaultAnswer(options: ["Keep background mode", "Continue in foreground", "Stop task"], sensitive: false, timeout: t) == .option("Keep background mode"), "background attention keeps background")
        check(QuestionPolicy.defaultAnswer(options: ["I've handled it in the task tab", "Stop this task"], sensitive: false, timeout: t) == .option("Stop this task"), "isolated attention never claims it was handled")
        check(QuestionPolicy.defaultAnswer(options: ["Skip", "Pay now"], sensitive: false, timeout: t) == .option("Skip"), "skip preferred")
        check(QuestionPolicy.defaultAnswer(options: ["Don't send", "Send"], sensitive: false, timeout: t).reply?.hasPrefix("[") == true, "options naming a risky verb are never chosen")
        check(QuestionPolicy.defaultAnswer(options: ["x"], sensitive: true, timeout: t) == .none, "private questions get no answer")
        let skip = QuestionPolicy.skipText(timeout: t)
        check(QuestionPolicy.isTimeoutDefault(skip) && !QuestionPolicy.isTimeoutDefault("Delhi"), "timeout default is recognisable (never saved to the profile)")
        check(QuestionPolicy.skipAnswer(options: ["Pay now", "Not now"]) == "Not now", "remote Skip picks the declining option")
        let userSkip = QuestionPolicy.skipAnswer(options: ["Submit", "Edit"])
        check(userSkip.hasPrefix(QuestionPolicy.skippedPrefix) && QuestionPolicy.isTimeoutDefault(userSkip) && userSkip.contains("don't"), "remote Skip never submits and is never remembered as the user's answer")
        check(!skip.lowercased().hasPrefix("yes") && !skip.lowercased().hasPrefix("no") && skip.contains("don't"), "free-text default can't parse as yes or as no")
        for option in ["Pay $40", "Buy", "Delete permanently", "Post publicly", "Send email", "Submit", "Confirm", "Yes"] {
            check(QuestionPolicy.isRisky(option), "risky: \(option)")
        }

        // Timeout config.
        check(QuestionPolicy.timeout(config: nil) == 600 && QuestionPolicy.timeout(config: "junk") == 600, "default timeout 10 min")
        check(QuestionPolicy.timeout(config: "3") == 180 && QuestionPolicy.timeout(config: "0") == nil && QuestionPolicy.timeout(config: "never") == nil, "configurable timeout")

        // Card rendering.
        check(QuestionPolicy.note(.text(skip), timeout: 600) == "No answer in 10 min → I'll skip this step.", "skip note text")
        check(QuestionPolicy.note(.option("No"), timeout: 60) == "No answer in 1 min → I'll choose “No”.", "option note text")
        check(QuestionPolicy.note(.none, timeout: nil) == nil, "no timeout, no note")
        let card = RemoteQuestionCard.render(shortID: "abc12345", text: "Which city?", sensitive: false, note: "No answer in 10 min → I'll skip this step.")
        check(card.hasPrefix("[abc12345] Input needed") && card.contains("Which city?") && card.contains("⏱ No answer in 10 min"), "question card shows text and default")
        let secret = RemoteQuestionCard.render(shortID: "abc12345", text: "Your bank password?", sensitive: true, note: nil)
        check(!secret.contains("bank password") && secret.contains("on your Mac"), "private question text stays on the Mac")
        check(RemoteQuestionCard.render(shortID: "a", text: "q", sensitive: false, note: "n", paused: true).contains("Paused"), "paused card says no default applies")

        // Registry + persistence across relaunch.
        let suite = "clinqy.runsupervisor.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let first = RunSupervisor(defaults: defaults)
        var changes = 0
        first.onChange = { if $0 == id { changes += 1 } }
        first.register(run: id, source: .mcp, title: "Fill the form", background: true)
        check(first.entry(id)?.source == .mcp && first.state(id) == .running && changes == 1, "register records source")
        check(first.apply(.resume, to: id) == nil, "resume of a running run is refused")
        check(first.apply(.pause, to: id) != nil && first.isPaused(id), "pause")
        let relaunched = RunSupervisor(defaults: defaults)
        check(!relaunched.isPaused(id), "unknown run isn't paused until registered")
        relaunched.register(run: id, source: .mcp, title: "Fill the form", background: true)
        check(relaunched.state(id) == .paused, "paused state survives relaunch")
        check(relaunched.apply(.resume, to: id) != nil && RunSupervisor(defaults: defaults).state(id) == .running, "resume clears persisted pause")
        relaunched.apply(.takeOver, to: id)
        relaunched.finished(run: id)
        let third = RunSupervisor(defaults: defaults)
        third.register(run: id, source: .mcp, title: "x", background: true)
        check(third.state(id) == .running, "finished run's pause is forgotten")
        third.finished(run: id)

        // Pause gate.
        let gate = RunSupervisor(defaults: defaults)
        let run = UUID()
        gate.register(run: run, source: .mac, title: "t", background: false)
        let none = await gate.waitIfPaused(run, poll: .milliseconds(5))
        check(none == nil, "running run passes straight through")
        gate.apply(.pause, to: run)
        let waiting = Task { await gate.waitIfPaused(run, poll: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        gate.apply(.resume, to: run)
        let plain = await waiting.value
        check(plain == nil, "plain resume has no note")
        gate.apply(.takeOver, to: run)
        let taken = Task { await gate.waitIfPaused(run, poll: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(30))
        gate.apply(.handBack, to: run)
        let note = await taken.value
        check(note == RunSupervisor.handBackNote, "hand back returns the re-observe note once")
        let again = await gate.waitIfPaused(run)
        check(again == nil, "note is delivered only once")
        let cancelled = Task { await gate.waitIfPaused(run, poll: .milliseconds(5)) }
        gate.apply(.pause, to: run)
        cancelled.cancel()
        _ = await cancelled.value
        check(true, "cancelled run stops waiting")
        gate.apply(.resume, to: run)

        // Question timeouts.
        gate.questionTimeout = 0.05
        var fired: [String?] = []
        let q = gate.question(run: run, text: "Pay now?", options: ["Yes, go ahead", "No"], sensitive: false) { fired.append($0) }
        check(q.note == "No answer in 1 min → I'll choose “No”.", "question records its default")
        try? await Task.sleep(for: .milliseconds(200))
        check(fired == ["No"] && gate.pendingQuestion(run) == nil, "timeout answers with the safe default")
        fired = []
        gate.question(run: run, text: "Which city?", options: [], sensitive: false) { fired.append($0) }
        gate.answered(run: run)
        try? await Task.sleep(for: .milliseconds(150))
        check(fired.isEmpty, "answered question never times out")
        gate.question(run: run, text: "Which city?", options: [], sensitive: false) { fired.append($0) }
        gate.apply(.pause, to: run)
        try? await Task.sleep(for: .milliseconds(150))
        check(fired.isEmpty && gate.pendingQuestion(run) != nil, "paused run's question waits without a default")
        gate.apply(.resume, to: run)
        try? await Task.sleep(for: .milliseconds(200))
        check(fired.count == 1 && fired[0]?.hasPrefix("[No reply") == true, "resume re-arms the timeout")
        fired = []
        gate.question(run: run, text: "Password?", options: [], sensitive: true) { fired.append($0) }
        try? await Task.sleep(for: .milliseconds(200))
        check(fired.count == 1 && fired[0] == nil, "private question times out with no answer")
        gate.questionTimeout = nil
        gate.question(run: run, text: "Never?", options: [], sensitive: false) { fired.append($0) }
        check(gate.pendingQuestion(run)?.note == nil, "disabled timeout shows no note")
        gate.finished(run: run)
        check(gate.active.isEmpty, "registry empty after finish")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("run supervisor: all checks passed")
    }
}

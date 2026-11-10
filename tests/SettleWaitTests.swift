import Foundation

@main struct SettleWaitTests {
    static var checks = 0
    static func check(_ c: Bool, _ m: String) { checks += 1; if !c { print("FAIL: \(m)"); exit(1) } }
    static func ms(since start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: ContinuousClock().now)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    static func main() async {
        // An early signal ends the wait well before its cap.
        var calls = 0
        var start = ContinuousClock().now
        var held = await SettleWait.until(capMs: 1200, stepMs: 20) { calls += 1; return calls >= 3 }
        check(held && calls == 3, "stops at the first true check")
        check(ms(since: start) < 400, "an early signal doesn't wait out the cap")

        // Immediate truth: no sleep at all.
        calls = 0; start = ContinuousClock().now
        held = await SettleWait.until(capMs: 700, stepMs: 100) { calls += 1; return true }
        check(held && calls == 1 && ms(since: start) < 50, "already true returns at once")

        // No signal: the old fixed sleep is the cap (never shorter, not much longer), with a final check at the cap.
        calls = 0; start = ContinuousClock().now
        held = await SettleWait.until(capMs: 150, stepMs: 20) { calls += 1; return false }
        let waited = ms(since: start)
        check(!held, "times out false")
        check(waited >= 150 && waited < 400, "waits the full cap when nothing signals (\(waited) ms)")
        check(calls >= 3, "polls repeatedly within the cap")

        // Cancellation ends the wait.
        let task = Task { await SettleWait.until(capMs: 5000, stepMs: 20) { false } }
        task.cancel()
        check(await task.value == false, "cancelled wait reports false")

        // Page readiness.
        check(!SettleWait.pageSettled(ready: "loading", elementCount: 10, hasProblem: false), "loading isn't settled")
        check(!SettleWait.pageSettled(ready: "complete", elementCount: 0, hasProblem: false), "empty listing isn't settled")
        check(SettleWait.pageSettled(ready: "interactive", elementCount: 3, hasProblem: false), "interactive with elements is settled")
        check(SettleWait.pageSettled(ready: "complete", elementCount: 0, hasProblem: true), "a blocked page explains its empty list")
        check(SettleWait.pageSettled(ready: nil, elementCount: 1, hasProblem: false), "no readyState still settles on elements")

        // Receipt reactions.
        check(!SettleWait.reacted(nil), "no receipt is no reaction")
        check(!SettleWait.reacted(["mutationCount": 0, "urlChanged": false]), "quiet page is no reaction")
        check(SettleWait.reacted(["mutationCount": 2]), "DOM changes are a reaction")
        check(SettleWait.reacted(["urlChanged": true, "mutationCount": 0]), "navigation is a reaction")
        check(SettleWait.reacted(["unreadable": true]), "a replaced frame is a reaction")

        // Quiet detection.
        var quiet = SettleWait.Quiet()
        check(!quiet.settled(after: 1), "first sample is never quiet")
        check(!quiet.settled(after: 2), "a change isn't quiet")
        check(quiet.settled(after: 2), "the same sample twice is quiet")
        check(!quiet.settled(after: nil), "unreadable isn't quiet")
        check(!quiet.settled(after: 2), "after unreadable, needs two readable samples again")

        // Observation reuse (liveness probe).
        check(ObservationReuse.canSkipAliveCheck(listedInSnapshot: true, actionsSinceSnapshot: 0, snapshotIsCurrentPage: true), "fresh untouched listing is reused")
        check(!ObservationReuse.canSkipAliveCheck(listedInSnapshot: true, actionsSinceSnapshot: 1, snapshotIsCurrentPage: true), "after an action the probe runs")
        check(!ObservationReuse.canSkipAliveCheck(listedInSnapshot: false, actionsSinceSnapshot: 0, snapshotIsCurrentPage: true), "unlisted target is probed")
        check(!ObservationReuse.canSkipAliveCheck(listedInSnapshot: true, actionsSinceSnapshot: 0, snapshotIsCurrentPage: false), "another document is probed")

        // Direct-control binding.
        func bind(browser: Bool = true, tab: Int? = 7, adopt: Bool = true, prefer: Bool = true, native: Bool = true,
                  window: UInt32? = 42, observable: Bool = true, connected: Bool = true) -> ControlBinding {
            ControlBinding.choose(isBrowser: browser, tabID: tab, canAdoptTabs: adopt, extensionPreferred: prefer,
                                  nativeLaneEnabled: native, windowID: window, windowObservable: observable, extensionConnected: connected)
        }
        check(bind() == .tab(id: 7), "adoptable browser tab binds to the tab")
        check(bind(adopt: false) == .foreground, "connected browser without adoption stays foreground (never native input over the DOM)")
        check(bind(prefer: false) == .foreground, "headless preference doesn't adopt the user's tab")
        check(bind(tab: nil, adopt: false, connected: false) == .window(id: 42), "extension-less browser window uses the native lane")
        check(bind(browser: false, tab: nil, adopt: false, connected: false) == .window(id: 42), "native app window binds natively")
        check(bind(browser: false, tab: nil, adopt: false, native: false, connected: false) == .foreground, "native lane off keeps foreground")
        check(bind(browser: false, tab: nil, adopt: false, observable: false, connected: false) == .foreground, "unobservable window keeps foreground")
        check(bind(browser: false, tab: nil, adopt: false, window: nil, connected: false) == .foreground, "no window keeps foreground")
        check(ControlBinding.fallsBack(laneRefusal: "BACKGROUND LANE: x"), "lane refusal falls back")
        check(!ControlBinding.fallsBack(laneRefusal: nil), "no lane refusal, no fallback")

        print("PASS settle waits, observation reuse and control binding (\(checks) checks)")
    }
}

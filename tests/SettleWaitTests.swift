import Foundation

/// Advances only when the wait sleeps; optional oversleep models a delayed CI runner wakeup.
private final class TestClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant
    let minimumResolution = Duration.nanoseconds(1)
    private let lock = NSLock()
    private let start = ContinuousClock().now
    private var elapsed: Duration = .zero
    private var sleeps: [Duration] = []
    let oversleep: Duration

    init(oversleep: Duration = .zero) { self.oversleep = oversleep }
    var now: Instant { lock.withLock { start.advanced(by: elapsed) } }
    var elapsedTime: Duration { lock.withLock { elapsed } }
    var sleepDurations: [Duration] { lock.withLock { sleeps } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        lock.withLock {
            let duration = start.advanced(by: elapsed).duration(to: deadline)
            sleeps.append(duration)
            elapsed += duration + oversleep
        }
    }
}

@main struct SettleWaitTests {
    static var checks = 0
    static func check(_ c: Bool, _ m: String) { checks += 1; if !c { print("FAIL: \(m)"); exit(1) } }
    static func main() async {
        // An early signal ends the wait well before its cap.
        var calls = 0
        var clock = TestClock()
        var held = await SettleWait.until(capMs: 1200, stepMs: 20, clock: clock) { calls += 1; return calls >= 3 }
        check(held && calls == 3, "stops at the first true check")
        check(clock.elapsedTime == .milliseconds(40), "an early signal doesn't wait out the cap")

        // Immediate truth: no sleep at all.
        calls = 0; clock = TestClock()
        held = await SettleWait.until(capMs: 700, stepMs: 100, clock: clock) { calls += 1; return true }
        check(held && calls == 1 && clock.sleepDurations.isEmpty, "already true returns without sleeping")

        // No signal: poll through the deadline, shortening the final sleep to the remaining time.
        calls = 0; clock = TestClock()
        held = await SettleWait.until(capMs: 150, stepMs: 20, clock: clock) { calls += 1; return false }
        check(!held, "times out false")
        check(clock.elapsedTime == .milliseconds(150), "waits the full cap when nothing signals")
        check(calls == 9, "polls immediately, every step and at the cap")
        check(clock.sleepDurations == Array(repeating: .milliseconds(20), count: 7) + [.milliseconds(10)],
              "the final sleep is limited to the remaining cap")

        // A delayed wakeup can cross the deadline after only one sleep; it must not require extra polls.
        calls = 0; clock = TestClock(oversleep: .milliseconds(200))
        held = await SettleWait.until(capMs: 150, stepMs: 20, clock: clock) { calls += 1; return false }
        check(!held && calls == 2 && clock.sleepDurations.count == 1, "oversleep checks once more then times out")

        calls = 0; clock = TestClock()
        held = await SettleWait.until(capMs: 0, stepMs: 20, clock: clock) { calls += 1; return false }
        check(!held && calls == 1 && clock.sleepDurations.isEmpty, "zero cap checks once without sleeping")

        // Exercise the default production clock as well, without a wall-time assertion.
        check(await SettleWait.until(capMs: 700, stepMs: 100) { true }, "default clock accepts an immediate signal")

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

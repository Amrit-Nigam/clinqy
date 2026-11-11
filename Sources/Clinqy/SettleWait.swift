import Foundation

/// Event-driven settle waits: poll an observable condition instead of sleeping a fixed time. Every wait keeps the
/// fixed sleep it replaced as its cap, so a page or app that never signals is no slower than before, and one that
/// signals early moves on at once.
enum SettleWait {
    /// Checks `condition` now and then every `stepMs` until it holds or `capMs` have passed (the last check happens at
    /// or after the cap). True when it held; false on timeout or cancellation.
    @discardableResult
    static func until(capMs: Int, stepMs: Int, _ condition: () async -> Bool) async -> Bool {
        await until(capMs: capMs, stepMs: stepMs, clock: ContinuousClock(), condition)
    }

    /// Accept a clock so polling and deadline behavior can be tested without scheduler timing assumptions.
    @discardableResult
    static func until<C: Clock>(capMs: Int, stepMs: Int, clock: C, _ condition: () async -> Bool) async -> Bool
    where C.Duration == Duration {
        let deadline = clock.now.advanced(by: .milliseconds(max(0, capMs)))
        let step = Duration.milliseconds(max(1, stepMs))
        while true {
            if Task.isCancelled { return false }
            if await condition() { return true }
            let now = clock.now
            guard now < deadline else { return false }
            let left = now.duration(to: deadline)
            do { try await clock.sleep(until: now.advanced(by: left < step ? left : step), tolerance: nil) }
            catch { return false }
        }
    }

    /// A listed page is ready to read: past `document.readyState == "loading"` and showing something (or a problem
    /// that explains why it lists nothing).
    static func pageSettled(ready: String?, elementCount: Int, hasProblem: Bool) -> Bool {
        ready != "loading" && (elementCount > 0 || hasProblem)
    }

    /// An effect receipt (extension `receiptCollect`) shows the page reacted to an input: it navigated, a watched frame
    /// went away (replaced or navigated), or the DOM changed. Nil or no reaction means nothing was observed yet.
    static func reacted(_ receipt: [String: Any]?) -> Bool {
        guard let receipt else { return false }
        if receipt["urlChanged"] as? Bool == true || receipt["unreadable"] as? Bool == true { return true }
        return ((receipt["mutationCount"] as? NSNumber)?.intValue ?? 0) > 0
    }

    /// Quiet detection: the same sample twice in a row (an AX fingerprint, a page signature) means the UI stopped
    /// changing. A nil sample (not readable yet) never counts as quiet.
    struct Quiet {
        private var last: Int?
        init() {}
        mutating func settled(after sample: Int?) -> Bool {
            defer { last = sample }
            guard let sample, let last else { return false }
            return sample == last
        }
    }
}

/// Within one turn, the page listing the model just saw is fresh: a target listed there needs no extra "is it still
/// on the page" round trip until something acts on the page. Every mutation still re-resolves its target in the
/// driver (a vanished element fails there without input), so this only drops a redundant probe.
enum ObservationReuse {
    static func canSkipAliveCheck(listedInSnapshot: Bool, actionsSinceSnapshot: Int, snapshotIsCurrentPage: Bool) -> Bool {
        listedInSnapshot && actionsSinceSnapshot == 0 && snapshotIsCurrentPage
    }
}

/// What a direct-control session (clinqy_observe/act) is bound to. A session binds once, at its first observation,
/// to the exact target it saw; later input goes to that target through the background paths without needing the
/// target in front. Foreground input stays as the fallback when the background path can't take an action.
enum ControlBinding: Equatable {
    /// The observed browser tab, adopted through the extension (CDP input; it stays where it is).
    case tab(id: Int)
    /// The observed native window, through the native background lane (pid-scoped input to that window).
    case window(id: UInt32)
    /// The old behaviour: the target must be frontmost (and its observed tab active) before each input.
    case foreground

    /// Chooses the binding for a first observation. A browser page binds to its tab only when the extension can adopt
    /// tabs; a non-browser (or extension-less browser) window binds natively only when the native lane is on and the
    /// window is observable. Anything else keeps foreground control.
    static func choose(isBrowser: Bool, tabID: Int?, canAdoptTabs: Bool, extensionPreferred: Bool,
                       nativeLaneEnabled: Bool, windowID: UInt32?, windowObservable: Bool, extensionConnected: Bool) -> ControlBinding {
        if isBrowser, let tabID, canAdoptTabs, extensionPreferred { return .tab(id: tabID) }
        if isBrowser, extensionConnected { return .foreground }   // its page is the DOM; native input would bypass it
        if nativeLaneEnabled, let windowID, windowObservable { return .window(id: windowID) }
        return .foreground
    }

    /// Which background refusals fall back to foreground input. Safety refusals and approvals never do: the fallback is
    /// only for an action the background lane can't express (`laneRefusal` comes from the lane's own capability check).
    static func fallsBack(laneRefusal: String?) -> Bool { laneRefusal != nil }
}

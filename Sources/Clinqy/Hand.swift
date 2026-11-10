import AppKit

/// Carries out actions the way a person would, with the buddy as the visible hand: it travels to the Dock
/// to open an app, to the address bar to go somewhere, types at a human rhythm, and hovers before it clicks.
/// Your real mouse is left where you put it.
@MainActor
final class Hand {
    private let buddy: Buddy
    /// Extra time to stay put at the end (e.g. while pointing something out).
    var lingerBeforeHome: TimeInterval = 0
    /// The run's request, so session-ending chords are pressed only when it asked for them.
    var request = ""
    /// Set when switching apps was the point of the task ("open Spotify"): the run's end then leaves it in front.
    var keepFrontApp = false
    /// Why Hand last refused to act (password field, sensitive app, blocked chord, stale target), for the step's message.
    private(set) var refusal: String?

    private var runCursor: CGPoint?
    private var runFrontApp: NSRunningApplication?
    /// Where Clinqy last left the real pointer without putting it back (scrolling moves it).
    private var cursorLeftAt: CGPoint?

    init(buddy: Buddy) { self.buddy = buddy }

    private func trace(_ s: String) {
        if ProcessInfo.processInfo.environment["CB_TRACE"] != nil { print("    · \(s)"); fflush(stdout) }
    }

    private func refuse(_ why: String) -> String {
        refusal = why
        trace("refused: \(why)")
        return why
    }

    // MARK: - Run

    /// Notes the pointer and frontmost app so `endRun` can put things back the way the user had them.
    func beginRun(request: String) {
        self.request = request
        keepFrontApp = false
        refusal = nil
        cursorLeftAt = nil
        runCursor = Self.exactPointer()
        let front = NSWorkspace.shared.frontmostApplication
        runFrontApp = front?.processIdentifier == getpid() ? nil : front
    }

    /// Releases held input and restores the pointer only when the user has not moved it.
    /// Never changes foreground focus during cancellation or completion.
    func endRun() {
        _ = SkyLight.retryPendingCleanup()
        // Windows pinned visible for the run get their occlusion notifications back.
        SkyLight.releaseKeepAlive()
        // A background run never touched the user's pointer, buttons or front app: nothing to put back.
        if Background.active {
            runCursor = nil
            runFrontApp = nil
            cursorLeftAt = nil
            return
        }
        Self.releaseButtons()
        if let start = runCursor, let left = cursorLeftAt, Self.near(Self.exactPointer(), left, 2) {
            Self.restorePointer(start)
        }
        // No activation during cleanup: a foreground change may be the user's choice.
        // We cannot establish ownership of that focus change from the final frontmost PID.
        runCursor = nil
        runFrontApp = nil
        cursorLeftAt = nil
    }

    // MARK: - Pointer

    /// How a click at a point is delivered.
    enum ClickMode: Sendable {
        /// Moves the real pointer, clicks, and puts it back. The default: web pages and many apps trust only real events.
        case real
        /// Posted straight to the app (postToPid): the pointer never moves, and the window needn't be frontmost.
        case pid
        /// Private SkyLight path for Chromium/Electron windows in the background. Every click of a background run
        /// goes this way; other runs only with BACKGROUND_CLICKS=1.
        case background
    }

    /// How the last element click went through: "axpress" or "real" (for the click log).
    private(set) var lastMethod = ""
    private(set) var lastClickUncertain = false

    /// Submit one input delivery. A successful AX request must not be followed by another click merely
    /// because its visible acknowledgement is slow; the caller owns effect verification.
    @discardableResult
    func click(_ el: UIElementInfo, in app: NSRunningApplication, fingerprint: Int, window requested: WindowSnapshot? = nil) async -> String? {
        lastClickUncertain = false
        guard let window = requested ?? WindowSnapshot.capture(app), window.pid == app.processIdentifier,
              el.windowID == nil || el.windowID == window.windowID else { return refuse("the element's window cannot be verified; look again") }
        if let requested, el.observationID != requested.id { return refuse("the element belongs to another observation; look again") }
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        // A long text or scroll area may have its centre outside the window: aim at its part inside the window.
        guard let aim = NativeAim.point(element: el.frame, window: window.frame) else { return refuse("the element is outside the observed window; look again") }
        lastMethod = "axpress"
        await buddy.travel(to: aim, framing: el.frame)
        guard !Task.isCancelled else { return "Stopped" }
        if Efficiency.humanMotion { try? await Task.sleep(for: .milliseconds(80)) }
        guard !Task.isCancelled else { return "Stopped" }
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        buddy.click()
        let element = el.element
        guard !Task.isCancelled else { return "Stopped" }
        switch await Task.detached(operation: { AXEngine.axPressDelivery(element) }).value {
        case .delivered: return nil
        case .uncertain:
            lastClickUncertain = true
            return nil // Observe the effect; never issue a second input after an ambiguous AX reply.
        case .unsupported: break
        }
        guard !Task.isCancelled else { return "Stopped" }
        // An explicitly unsupported AX action permits one checked pixel input.
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        if let why = hitCheck(aim, pid: app.processIdentifier, window: window.element) { return refuse(why) }
        if Background.active {
            lastMethod = "background"
            return backgroundClick(at: aim, pid: app.processIdentifier, window: window)
        }
        lastMethod = "real"
        realClick(at: aim)
        return nil
    }

    /// Selects the row (AXSelected=true) and, if nothing changed, clicks its centre inside the pinned window
    /// (pid-posted/SkyLight in background, a real click in foreground). nil = sent.
    func selectOrClickRow(_ el: UIElementInfo, in app: NSRunningApplication, fingerprint: Int, window requested: WindowSnapshot?) async -> String? {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el.element, kAXSelectedAttribute as CFString, &settable) == .success, settable.boolValue,
           AXUIElementSetAttributeValue(el.element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
            lastMethod = "axselect"
            try? await Task.sleep(for: .milliseconds(150))
            if await AXEngine.fingerprintAsync(of: app) != fingerprint { return nil }
        }
        guard let window = requested ?? WindowSnapshot.capture(app), window.pid == app.processIdentifier,
              el.windowID == nil || el.windowID == window.windowID else { return refuse("the row's window cannot be verified; look again") }
        if let why = window.staleness() { return refuse(why) }
        guard let aim = NativeAim.point(element: el.frame, window: window.frame) else { return refuse("the row is outside the observed window; look again") }
        if let why = hitCheck(aim, pid: app.processIdentifier, window: window.element) { return refuse(why) }
        if Background.active {
            lastMethod = "background"
            return backgroundClick(at: aim, pid: app.processIdentifier, window: window)
        }
        lastMethod = "real"
        realClick(at: aim)
        return nil
    }

    /// Clicks a screen point, with the buddy travelling there first. Given the target `pid` (and the `window` as
    /// scanned), first checks the window is unchanged and the point still shows that app, so a moved window or a
    /// popup that slid in isn't clicked by mistake. Returns why it didn't click (re-scan and retry), or nil.
    @discardableResult
    func click(at point: CGPoint, pid: pid_t? = nil, window: WindowSnapshot? = nil, mode: ClickMode = .real) async -> String? {
        let mode = Background.active ? .background : mode
        if let window {
            guard pid == window.pid, window.frame.contains(point) else { return refuse("the point is outside the observed target window; look again") }
            if let why = window.staleness(includeContent: true) { return refuse(why) }
        }
        if let pid, let why = hitCheck(point, pid: pid, window: window?.element) { return refuse(why) }
        await buddy.travel(to: point)
        guard !Task.isCancelled else { return "Stopped" }
        if Efficiency.humanMotion { try? await Task.sleep(for: .milliseconds(80)) }
        guard !Task.isCancelled else { return "Stopped" }
        // Cursor animation is asynchronous: verify again immediately before input delivery.
        if let why = window?.staleness(includeContent: true) { return refuse(why) }
        if let pid, let why = hitCheck(point, pid: pid, window: window?.element) { return refuse(why) }
        buddy.click()
        switch mode {
        case .real:
            realClick(at: point)
        case .pid:
            guard let pid else { return refuse("a click sent to an app needs its pid") }
            Self.postClick(at: point, pid: pid)
        case .background:
            guard let pid else { return refuse("a background click needs the app's pid") }
            if !Background.active, !SkyLight.isEnabled { return refuse("background clicks are off (BACKGROUND_CLICKS=1 enables them)") }
            return backgroundClick(at: point, pid: pid, window: window)
        }
        return nil
    }

    /// A click on `pid`'s window at `point` that leaves the pointer and the front app alone: SkyLight where this macOS
    /// has it (Chromium and Electron windows take nothing else), else posted to the app.
    private func backgroundClick(at point: CGPoint, pid: pid_t, window: WindowSnapshot?, button: SkyLight.Button = .left, count: Int = 1) -> String? {
        guard SkyLight.isAvailable else { return refuse("background pointer input is unavailable on this macOS; use a semantic control or foreground handoff") }
        guard let window, window.pid == pid, window.frame.contains(point) else {
            return refuse("background input needs the exact observed window; observe again")
        }
        // Callers checked staleness immediately before; SkyLight.click re-captures the exact window and checks
        // it again right before delivery, so no extra content fingerprint pass happens here.
        // Never substitute another window or a helper process merely because it occupies the same coordinates.
        if let why = SkyLight.click(at: point, pid: pid, window: window.windowID, frame: window.frame, button: button, count: count) { return refuse(why) }
        return nil
    }

    /// Click options a SkyLight background click can honour exactly: left or right, one or two clicks,
    /// no modifiers and no hold. Anything else stays a foreground handoff rather than an approximation.
    nonisolated static func skyCompatible(_ options: ClickOptions) -> Bool {
        options.button != .middle && (1...2).contains(options.count) && options.modifiers.isEmpty && options.holdMilliseconds == 0
    }

    /// Whether a window number still exists anywhere (including other Spaces).
    nonisolated static func windowExists(_ id: CGWindowID) -> Bool { NativeWindowObservation.serverInfo(id) != nil }

    /// The frontmost normal-level window at `point`, whoever owns it.
    nonisolated static func topWindow(at point: CGPoint) -> (pid: pid_t, id: CGWindowID, frame: CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list where info[kCGWindowLayer as String] as? Int == 0 {
            guard let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), pid != getpid(),
                  let id = info[kCGWindowNumber as String] as? Int, let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point) else { continue }
            return (pid, CGWindowID(id), frame)
        }
        return nil
    }

    /// Puts the caret in a text box: travel, click, focus. Returns why it didn't, or nil.
    @discardableResult
    func focus(_ el: UIElementInfo, in app: NSRunningApplication, window requested: WindowSnapshot? = nil) async -> String? {
        focusUnverified = false
        guard Self.isTextRole(el.role) else { return refuse("the requested element is not a text input; look again before typing") }
        guard let window = requested ?? WindowSnapshot.capture(app), window.pid == app.processIdentifier,
              el.windowID == nil || el.windowID == window.windowID,
              requested.map { el.observationID == $0.id } ?? true else { return refuse("the field belongs to another observation; look again") }
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        await buddy.travel(to: el.center, framing: el.frame)
        guard !Task.isCancelled else { return "Stopped" }
        if Efficiency.humanMotion { try? await Task.sleep(for: .milliseconds(90)) }
        guard !Task.isCancelled else { return "Stopped" }
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        buddy.click()
        var settable = DarwinBoolean(false)
        let canFocus = AXUIElementIsAttributeSettable(el.element, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
        let setOK = canFocus && AXEngine.focus(el.element)
        // AXFocused unavailable or ignored (chat composers often are): click the field itself, pid-posted in background.
        if !canFocus || !Self.focusHeld(el.element, in: app, window: window.element, focusSet: setOK) {
            if canFocus { try? await Task.sleep(for: .milliseconds(60)) }
            if !canFocus || !Self.focusHeld(el.element, in: app, window: window.element, focusSet: setOK) {
                if let why = hitCheck(el.center, pid: app.processIdentifier, window: window.element) { return refuse(why) }
                if Background.active {
                    if let why = backgroundClick(at: el.center, pid: app.processIdentifier, window: window) { return refuse(why) }
                } else { realClick(at: el.center) }
            }
        }
        try? await Task.sleep(for: .milliseconds(120))
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        // The background lane: the app-wide focus may never update, so set AXFocused on the field once more and
        // accept the pinned window's own focused element when it is this field.
        var focusSet = setOK
        if Background.active, canFocus, !Self.focusHeld(el.element, in: app, window: window.element, focusSet: setOK) {
            focusSet = AXEngine.focus(el.element)
            try? await Task.sleep(for: .milliseconds(60))
        }
        guard Self.focusHeld(el.element, in: app, window: window.element, focusSet: focusSet) else {
            focusUnverified = true
            return refuse("the requested field did not acquire verifiable focus; look again before typing")
        }
        return nil
    }

    /// The last `focus` refused only because the field's focus couldn't be verified (not staleness, not a hit check).
    private(set) var focusUnverified = false

    /// How `focused` relates to `target`: the target itself, an editable descendant of it, another text input, etc.
    nonisolated static func focusRelation(_ focused: AXUIElement?, to target: AXUIElement) -> FocusVerification.Relation {
        guard let focused else { return .unreadable }
        if CFEqual(focused, target) { return .target }
        let text = isTextRole(AXEngine.attribute(focused, kAXRoleAttribute))
        var current: AXUIElement? = AXEngine.attribute(focused, kAXParentAttribute)
        for _ in 0..<16 {
            guard let item = current else { break }
            if CFEqual(item, target) { return text ? .inside : .other }
            current = AXEngine.attribute(item, kAXParentAttribute)
        }
        return text ? .otherText : .other
    }

    /// The app's focused element relation to `target` (one AX read).
    nonisolated static func appFocusRelation(_ target: AXUIElement, in app: NSRunningApplication) -> FocusVerification.Relation {
        focusRelation(AXEngine.attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute), to: target)
    }

    /// `target` holds focus: the app's focused element is it (or inside it); in the background, after a successful
    /// AXFocused set, the pinned window's focused element being it counts too (FocusVerification).
    static func focusHeld(_ target: AXUIElement, in app: NSRunningApplication, window: AXUIElement?, focusSet: Bool) -> Bool {
        let appRelation = appFocusRelation(target, in: app)
        let windowRelation: FocusVerification.Relation = window.map {
            focusRelation(AXEngine.attribute($0, kAXFocusedUIElementAttribute), to: target)
        } ?? .unreadable
        return FocusVerification.accepts(app: appRelation, window: windowRelation, focusSet: focusSet, background: Background.active)
    }

    nonisolated static func isTextRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea"].contains(role)
    }

    /// A real click, with the user's pointer put back afterwards.
    /// Foreground gestures use the same window provenance and hit checks as clicks. Always release a
    /// possibly delivered down event, including cancellation and failure during a drag.
    func gesture(_ plan: PointerGesture, in app: NSRunningApplication, window: WindowSnapshot) async -> String? {
        if Background.active {
            // Right and double clicks are window-targeted SkyLight clicks; hover and drag need the real pointer.
            guard plan.kind == .right_click || plan.kind == .double_click else { return refuse("Native hover and drag require foreground mode") }
            let point = CGPoint(x: plan.start.x, y: plan.start.y)
            guard app.processIdentifier == window.pid, window.frame.contains(point) else { return refuse("gesture endpoints must belong to the observed window") }
            if let why = window.staleness(includeContent: true) { return refuse(why) }
            if let why = hitCheck(point, pid: app.processIdentifier, window: window.element) { return refuse(why) }
            buddy.click()
            lastMethod = "background"
            return backgroundClick(at: point, pid: app.processIdentifier, window: window,
                                   button: plan.kind == .right_click ? .right : .left, count: plan.kind == .double_click ? 2 : 1)
        }
        let start = CGPoint(x: plan.start.x, y: plan.start.y), end = CGPoint(x: plan.end.x, y: plan.end.y)
        guard app.processIdentifier == window.pid, window.frame.contains(start), window.frame.contains(end) else {
            return refuse("gesture endpoints must belong to the observed window")
        }
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        for point in [start, end] {
            if let why = hitCheck(point, pid: app.processIdentifier, window: window.element) { return refuse(why) }
        }
        await buddy.travel(to: start)
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        for point in [start, end] {
            if let why = hitCheck(point, pid: app.processIdentifier, window: window.element) { return refuse(why) }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        var held = false, last = start
        defer {
            if held {
                CGEvent(mouseEventSource: source, mouseType: plan.kind == .right_click ? .rightMouseUp : .leftMouseUp,
                        mouseCursorPosition: last, mouseButton: plan.kind == .right_click ? .right : .left)?.post(tap: .cghidEventTap)
            }
            cursorLeftAt = last
        }
        for step in plan.events {
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                return refuse("gesture interrupted; inspect the result before repeating input")
            }
            let point = CGPoint(x: step.point.x, y: step.point.y)
            let type: CGEventType = step.phase == .move ? (held ? .leftMouseDragged : .mouseMoved)
                : step.phase == .down ? (step.right ? .rightMouseDown : .leftMouseDown) : (step.right ? .rightMouseUp : .leftMouseUp)
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                      mouseButton: step.right ? .right : .left) else { return refuse("couldn't construct pointer event") }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(step.count))
            // Treat delivery as possible before posting; cancellation must still release the button.
            if step.phase == .down { held = true }
            last = point
            event.post(tap: .cghidEventTap)
            if step.phase == .up { held = false }
            try? await Task.sleep(for: .milliseconds(plan.kind == .drag ? 20 : 35))
        }
        return nil
    }

    private func realClick(at point: CGPoint) {
        // The exact pointer location, fractions included: the restore puts the user's pointer back exactly where it
        // was, not a fraction of a pixel away (round 10: 1389.59,591.52 came back as 1389,591).
        let saved = Self.exactPointer()
        Self.postRealClick(at: point)
        usleep(25_000)
        Self.restorePointer(saved)
    }

    /// The pointer in global display coordinates (top-left origin), with its fractional part kept.
    static func exactPointer() -> CGPoint { CGEvent(source: nil)?.location ?? Buddy.mouse() }

    /// Puts the pointer back at exactly `saved`. The warp may land on whole pixels; when the pointer then reads
    /// differently, one mouse-moved event at the exact (fractional) point finishes the restore.
    nonisolated static func restorePointer(_ saved: CGPoint) {
        CGWarpMouseCursorPosition(saved)
        CGAssociateMouseAndMouseCursorPosition(1)
        guard let now = CGEvent(source: nil)?.location, PointerRestore.needsExactMove(saved: saved, now: now) else { return }
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved,
                mouseCursorPosition: saved, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Down and up through the HID stream; the up is posted however the down went, so the button is never left held.
    nonisolated private static func postRealClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        defer {
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        usleep(15_000)
    }

    /// A click posted to the app itself: the real pointer stays put. The window number fields let AppKit route it
    /// to the right window even when it isn't frontmost.
    nonisolated private static func postClick(at point: CGPoint, pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let window = windowInfo(pid: pid, containing: point)?.id
        func post(_ type: CGEventType) {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            if let window {
                e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
                e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
            }
            e.postToPid(pid)
        }
        post(.leftMouseDown)
        defer { post(.leftMouseUp) }
        usleep(15_000)
    }

    /// Lets go of any mouse button still down (a click interrupted by a crash, cancel or error).
    nonisolated static func releaseButtons() {
        let point = CGEvent(source: nil)?.location ?? .zero
        for (button, type) in [(CGMouseButton.left, CGEventType.leftMouseUp), (.right, .rightMouseUp)]
        where CGEventSource.buttonState(.combinedSessionState, button: button) {
            CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                    mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Pre-click checks

    /// What's under `point` must belong to `pid` (and to the element's window, when known), or the click would
    /// land on something else: another app's popup, a window that moved.
    private func hitCheck(_ point: CGPoint, pid: pid_t, windowOf element: AXUIElement) async -> String? {
        let window: AXUIElement? = Self.axAttr(element, kAXWindowAttribute)
        return hitCheck(point, pid: pid, window: window)
    }

    private func hitCheck(_ point: CGPoint, pid: pid_t, window: AXUIElement?) -> String? {
        Background.active ? Self.hitMismatchInApp(at: point, pid: pid, window: window) : Self.hitMismatch(at: point, pid: pid, window: window)
    }

    /// hitMismatch for a background run, whose window is expected to sit under the user's: only the app's own
    /// windows are hit-tested, so another of its windows (a popup that slid in, a moved window) still stops the click.
    static func hitMismatchInApp(at point: CGPoint, pid: pid_t, window: AXUIElement?) -> String? {
        var hit: AXUIElement?
        guard let window, AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &hit) == .success,
              let hit, let hitWindow: AXUIElement = axAttr(hit, kAXWindowAttribute), !CFEqual(hitWindow, window) else { return nil }
        return "a different \(NSRunningApplication(processIdentifier: pid)?.cleanName ?? "app") window is at that spot now; look again"
    }

    /// Why the element at `point` isn't the target app's (or target window's), or nil. Inconclusive answers
    /// (no element, Clinqy's own overlay) pass: this guards against clicking the wrong thing, not against clicking.
    /// Main thread only: a hit test that lands on one of Clinqy's own windows is answered in this process on the calling
    /// thread, and off the main thread AppKit throws inside SwiftUI's update and leaves its lock held, freezing the app.
    static func hitMismatch(at point: CGPoint, pid: pid_t, window: AXUIElement?) -> String? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(hit, &owner) == .success, owner != getpid() else { return nil }
        // Web content can answer from the browser's own helper process (Safari's WebContent, Chromium helpers).
        let helper = NSRunningApplication(processIdentifier: owner).map { app in
            let id = app.bundleIdentifier?.lowercased() ?? ""
            return id.hasPrefix("com.apple.webkit") || id.contains(".helper") || id.contains("framework")
        } ?? true
        if owner != pid, !helper {
            let other = NSRunningApplication(processIdentifier: owner)?.cleanName ?? "another app"
            let target = NSRunningApplication(processIdentifier: pid)?.cleanName ?? "the target app"
            return "\(other) is on top at that spot, not \(target); look again before clicking"
        }
        if let window, let hitWindow: AXUIElement = axAttr(hit, kAXWindowAttribute), !CFEqual(hitWindow, window) {
            return "a different \(NSRunningApplication(processIdentifier: pid)?.cleanName ?? "app") window is at that spot now; look again"
        }
        return nil
    }

    /// Kept as an alias for input callers; observation, capture and execution share one immutable identity.
    typealias WindowSnapshot = NativeWindowObservation

    /// Numbers of `pid`'s normal-level windows, wherever they are.
    nonisolated static func windowIDs(pid: pid_t) -> Set<CGWindowID> {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid, info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? Int else { return nil }
            return CGWindowID(id)
        })
    }

    /// The on-screen normal-level window of `pid` containing `point`: its number and bounds.
    nonisolated static func windowInfo(pid: pid_t, containing point: CGPoint) -> (id: CGWindowID, frame: CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list where (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid
            && info[kCGWindowLayer as String] as? Int == 0 {
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point) else { continue }
            return (CGWindowID(id), frame)
        }
        return nil
    }

    nonisolated private static func axAttr<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    nonisolated private static func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    /// Presses a combo. Refuses (false, with `refusal` set) a lock/log-out/force-quit chord the request didn't ask for.
    @discardableResult
    func press(_ keys: String) -> Bool {
        refusal = nil
        if let why = Safety.blockedChord(keys, request: request) { _ = refuse(why); return false }
        if let why = AXEngine.chordProblem(keys) { _ = refuse(why); return false }
        buddy.click()
        return AXEngine.press(combo: keys)
    }

    /// Exact-window keyboard route used by native tasks, including the opt-in background capability.
    @discardableResult
    func press(_ keys: String, in app: NSRunningApplication, window: WindowSnapshot) -> Bool {
        refusal = nil
        if let why = Safety.blockedChord(keys, request: request) ?? AXEngine.chordProblem(keys) { _ = refuse(why); return false }
        guard window.pid == app.processIdentifier, window.staleness() == nil, !Task.isCancelled else {
            _ = refuse("the keyboard target changed; observe again"); return false
        }
        if let why = Safety.secureInputBlock() { _ = refuse(why); return false }
        let session: SkyLight.KeyboardSession
        switch SkyLight.beginKeyboard(in: window) {
        case .failure(let error): _ = refuse(error.reason); return false
        case .success(let value): session = value
        }
        let delivered = AXEngine.press(combo: keys, in: app, window: window)
        guard session.finish() else { _ = refuse("keyboard delivery is uncertain because temporary focus cleanup failed"); return false }
        switch delivered {
        case .delivered: buddy.click(); return true
        case .unsupported: _ = refuse("the target cannot deliver this shortcut without a foreground handoff"); return false
        case .uncertain: _ = refuse("the shortcut may have taken effect; inspect before repeating it"); return false
        }
    }

    func scroll(up: Bool, in app: NSRunningApplication) async {
        await scroll(ScrollPlan(direction: up ? .up : .down, unit: .lines, amount: 12, isDefault: true), in: app, window: nil)
    }

    /// Scrolls as asked: direction, unit and amount are all honoured. With `anchor` the wheel is aimed at that point
    /// (which must lie inside the observed `window`); otherwise at the window's middle.
    /// Returns why it did not scroll, or nil.
    @discardableResult
    func scroll(_ plan: ScrollPlan, in app: NSRunningApplication, window: WindowSnapshot?, anchor: CGPoint? = nil) async -> String? {
        refusal = nil
        if Background.active { return await backgroundScroll(plan, in: app, window: window, anchor: anchor) }
        if let window {
            guard window.pid == app.processIdentifier else { return refuse("the scroll target belongs to another application; look again") }
            if let why = window.staleness() { return refuse(why) }
            if let anchor, !window.frame.contains(anchor) { return refuse("the scroll anchor is outside the observed window; look again") }
        }
        let frame = window?.frame ?? AXEngine.windowFrame(of: app)
        if let anchor, window == nil, let frame, !frame.contains(anchor) { return refuse("the scroll anchor is outside the window") }
        let target = anchor ?? frame.map { CGPoint(x: $0.midX, y: $0.midY) }
        if let target { await buddy.travel(to: target) }
        let (pixels, steps) = plan.chunks(viewport: frame?.size ?? CGSize(width: 800, height: 600))
        for step in steps {
            if Task.isCancelled { return refuse("scroll interrupted; inspect the result before repeating input") }
            if let why = window?.staleness() { return refuse(why) }
            AXEngine.scroll(dy: step.dy, dx: step.dx, pixels: pixels, at: target, in: app)
            try? await Task.sleep(for: .milliseconds(70))
        }
        // Scrolling moves the real pointer to the aimed point; the run's end puts it back if the user doesn't.
        if !Background.active { cursorLeftAt = Buddy.mouse() }
        try? await Task.sleep(for: .milliseconds(200))
        return nil
    }

    /// Background scrolling of the pinned window: AX scroll-by-page actions on the scroll area under the
    /// anchor first (no events at all), otherwise wheel events posted to the app and tagged with the window.
    /// The real pointer, frontmost app and window order never change.
    private func backgroundScroll(_ plan: ScrollPlan, in app: NSRunningApplication, window: WindowSnapshot?, anchor: CGPoint?) async -> String? {
        guard let window, window.pid == app.processIdentifier else { return refuse("background scrolling needs the exact observed window; observe again") }
        if let why = window.staleness() { return refuse(why) }
        if let anchor, !window.frame.contains(anchor) { return refuse("the scroll anchor is outside the observed window; look again") }
        let target = anchor ?? CGPoint(x: window.frame.midX, y: window.frame.midY)
        if let why = hitCheck(target, pid: app.processIdentifier, window: window.element) { return refuse(why) }
        if plan.unit == .pages, let area = Self.scrollArea(at: target, pid: app.processIdentifier, window: window) {
            let action = Self.pageScrollAction(plan.direction)
            var names: CFArray?
            if AXUIElementCopyActionNames(area, &names) == .success, (names as? [String] ?? []).contains(action) {
                for _ in 0..<max(1, Int(plan.amount.rounded())) {
                    if Task.isCancelled { return refuse("scroll interrupted; inspect the result before repeating input") }
                    guard AXUIElementPerformAction(area, action as CFString) == .success else {
                        return refuse("the scroll area stopped accepting page actions; inspect before repeating")
                    }
                }
                lastMethod = "axscroll"
                return nil
            }
        }
        let (pixels, steps) = plan.chunks(viewport: window.frame.size)
        for step in steps {
            if Task.isCancelled { return refuse("scroll interrupted; inspect the result before repeating input") }
            if let why = window.staleness() { return refuse(why) }
            guard SkyLight.scroll(dy: step.dy, dx: step.dx, pixels: pixels, at: target, pid: app.processIdentifier, window: window.windowID) else {
                return refuse("couldn't construct a scroll event")
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        lastMethod = "pidwheel"
        return nil
    }

    nonisolated static func pageScrollAction(_ direction: ScrollPlan.Direction) -> String {
        switch direction {
        case .up: return "AXScrollUpByPage"
        case .down: return "AXScrollDownByPage"
        case .left: return "AXScrollLeftByPage"
        case .right: return "AXScrollRightByPage"
        }
    }

    /// The AXScrollArea of the observed window under `point` (walking up from the app-only hit test).
    private static func scrollArea(at point: CGPoint, pid: pid_t, window: WindowSnapshot) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &hit) == .success,
              var node = hit, window.containsElement(node) else { return nil }
        for _ in 0..<20 {
            if (axAttr(node, kAXRoleAttribute) as String?) == "AXScrollArea" { return node }
            guard let parent: AXUIElement = axAttr(node, kAXParentAttribute) else { return nil }
            node = parent
        }
        return nil
    }

    // MARK: - Native choose and secondary actions (Accessibility only; work behind the user's window)

    enum SemanticOutcome: Equatable { case done(String), uncertain(String), refused(String) }

    /// Picks `option` from a native pop-up button, combo box or menu button through Accessibility: open the
    /// control (AXPress / AXShowMenu), press the exactly matching AXMenuItem once, then read the value back.
    func choose(_ option: String, on el: UIElementInfo, in app: NSRunningApplication, window: WindowSnapshot) async -> SemanticOutcome {
        refusal = nil
        guard window.pid == app.processIdentifier, el.observationID == window.id, el.windowID == window.windowID else {
            return .refused(refuse("the control belongs to another observation; look again"))
        }
        if let why = window.staleness(includeContent: true) { return .refused(refuse(why)) }
        let control = el.element
        var names: CFArray?
        _ = AXUIElementCopyActionNames(control, &names)
        let actions = names as? [String] ?? []
        let opener = actions.contains("AXShowMenu") && el.role != "AXPopUpButton" ? "AXShowMenu" : kAXPressAction as String
        guard actions.contains(opener) else { return .refused(refuse("this control offers no Accessibility menu to choose from")) }
        buddy.click()
        guard AXUIElementPerformAction(control, opener as CFString) == .success else {
            return .uncertain("the menu may have opened; inspect before choosing again")
        }
        var items: [AXUIElement] = []
        for _ in 0..<15 where items.isEmpty {
            try? await Task.sleep(for: .milliseconds(40))
            items = Self.menuItems(under: control) ?? Self.menuItems(under: AXUIElementCreateApplication(app.processIdentifier)) ?? []
        }
        let titles = items.map { (Self.axAttr($0, kAXTitleAttribute) as String?) ?? "" }
        let wanted = option.trimmingCharacters(in: .whitespaces).lowercased()
        var hits = titles.indices.filter { titles[$0].lowercased() == wanted }
        if hits.isEmpty { hits = titles.indices.filter { titles[$0].lowercased().hasPrefix(wanted) } }
        guard hits.count == 1 else {
            _ = AXUIElementPerformAction(control, kAXCancelAction as CFString)
            let offered = titles.filter { !$0.isEmpty }.prefix(20).joined(separator: ", ")
            return .refused(refuse(hits.isEmpty ? "no “\(option)” in that menu; it has: \(offered)" : "“\(option)” matches several items; name one exactly"))
        }
        let item = items[hits[0]]
        guard (Self.axAttr(item, kAXEnabledAttribute) as Bool?) != false else {
            _ = AXUIElementPerformAction(control, kAXCancelAction as CFString)
            return .refused(refuse("“\(titles[hits[0]])” is disabled"))
        }
        switch AXUIElementPerformAction(item, kAXPressAction as CFString) {
        case .success: break
        default: return .uncertain("the choice may have been applied; inspect before choosing again")
        }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(40))
            let value = (Self.axAttr(control, kAXValueAttribute) as String?) ?? (Self.axAttr(control, kAXTitleAttribute) as String?) ?? ""
            if value.lowercased() == titles[hits[0]].lowercased() { return .done(titles[hits[0]]) }
        }
        return .uncertain("chose “\(titles[hits[0]])” once, but the control did not read it back")
    }

    /// Sets an element's AXValue once and reads it back (sliders, steppers, text fields, date pickers).
    func setValue(_ value: String, on el: UIElementInfo, window: WindowSnapshot) -> SemanticOutcome {
        refusal = nil
        guard el.observationID == window.id, el.windowID == window.windowID else { return .refused(refuse("the element belongs to another observation; look again")) }
        if let why = window.staleness(includeContent: true) { return .refused(refuse(why)) }
        guard !Safety.isSecureField(el.element), Safety.secureInputBlock() == nil else { return .refused(refuse("secure input is active; no value was set")) }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(el.element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else {
            return .refused(refuse("this element's value is not settable through Accessibility"))
        }
        let current: CFTypeRef? = Self.axAttr(el.element, kAXValueAttribute)
        let typed: CFTypeRef
        if current is NSNumber, let number = Double(value.trimmingCharacters(in: .whitespaces)) { typed = NSNumber(value: number) }
        else { typed = value as CFString }
        buddy.click()
        switch AXUIElementSetAttributeValue(el.element, kAXValueAttribute as CFString, typed) {
        case .success: break
        case .attributeUnsupported, .illegalArgument: return .refused(refuse("the element rejected that value"))
        default: return .uncertain("the value may have been set; read it before trying again")
        }
        let now: CFTypeRef? = Self.axAttr(el.element, kAXValueAttribute)
        if let now, CFEqual(now, typed) { return .done(value) }
        if let text = now as? String, typed is String, TextReadback.matches(expected: value, actual: text) { return .done(value) }
        if let n = now as? NSNumber, let want = typed as? NSNumber, abs(n.doubleValue - want.doubleValue) < 1e-6 { return .done(value) }
        return .uncertain("the value was set once but did not read back exactly")
    }

    /// Open menu items below `root` (breadth-first, bounded). nil when no open AXMenu is found.
    private static func menuItems(under root: AXUIElement) -> [AXUIElement]? {
        var queue: [(AXUIElement, Int)] = [(root, 0)], head = 0
        while head < queue.count, head < 400 {
            let (node, depth) = queue[head]; head += 1
            let role: String? = Self.axAttr(node, kAXRoleAttribute)
            if role == "AXMenu" {
                let items = ((Self.axAttr(node, kAXChildrenAttribute) as [AXUIElement]?) ?? [])
                    .filter { (Self.axAttr($0, kAXRoleAttribute) as String?) == "AXMenuItem" }
                if !items.isEmpty { return items }
            }
            // Never walk into the menu bar: its items are not this control's popup.
            if depth < 4, role != "AXMenuBar" {
                queue.append(contentsOf: ((axAttr(node, kAXChildrenAttribute) as [AXUIElement]?) ?? []).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    /// Performs one advertised non-press AX action (AXShowMenu, AXIncrement, AXPick, …) on an element of the
    /// observed window. Delivered once; a timeout is uncertainty, never a reason to repeat it.
    func performSecondaryAction(_ name: String, on el: UIElementInfo, window: WindowSnapshot) -> SemanticOutcome {
        refusal = nil
        guard el.observationID == window.id, el.windowID == window.windowID else { return .refused(refuse("the element belongs to another observation; look again")) }
        if let why = window.staleness(includeContent: true) { return .refused(refuse(why)) }
        var names: CFArray?
        guard AXUIElementCopyActionNames(el.element, &names) == .success, (names as? [String] ?? []).contains(name),
              !BackgroundPolicy.secondaryActionDenylist.contains(name) else {
            return .refused(refuse("\(name) is not one of this element's secondary actions"))
        }
        buddy.click()
        switch AXUIElementPerformAction(el.element, name as CFString) {
        case .success: return .done(name)
        case .actionUnsupported: return .refused(refuse("the element rejected \(name)"))
        default: return .uncertain("\(name) may have been applied; inspect before repeating it")
        }
    }

    // MARK: - Click options

    /// A pixel click with the requested button, count, modifiers and hold, after the same window and hit checks as
    /// every other click. AXPress cannot express any of these, so it is never used here.
    @discardableResult
    func click(at point: CGPoint, options: ClickOptions, pid: pid_t, window: WindowSnapshot) async -> String? {
        guard pid == window.pid, window.frame.contains(point) else { return refuse("the point is outside the observed target window; look again") }
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        if let why = hitCheck(point, pid: pid, window: window.element) { return refuse(why) }
        if Background.active {
            guard Self.skyCompatible(options) else { return refuse("modifier, hold, middle-button and triple-click options need foreground mode") }
            buddy.click()
            lastMethod = "background"
            return backgroundClick(at: point, pid: pid, window: window, button: options.button == .right ? .right : .left, count: options.count)
        }
        await buddy.travel(to: point)
        try? await Task.sleep(for: .milliseconds(80))
        if let why = window.staleness(includeContent: true) { return refuse(why) }
        if let why = hitCheck(point, pid: pid, window: window.element) { return refuse(why) }
        buddy.click()
        let saved = Self.exactPointer()
        let source = CGEventSource(stateID: .hidSystemState)
        var flags: CGEventFlags = []
        if options.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if options.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if options.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if options.modifiers.contains(.control) { flags.insert(.maskControl) }
        let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) = {
            switch options.button {
            case .left: return (.leftMouseDown, .leftMouseUp, .left)
            case .right: return (.rightMouseDown, .rightMouseUp, .right)
            case .middle: return (.otherMouseDown, .otherMouseUp, .center)
            }
        }()
        func post(_ type: CGEventType, state: Int) {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
            e.flags = flags
            e.setIntegerValueField(.mouseEventClickState, value: Int64(state))
            e.post(tap: .cghidEventTap)
        }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        var held = false
        defer {
            if held { post(upType, state: 1) }
            // Make sure no modifier stays latched, then give the pointer back (exactly, fractions included).
            Self.restorePointer(saved)
            cursorLeftAt = nil
        }
        for step in options.steps {
            if step.down {
                held = true
                post(downType, state: step.clickState)
                if options.holdMilliseconds > 0 {
                    try? await Task.sleep(for: .milliseconds(options.holdMilliseconds))
                    if Task.isCancelled { return refuse("click interrupted; inspect the result before repeating input") }
                } else { usleep(15_000) }
            } else {
                post(upType, state: step.clickState)
                held = false
                usleep(30_000)
            }
        }
        lastMethod = "options"
        return nil
    }

    // MARK: - Screenshot insertion

    struct SnapPasteReport {
        /// Indices (into the items given) whose caption and picture were both delivered without interruption.
        var inserted: [Int] = []
        /// An item whose caption went in but whose picture did not (so the document holds a lone caption).
        var partial: Int?
        var stopped: String?
    }

    /// Pastes each caption and then its picture at the caret, counting only items delivered start to finish. Delivery is
    /// keystrokes plus the clipboard: apps like Google Docs do not let Clinqy read the result back, so "inserted"
    /// means delivered while the target stayed frontmost and the clipboard stayed ours, not independently seen.
    func pasteSnaps(_ items: [(caption: String, png: Data)], in app: NSRunningApplication) async -> SnapPasteReport {
        var report = SnapPasteReport()
        let board = NSPasteboard.general
        let saved = PasteboardSnapshot(board)
        var owned = board.changeCount
        AXEngine.targetPid = app.processIdentifier
        defer {
            AXEngine.targetPid = nil
            saved.restore(to: board, ifUnchangedSince: owned)
        }
        func ready() -> String? {
            if Task.isCancelled { return "the run was cancelled" }
            if !Background.active, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                return "\(app.cleanName ?? "the target app") is no longer in front"
            }
            if board.changeCount != owned { return "the clipboard changed while pasting (the user may have copied something)" }
            return nil
        }
        func load(_ write: (NSPasteboard) -> Void) {
            board.clearContents()
            write(board)
            owned = board.changeCount
        }
        for (i, item) in items.enumerated() {
            if let why = ready() { report.stopped = why; return report }
            load { $0.setString(item.caption, forType: .string) }
            AXEngine.pressPaste()
            try? await Task.sleep(for: .milliseconds(250))
            AXEngine.pressReturn()
            if let why = ready() { report.partial = i; report.stopped = why; return report }
            load { $0.setData(item.png, forType: .png) }
            AXEngine.pressPaste()
            try? await Task.sleep(for: .milliseconds(1800))   // Google Docs uploads the image
            AXEngine.pressReturn()
            AXEngine.pressReturn()
            try? await Task.sleep(for: .milliseconds(150))
            report.inserted.append(i)
        }
        return report
    }

    // MARK: - Control state

    /// Sets a checkbox, radio button or range control to the requested state, confirming it by reading it back.
    func setState(_ el: UIElementInfo, to desired: DesiredState, in app: NSRunningApplication, window requested: WindowSnapshot? = nil) async -> AXEngine.StateOutcome {
        guard let window = requested ?? WindowSnapshot.capture(app), window.pid == app.processIdentifier,
              el.windowID == nil || el.windowID == window.windowID,
              requested.map({ el.observationID == $0.id }) ?? true else { return .refused("the control belongs to another observation; look again") }
        if let why = window.staleness(includeContent: true) { return .refused(why) }
        await buddy.travel(to: el.center, framing: el.frame)
        if let why = window.staleness(includeContent: true) { return .refused(why) }
        buddy.click()
        let element = el.element
        return await Task.detached { AXEngine.setState(element, to: desired) }.value
    }

    /// Applies a formatting toggle to the current selection of the exact pinned window through the app's own menu
    /// item (Format ▸ Font ▸ Bold), pressed while that window is the target's synthetic key window. A toolbar
    /// toggle pressed while the window isn't key changes only the toggle: its nil-targeted action reaches no text.
    /// Never activates or raises anything. The caller verifies the text's own formatting afterwards.
    func applyFormattingInBackground(_ style: TextFormatting.Style, in app: NSRunningApplication, window: WindowSnapshot) async -> AXEngine.StateOutcome {
        guard window.pid == app.processIdentifier, !Task.isCancelled else { return .refused("the formatting target changed; look again") }
        if let why = window.staleness() { return .refused(why) }
        guard let item = await Task.detached(operation: { AXEngine.formattingMenuItem(style, in: app) }).value else {
            return .unsupported("\(app.cleanName ?? "the app") has no single enabled \(TextFormatting.menuTitle(for: style)) menu item to apply it in the background")
        }
        if let why = Safety.secureInputBlock() { return .refused(why) }
        let session: SkyLight.KeyboardSession
        switch SkyLight.beginKeyboard(in: window) {
        case .failure(let error): return .refused(error.reason)
        case .success(let value): session = value
        }
        let delivery = AXEngine.axPressDelivery(item)
        guard session.finish() else { return .unverified("the formatting may have been applied, but temporary focus cleanup failed") }
        switch delivery {
        case .delivered: buddy.click(); return .changed
        case .uncertain: return .unverified("the \(TextFormatting.menuTitle(for: style)) menu item was pressed but the app did not confirm")
        case .unsupported: return .unsupported("the \(TextFormatting.menuTitle(for: style)) menu item can't be pressed through Accessibility")
        }
    }

    // MARK: - Text placement

    /// Inserts or appends text at the real caret instead of replacing the field. Where the field gives Accessibility
    /// no caret or settable text, says so rather than falling back to select-all-and-replace.
    func place(_ text: String, mode: TextEditMode, in app: NSRunningApplication) -> AXEngine.EditOutcome {
        refusal = nil
        guard mode != .replaceAll else { return .unsupported("replace is what type already does") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let field = focused, CFGetTypeID(field) == AXUIElementGetTypeID() else { return .refused("no focused field") }
        if let why = Safety.secureInputBlock() { _ = refuse(why); return .refused(why) }
        let outcome = AXEngine.edit(text, mode: mode, field: field as! AXUIElement)
        if case .refused(let why) = outcome { _ = refuse(why) }
        return outcome
    }

    // MARK: - Keyboard

    /// Replaces exactly one verified focused field. Once a mutation is dispatched, a missing readback
    /// is uncertainty, never permission to clear, paste again, or append a second copy.
    /// The last `type` went into a field that can't be read back: delivered, but not confirmed by readback.
    private(set) var unreadableEntry = false

    /// `target`: the field `focus` just verified (by id); its focus is re-checked the same way (app focus, or in the
    /// background the pinned window's focused element). Without it, the app's focused text field in the window.
    func type(_ text: String, in app: NSRunningApplication, window requested: WindowSnapshot? = nil, target: AXUIElement? = nil) async -> Bool {
        refusal = nil
        unreadableEntry = false
        guard !Task.isCancelled,
              let window = requested ?? WindowSnapshot.capture(app, windowID: Background.active ? Background.nativeWindowID : nil, followAttachedSheet: true),
              window.pid == app.processIdentifier, window.staleness(includeContent: true) == nil else {
            _ = refuse("the text target is unavailable; observe again"); return false
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let appFocused: AXUIElement? = AXEngine.attribute(root, kAXFocusedUIElementAttribute)
        let candidate: AXUIElement?
        if let target, Self.focusHeld(target, in: app, window: window.element, focusSet: true) {
            // The app's focused element when it is the target or inside it; else the target the window reports.
            candidate = appFocused.flatMap { [.target, .inside].contains(Self.focusRelation($0, to: target)) ? $0 : nil } ?? target
        } else { candidate = target == nil ? appFocused : nil }
        guard let field = candidate, window.containsElement(field), Self.isTextRole(AXEngine.attribute(field, kAXRoleAttribute)) else {
            _ = refuse("no verified text field in the observed window"); return false
        }
        let holds = { Self.focusHeld(field, in: app, window: window.element, focusSet: target != nil) }
        guard !Safety.isSecureField(field), Safety.secureInputBlock() == nil else {
            _ = refuse("secure input is active; no text was sent"); return false
        }
        buddy.setTyping(true)
        defer { buddy.setTyping(false) }
        guard window.staleness(includeContent: true) == nil, holds(), !Task.isCancelled else {
            _ = refuse("the target changed before text delivery; observe again"); return false
        }
        switch AXEngine.edit(text, mode: .replaceAll, field: field) {
        case .done: return true
        case .refused(let why), .unverified(let why): _ = refuse(why); return false
        case .unsupported: break
        }
        let readable: String? = AXEngine.attribute(field, kAXValueAttribute)
        let count: Int? = (AXEngine.attribute(field, kAXNumberOfCharactersAttribute) as NSNumber?)?.intValue
        let plan = BackgroundPolicy.textEntryPlan(value: readable, characterCount: count)
        if case .refuse(let why) = plan { _ = refuse(why); return false }
        let before = readable ?? ""
        guard window.staleness() == nil, holds() else {
            _ = refuse("the field changed before typing; observe again"); return false
        }
        let keyboard: SkyLight.KeyboardSession
        switch SkyLight.beginKeyboard(in: window) {
        case .success(let session): keyboard = session
        case .failure(let error): _ = refuse(error.reason); return false
        }
        defer { if !keyboard.finish() { _ = refuse("text may have been delivered, but temporary keyboard state could not be released") } }
        if !before.isEmpty {
            guard case .delivered = AXEngine.press(combo: "cmd+a", in: app, window: window) else {
                _ = refuse("select-all was not confirmed; no replacement text was sent"); return false
            }
            try? await Task.sleep(for: .milliseconds(60))
            // A menu shortcut can be accepted without selecting this field. Do not overwrite until its
            // selection is visible, including UTF-16 length for emoji and non-Latin text.
            guard AXEngine.selection(of: field) == NSRange(location: 0, length: (before as NSString).length) else {
                _ = refuse("the field did not confirm select-all; no replacement text was sent"); return false
            }
        }
        let characters = Array(text)
        for offset in stride(from: 0, to: characters.count, by: 16) {
            let chunk = String(characters[offset..<min(characters.count, offset + 16)])
            guard !Task.isCancelled, window.staleness() == nil, holds(),
                  !Safety.isSecureField(field), Safety.secureInputBlock() == nil else {
                _ = refuse("typing stopped after partial delivery; inspect the field before continuing"); return false
            }
            AXEngine.type(chunk, to: app.processIdentifier)
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Empty replacement still needs one edit when the AX value setter is unavailable.
        if text.isEmpty, !before.isEmpty { _ = AXEngine.press(combo: "backspace", in: app, window: window) }
        if readable == nil {
            // Nothing to read back: delivered keystrokes are reported as such, never as a confirmed value.
            guard keyboard.finish() else { _ = refuse("text may have been delivered, but temporary keyboard state could not be released"); return false }
            unreadableEntry = true
            return true
        }
        for _ in 0..<10 {
            guard !Task.isCancelled else { _ = refuse("typing interrupted; inspect the existing text before continuing"); return false }
            if (AXEngine.attribute(field, kAXValueAttribute) as String?) == text {
                guard keyboard.finish() else { _ = refuse("text matches, but temporary keyboard state could not be released"); return false }
                return true
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        _ = refuse("text was sent once but exact readback was not confirmed; inspect before retrying")
        return false
    }

    /// Apps whose editors auto-indent what's typed.
    static let codeEditorIDs: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.sublimetext.4", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.google.android.studio",
    ]

    /// Enters text into the focused field, always typed so it can be watched.
    /// Line breaks are Shift+Return (a new line without sending in chat apps). In code editors, which re-indent
    /// typed code, each line is typed without its leading spaces and the exact code is swapped in at the end.
    func enterText(_ text: String, codeEditor: Bool = false) async {
        // A long program typed key by key takes half a minute (and trips the watchdog), only to be replaced by the
        // exact paste at the end anyway: paste it straight in.
        if codeEditor, text.count > 300 {
            AXEngine.selectAll()
            try? await Task.sleep(for: .milliseconds(60))
            AXEngine.paste(text)
            try? await Task.sleep(for: .milliseconds(250))
            return
        }
        guard text.contains("\n") else { return await keystrokes(text) }
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if Task.isCancelled { return }
            if i > 0 {
                AXEngine.press(combo: "shift+return")
                try? await Task.sleep(for: .milliseconds(60))
            }
            await keystrokes(codeEditor ? line.trimmingCharacters(in: .whitespaces) : line)
        }
        if codeEditor {
            // The editor's auto-indent and auto-closing brackets have had their say; now make it exactly right.
            try? await Task.sleep(for: .milliseconds(200))
            AXEngine.selectAll()
            try? await Task.sleep(for: .milliseconds(60))
            AXEngine.paste(text)
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Types at a human rhythm (keys go wherever AXEngine.targetPid points). Stops, with `refusal` set, the moment
    /// a password field takes secure input: focus can move mid-word.
    func keystrokes(_ text: String) async {
        let base = text.count > 80 ? 10.0 : text.count > 30 ? 20.0 : 32.0
        refusal = nil
        for ch in text {
            if Task.isCancelled { return }
            if let why = Safety.secureInputBlock() { _ = refuse(why); return }
            AXEngine.type(String(ch))
            var ms = base + Double.random(in: 0...(base * 0.9))
            if ch == " " { ms += base * 0.5 }
            if ".,!?".contains(ch) { ms += 70 }
            try? await Task.sleep(for: .milliseconds(Int(ms)))
        }
    }

    private func landed(_ text: String, in app: NSRunningApplication) async -> Bool {
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(70))
            if AXEngine.fieldHolds(text, in: app) { return true }
        }
        return false
    }

    // MARK: - Apps

    /// Opens an app like a person: click its Dock icon, or use Spotlight if it isn't in the Dock.
    func openApp(named name: String) async -> NSRunningApplication? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let running = Launcher.running(named: wanted)
        let url = running?.bundleURL ?? Launcher.find(named: wanted)
        guard let url else { return nil }
        let appName = url.deletingPathExtension().lastPathComponent

        if let running, NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier,
           AXEngine.windowFrame(of: running) != nil {
            return running
        }
        // In a background run the app opens behind the user's (no Dock click, no Spotlight).
        if Background.active { return await Launcher.launch(url) }
        if !Efficiency.humanMotion { return await Launcher.launch(url) }

        trace("openApp \(appName) dock=\(AXEngine.dockItem(named: appName) != nil)")
        if let dock = AXEngine.dockItem(named: appName) {
            await buddy.travel(to: CGPoint(x: dock.frame.midX, y: dock.frame.midY), framing: dock.frame)
            try? await Task.sleep(for: .milliseconds(140))
            buddy.click()
            let item = dock.element
            _ = await Task.detached { AXEngine.axPress(item) }.value
        } else {
            await spotlight(appName)
        }
        if let app = await waitForFront(bundleURL: url, seconds: 5) { return app }
        return await Launcher.launch(url)
    }

    private func spotlight(_ query: String) async {
        // Typing blind into a password prompt is worse than launching the app directly (the caller falls back).
        guard Safety.secureInputBlock() == nil else { return }
        let screen = NSScreen.main?.frame ?? .zero
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let spot = CGPoint(x: screen.midX - 180, y: primaryHeight - screen.maxY + screen.height * 0.3)
        await buddy.travel(to: spot)
        press("cmd+space")
        try? await Task.sleep(for: .milliseconds(450))
        buddy.setTyping(true)
        for ch in query {
            AXEngine.type(String(ch))
            try? await Task.sleep(for: .milliseconds(Int.random(in: 45...95)))
        }
        buddy.setTyping(false)
        try? await Task.sleep(for: .milliseconds(550))
        press("return")
    }

    private func waitForFront(bundleURL: URL, seconds: Double) async -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleURL == bundleURL {
                // Give it a moment to put a window up.
                for _ in 0..<20 where AXEngine.windowFrame(of: front) == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if AXEngine.windowFrame(of: front) == nil { return nil }
                return front
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }

    // MARK: - Web

    /// Goes to a website like a person: bring up the browser, open a tab, type the address, press Return.
    func openURL(_ url: URL, current: NSRunningApplication?, newTab: Bool = true) async -> NSRunningApplication? {
        // A background run without the extension: hand the address to the browser, which opens it without coming
        // forward. Typing it would send ⌘T and the address to whichever of its windows the user has.
        if Background.active {
            await Launcher.openURL(url)
            let id = NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
            return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id && id != nil }
        }
        var browser: NSRunningApplication?
        if let current, Launcher.isBrowser(current) {
            await Launcher.bringToFront(current)
            browser = current
        } else if let name = Launcher.defaultBrowserName {
            browser = await openApp(named: name)
        }
        guard let browser else {
            await Launcher.openURL(url)
            return NSWorkspace.shared.frontmostApplication
        }

        if !Efficiency.humanMotion {
            let bridge = BrowserBridge.shared
            if bridge.isConnected(browser), let tab = await bridge.activeTab(in: browser),
               await bridge.tabCommand(newTab ? "newTab" : "navigate", on: tab, ["url": url.absoluteString]) != nil {
                return browser
            }
            if newTab, let bundle = browser.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                if let opened = try? await NSWorkspace.shared.open([url], withApplicationAt: bundle, configuration: configuration) { return opened }
            }
        }

        trace("browser \(browser.cleanName ?? "?") front=\(NSWorkspace.shared.frontmostApplication?.cleanName ?? "-")")
        // A new tab for a fresh destination; otherwise edit the current tab's address like a person would.
        press(newTab ? "cmd+t" : "cmd+l")
        try? await Task.sleep(for: .milliseconds(420))
        trace("after cmd+t focused=\(AXEngine.focusedFrame(of: browser).map { "\($0)" } ?? "nil")")
        // Go to where the address goes: the focused field if it's plausibly the address bar (top of the
        // window), otherwise Arc's command bar in the upper middle, or the usual toolbar spot.
        let window = AXEngine.windowFrame(of: browser)
        if let field = AXEngine.focusedFrame(of: browser), field.width > 40,
           let window, field.midY < window.minY + window.height * 0.4 {
            await buddy.travel(to: CGPoint(x: field.minX + min(80, field.width / 2), y: field.midY), framing: field)
        } else if let window {
            let arc = browser.bundleIdentifier == "company.thebrowser.Browser"
            await buddy.travel(to: CGPoint(x: window.midX - (arc ? 200 : 0), y: window.minY + (arc ? window.height * 0.3 : 44)))
        }

        trace("traveled; front=\(NSWorkspace.shared.frontmostApplication?.cleanName ?? "-")")
        var address = url.absoluteString
        for prefix in ["https://www.", "https://", "http://"] where address.hasPrefix(prefix) {
            address = String(address.dropFirst(prefix.count))
            break
        }
        if address.hasSuffix("/") { address.removeLast() }
        if Safety.secureInputBlock() != nil {
            press("esc")
            await Launcher.openURL(url)
            return browser
        }
        buddy.setTyping(true)
        // Deliver keys straight to the browser so they can't land in some other window.
        AXEngine.targetPid = browser.processIdentifier
        if Efficiency.humanMotion {
            for ch in address {
                guard !Task.isCancelled else { break }
                AXEngine.type(String(ch))
                try? await Task.sleep(for: .milliseconds(Int.random(in: 22...60)))
            }
        } else { AXEngine.type(address) }
        AXEngine.targetPid = nil
        buddy.setTyping(false)
        try? await Task.sleep(for: .milliseconds(150))
        let value = AXEngine.focusedValue(of: browser) ?? ""
        trace("typed; focused value=\(value.debugDescription)")

        // If the keys went astray, fill the field directly; failing that, open the tab through the browser.
        // Arc's command bar reports an empty value even when the text is there, so only a readable
        // mismatch counts as a miss.
        if !value.isEmpty, !value.lowercased().contains(address.prefix(6).lowercased()) {
            if AXEngine.setFocusedValue(address, in: browser),
               (AXEngine.focusedValue(of: browser) ?? "").lowercased().contains(address.prefix(6).lowercased()) {
                trace("filled field via accessibility")
            } else {
                trace("falling back to opening the URL directly")
                AXEngine.press(combo: "esc")
                try? await Task.sleep(for: .milliseconds(150))
                await Launcher.openURL(url)
                try? await Task.sleep(for: .milliseconds(900))
                return browser
            }
        }
        try? await Task.sleep(for: .milliseconds(200))
        press("return")
        // Wait for the page to start loading rather than a fixed pause.
        let startURL = Launcher.frontURLHint
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(100))
            if Launcher.frontURLHint != startURL { break }
        }
        try? await Task.sleep(for: .milliseconds(250))
        trace("returned")
        return browser
    }
}

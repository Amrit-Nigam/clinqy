import AppKit
import CoreGraphics

/// Background input and capture through private SkyLight, for windows that ignore a plain postToPid event
/// (Chromium/Electron/Catalyst hit-test against WindowServer's active window). Recipes from Cua Driver, yabai
/// and open-codex-computer-use (MIT; THIRD_PARTY_NOTICES.md). Undocumented ABI: every symbol is resolved with
/// dlsym at load, and each capability (input, capture, occlusion keep-alive) is fully off if any of its symbols
/// is missing rather than half-posting a sequence.
///
/// Focus rule: synthetic activation and key-window records go to the TARGET process only. Nothing is ever
/// posted to the real frontmost app, so it never resigns active/key (verified by tests/focus-intrusion-probe.sh).
enum SkyLight {
    private typealias PostToPid = @convention(c) (pid_t, UnsafeMutableRawPointer?) -> Void
    private typealias SetIntField = @convention(c) (UnsafeMutableRawPointer?, UInt32, Int64) -> Void
    private typealias SetWindowLocation = @convention(c) (UnsafeMutableRawPointer?, Double, Double) -> Void
    private typealias PostRecord = @convention(c) (UnsafeRawPointer?, UnsafePointer<UInt8>?) -> Int32
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer?) -> Int32

    private struct Symbols {
        let postToPid: PostToPid
        let setIntField: SetIntField
        let setWindowLocation: SetWindowLocation
        let postRecord: PostRecord
        let processForPID: ProcessForPID
    }

    private static let skyHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let servicesHandle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let symbols: Symbols? = {
        guard let postToPid: PostToPid = sym(skyHandle, "SLEventPostToPid"),
              let setIntField: SetIntField = sym(skyHandle, "SLEventSetIntegerValueField"),
              let setWindowLocation: SetWindowLocation = sym(skyHandle, "CGEventSetWindowLocation"),
              let postRecord: PostRecord = sym(skyHandle, "SLPSPostEventRecordTo"),
              let processForPID: ProcessForPID = sym(servicesHandle, "GetProcessForPID") else { return nil }
        return Symbols(postToPid: postToPid, setIntField: setIntField, setWindowLocation: setWindowLocation,
                       postRecord: postRecord, processForPID: processForPID)
    }()

    static var isEnabled: Bool { Config.value("BACKGROUND_CLICKS") == "1" && symbols != nil }
    /// This macOS has every symbol the background input path needs.
    static var isAvailable: Bool { symbols != nil }

    /// Calibrated gaps (env/config tunable; see NativeInputTiming). Read once per operation.
    static var timing: NativeInputTiming { NativeInputTiming.parse(Config.value) }
    /// The native lane's kill switch (BACKGROUND_NATIVE=0). On by default.
    static var nativeEnabled: Bool { NativeInputTiming.nativeEnabled(Config.value("BACKGROUND_NATIVE")) }

    private static func windowExists(_ id: CGWindowID) -> Bool {
        !((CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]) ?? []).isEmpty
            || ((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? [])
                .contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
    }

    // MARK: - Backing-store capture (primary for native windows)

    private typealias MainConnection = @convention(c) () -> UInt32
    private typealias HardwareCapture = @convention(c) (UInt32, UnsafePointer<CGWindowID>, Int32, UInt32) -> Unmanaged<CFArray>?
    private static let mainConnection: MainConnection? = sym(skyHandle, "SLSMainConnectionID")
    private static let hardwareCapture: HardwareCapture? = sym(skyHandle, "SLSHWCaptureWindowList")
    static var canCapture: Bool { mainConnection != nil && hardwareCapture != nil }

    /// WindowServer reads the exact window's backing store (15–45 ms; covered windows and other Spaces work).
    /// Never bypasses Screen Recording permission. The caller owns identity/staleness checks around it.
    /// 0x800 ignores the global clip shape (OCU SkyLightSPI.hardwareCaptureWindow).
    static func capture(_ window: NativeWindowObservation) -> CGImage? {
        guard nativeEnabled, CGPreflightScreenCaptureAccess(),
              let mainConnection, let hardwareCapture else { return nil }
        var id = window.windowID
        guard let images = hardwareCapture(mainConnection(), &id, 1, 0x800)?.takeRetainedValue(), CFArrayGetCount(images) == 1,
              let pointer = CFArrayGetValueAtIndex(images, 0) else { return nil }
        let object = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        guard CFGetTypeID(object) == CGImage.typeID else { return nil }
        let image = unsafeBitCast(object, to: CGImage.self)
        guard image.width > 0, image.height > 0 else { return nil }
        // Reject backing stores with unexpected decoration/crop before coordinates are mapped to them.
        let ratio = Double(image.width) / Double(image.height)
        let wanted = Double(window.frame.width / window.frame.height)
        guard abs(ratio - wanted) <= max(0.005, wanted * 0.005) else { return nil }
        return image
    }

    // MARK: - Occlusion keep-alive

    /// (cid, wid, enable, previousStateOut) — ABI per OCU's macOS 27 disassembly; the out pointer is optional.
    private typealias EnableOcclusion = @convention(c) (UInt32, CGWindowID, UInt8, UnsafeMutablePointer<UInt8>?) -> Int32
    private static let enableOcclusion: EnableOcclusion? = sym(skyHandle, "SLSPackagesEnableWindowOcclusionNotifications")
    private static let keepAliveLock = NSLock()
    /// Pinned window → its prior state and the runs relying on it; a window is restored only when its last run ends.
    nonisolated(unsafe) private static var pinnedWindows: [CGWindowID: (previous: Bool, owners: Set<UInt>)] = [:]
    nonisolated(unsafe) private static var exitHookInstalled = false
    nonisolated(unsafe) private static var manualAccessibilityPIDs: Set<pid_t> = []

    /// Keeps a driven window rendering after it is covered: disabling its occlusion notifications pins the
    /// app's notion at "visible". Only applied while the window is still unoccluded (pinning an occluded window
    /// would freeze it hidden). Never activates, raises or moves anything. Restored by `releaseKeepAlive`.
    /// The run a keep-alive belongs to: the isolated task's execution context, or 0 for the main agent.
    static var keepAliveOwner: UInt { TaskExecution.current.map { UInt(bitPattern: ObjectIdentifier($0)) } ?? 0 }

    @discardableResult
    static func keepVisible(_ window: NativeWindowObservation, owner: UInt = keepAliveOwner) -> Bool {
        guard nativeEnabled, Config.value("SKY_OCCLUSION_KEEPALIVE") != "0",
              let mainConnection, let enableOcclusion else { return false }
        keepAliveLock.lock()
        defer { keepAliveLock.unlock() }
        if pinnedWindows[window.windowID] != nil { pinnedWindows[window.windowID]?.owners.insert(owner); return true }
        let above = (CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], window.windowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowLayer as String] as? Int ?? 0) >= 0 && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
        guard NativeWindowVisibility.looksUnoccluded(bounds: window.frame, covering: above) else { return false }
        // Enabled unless the call reports otherwise: if the (reverse-engineered) out-parameter is never written,
        // restoring must turn notifications back on, never leave them off for good.
        var previous: UInt8 = 1
        guard enableOcclusion(mainConnection(), window.windowID, 0, &previous) == 0 else { return false }
        pinnedWindows[window.windowID] = (previous != 0, [owner])
        if !exitHookInstalled {
            exitHookInstalled = true
            atexit { SkyLight.releaseKeepAlive(owner: nil) }
        }
        // Electron builds its web AX tree only for assistive clients; ask once per process (ignored elsewhere).
        if !manualAccessibilityPIDs.contains(window.pid) {
            manualAccessibilityPIDs.insert(window.pid)
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(window.pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return true
    }

    static func isKeptVisible(_ windowID: CGWindowID) -> Bool {
        keepAliveLock.lock(); defer { keepAliveLock.unlock() }
        return pinnedWindows[windowID] != nil
    }

    /// Restores the prior occlusion-notification state of the windows `owner`'s run pinned (run end, cancellation),
    /// unless another run still relies on one; nil (process exit) restores every window. Failed restorations stay
    /// recorded so a later call retries them.
    static func releaseKeepAlive(owner: UInt? = keepAliveOwner) {
        keepAliveLock.lock()
        defer { keepAliveLock.unlock() }
        if let owner {
            for id in pinnedWindows.keys { pinnedWindows[id]?.owners.remove(owner) }
        }
        guard let mainConnection, let enableOcclusion else {
            pinnedWindows = pinnedWindows.filter { owner != nil && !$0.value.owners.isEmpty }; return
        }
        for (id, pin) in pinnedWindows where owner == nil || pin.owners.isEmpty {
            var ignored: UInt8 = 0
            let status = enableOcclusion(mainConnection(), id, pin.previous ? 1 : 0, &ignored)
            // A window that has since closed cannot be restored and needs nothing.
            if status == 0 || !windowExists(id) { pinnedWindows.removeValue(forKey: id) }
        }
        manualAccessibilityPIDs.removeAll()
    }

    // MARK: - Synthetic target focus

    /// Private CGEvent fields the Chromium-compatible path sets.
    private enum Field {
        static let gesturePhase: UInt32 = 0, clickState: UInt32 = 1, buttonNumber: UInt32 = 3, subtype: UInt32 = 7
        static let targetPID: UInt32 = 40, windowNumber: UInt32 = 51, clickGroupID: UInt32 = 58
        static let windowUnderPointer: UInt32 = 91, handlingWindowUnderPointer: UInt32 = 92
    }

    /// Focus/defocus record for SLPSPostEventRecordTo. Posted to the target PSN only: it gives the target a
    /// synthetic active state without touching the real frontmost app (defocusing that would fire resignKey).
    static func activationRecord(window: CGWindowID, focused: Bool) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 0xF8)
        r[0x04] = 0xF8
        r[0x08] = 0x0D
        for i in 0..<4 { r[0x3C + i] = UInt8(truncatingIfNeeded: window >> (8 * UInt32(i))) }
        r[0x8A] = focused ? 0x01 : 0x02
        return r
    }

    private static func activate(_ s: Symbols, psn: [UInt8], window: CGWindowID, focused: Bool) -> Bool {
        let record = activationRecord(window: window, focused: focused)
        let ok = psn.withUnsafeBytes { p in record.withUnsafeBufferPointer { s.postRecord(p.baseAddress, $0.baseAddress) } } == 0
        // Records and CGEvents travel different channels with no ordering guarantee.
        let settle = timing.focusSettleMicros
        if ok, settle > 0 { usleep(settle) }
        return ok
    }

    private static func psn(for pid: pid_t, _ s: Symbols) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 8)
        return out.withUnsafeMutableBytes({ s.processForPID(pid, $0.baseAddress) }) == 0 ? out : nil
    }

    /// Legacy callers only check capability. Synthetic state is scoped to an input operation,
    /// never left active by app selection or observation.
    @discardableResult
    static func focus(pid: pid_t, window: CGWindowID) -> Bool {
        guard symbols != nil, let app = NSRunningApplication(processIdentifier: pid), !app.isHidden else { return false }
        return NativeWindowObservation.capture(app, windowID: window) != nil
    }

    /// Derived record layout: yabai window_manager_make_key_window and OCU SkyLightSPI.
    static func keyWindowRecords(_ window: CGWindowID) -> [[UInt8]] {
        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8
        record[0x3A] = 0x10
        for i in 0..<4 { record[0x3C + i] = UInt8(truncatingIfNeeded: window >> (8 * UInt32(i))) }
        for i in 0x20..<0x30 { record[i] = 0xFF }
        return [UInt8(1), UInt8(2)].map { kind in
            var value = record
            value[0x08] = kind
            return value
        }
    }

    private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var activeKeyboard: UUID?
    private struct PendingCleanup { let id: UUID; let window: NativeWindowObservation; let psn: [UInt8] }
    nonisolated(unsafe) private static var pendingCleanup: PendingCleanup?

    /// Failed cleanup retains input ownership. A later attempt must release it before sending new input.
    @discardableResult
    static func retryPendingCleanup() -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard let pending = pendingCleanup else { return true }
        let gone = !AXEngine.isSameProcess(pending.window.identity)
        guard gone || symbols.map({ activate($0, psn: pending.psn, window: pending.window.windowID, focused: false) }) == true else { return false }
        pendingCleanup = nil
        if activeKeyboard == pending.id { activeKeyboard = nil }
        return true
    }

    final class KeyboardSession {
        let id: UUID
        let window: NativeWindowObservation
        fileprivate let psn: [UInt8]?
        private let lock = NSLock()
        private var closed = false
        private var restorationSucceeded = true

        fileprivate init(id: UUID, window: NativeWindowObservation, psn: [UInt8]?) {
            self.id = id; self.window = window; self.psn = psn
        }

        /// Always releases target-only state, including cancellation and partial delivery.
        @discardableResult
        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return restorationSucceeded }
            closed = true
            var restored = true
            if let psn, let s = SkyLight.symbols, AXEngine.isSameProcess(window.identity) {
                let release = SkyLight.timing.keyReleaseMicros
                if release > 0 { usleep(release) }
                restored = SkyLight.activate(s, psn: psn, window: window.windowID, focused: false)
            }
            SkyLight.sessionLock.lock()
            if !restored, let psn { SkyLight.pendingCleanup = PendingCleanup(id: id, window: window, psn: psn) }
            else if SkyLight.activeKeyboard == id { SkyLight.activeKeyboard = nil }
            SkyLight.sessionLock.unlock()
            restorationSucceeded = restored
            return restored
        }

        deinit { finish() }
    }

    struct KeyboardError: Error { let reason: String }

    static func beginKeyboard(in window: NativeWindowObservation) -> Result<KeyboardSession, KeyboardError> {
        guard !Task.isCancelled else { return .failure(.init(reason: "keyboard operation cancelled")) }
        guard retryPendingCleanup() else { return .failure(.init(reason: "previous synthetic input state could not be released; background input remains blocked")) }
        guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isHidden else {
            return .failure(.init(reason: "the target app is hidden; it must be restored before background keyboard input"))
        }
        if let why = window.staleness() { return .failure(.init(reason: why)) }
        let id = UUID()
        sessionLock.lock()
        guard activeKeyboard == nil else {
            sessionLock.unlock()
            return .failure(.init(reason: "another native keyboard operation owns the input session"))
        }
        activeKeyboard = id
        sessionLock.unlock()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid {
            return .success(KeyboardSession(id: id, window: window, psn: nil))
        }
        guard let s = symbols else {
            sessionLock.lock(); activeKeyboard = nil; sessionLock.unlock()
            return .failure(.init(reason: "background keyboard symbols are unavailable on this macOS"))
        }
        guard let psn = psn(for: window.pid, s) else {
            sessionLock.lock(); activeKeyboard = nil; sessionLock.unlock()
            return .failure(.init(reason: "the target process could not be resolved"))
        }
        let session = KeyboardSession(id: id, window: window, psn: psn)
        // Order matters: activation first, then the key-window pair (reversed, Chromium ignores them).
        guard activate(s, psn: psn, window: window.windowID, focused: true) else {
            session.finish()
            return .failure(.init(reason: "the target rejected synthetic activation"))
        }
        for record in keyWindowRecords(window.windowID) {
            let status = psn.withUnsafeBytes { p in record.withUnsafeBufferPointer { s.postRecord(p.baseAddress, $0.baseAddress) } }
            guard status == 0 else {
                session.finish()
                return .failure(.init(reason: "the target rejected internal keyboard focus; no keys were sent"))
            }
        }
        let settle = timing.keySettleMicros
        if settle > 0 { usleep(settle) }
        if let why = window.staleness() {
            session.finish()
            return .failure(.init(reason: why))
        }
        return .success(session)
    }

    // MARK: - Pointer

    enum Button: Equatable, Sendable { case left, right }

    /// Clicks `point` (global, top-left) in `window` of `pid` without moving the cursor, raising the app or
    /// touching the frontmost app. Left or right button, single or double. Returns nil on success, else why not.
    static func click(at point: CGPoint, pid: pid_t, window: CGWindowID, frame: CGRect, button: Button = .left, count: Int = 1) -> String? {
        guard let s = symbols else { return "background clicks unavailable: SkyLight symbols missing on this macOS" }
        guard frame.contains(point) else { return "background click point is outside the target window" }
        let timing = self.timing
        guard let recipe = timing.clickRecipe(count: count) else { return "background clicks support one or two clicks" }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isHidden,
              let observed = NativeWindowObservation.capture(app, windowID: window),
              ObservationGeometry(frame: frame, imageSize: CGSize(width: 1, height: 1)).matches(observed.frame) else {
            return "background click window identity or geometry changed; observe again"
        }
        guard !Task.isCancelled else { return "background click cancelled before delivery" }
        guard retryPendingCleanup() else { return "previous input state could not be released; background input remains blocked" }
        let operation = UUID()
        sessionLock.lock()
        guard activeKeyboard == nil else { sessionLock.unlock(); return "another native input operation owns the target" }
        activeKeyboard = operation
        sessionLock.unlock()
        defer {
            sessionLock.lock()
            if pendingCleanup == nil, activeKeyboard == operation { activeKeyboard = nil }
            sessionLock.unlock()
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return "couldn't create an event source" }
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        let group = Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000)
        let offWindow = CGPoint(x: -1, y: -1)
        var prepared: [(CGEvent, useconds_t)] = []
        for step in recipe {
            // The primer is always a left press off-window; the target pair uses the requested button.
            let right = button == .right && step.onTarget
            let type: CGEventType
            switch step.kind {
            case .move: type = .mouseMoved
            case .down: type = right ? .rightMouseDown : .leftMouseDown
            case .up: type = right ? .rightMouseUp : .leftMouseUp
            }
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: step.onTarget ? point : offWindow,
                                  mouseButton: right ? .right : .left) else { return "background click event construction failed; inspect before retrying" }
            let raw = Unmanaged.passUnretained(e).toOpaque()
            for (field, value) in [(Field.gesturePhase, step.phase), (Field.clickState, step.clickState), (Field.buttonNumber, right ? 1 : 0),
                                   (Field.subtype, 3), (Field.targetPID, Int64(pid)), (Field.windowNumber, Int64(window)),
                                   (Field.clickGroupID, group), (Field.windowUnderPointer, Int64(window)),
                                   (Field.handlingWindowUnderPointer, Int64(window))] {
                s.setIntField(raw, field, value)
            }
            let at = step.onTarget ? local : offWindow
            s.setWindowLocation(raw, at.x, at.y)
            prepared.append((e, step.delayMicros))
        }
        guard observed.staleness() == nil, !Task.isCancelled else { return "the background click target changed before delivery" }

        var targetPSN: [UInt8]?
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            guard let out = psn(for: pid, s) else { return "couldn't resolve the app's process" }
            guard activate(s, psn: out, window: window, focused: true) else {
                if !activate(s, psn: out, window: window, focused: false) {
                    sessionLock.lock(); pendingCleanup = PendingCleanup(id: operation, window: observed, psn: out); sessionLock.unlock()
                }
                return "couldn't confirm synthetic focus; no pointer input was sent"
            }
            targetPSN = out
        }
        // The whole sequence was constructed before the first down event; allocation failure can't leave a button held.
        for (event, delay) in prepared {
            // Both channels: SkyLight reaches Chromium/Catalyst, the public one keeps AppKit happy.
            s.postToPid(pid, Unmanaged.passUnretained(event).toOpaque())
            event.postToPid(pid)
            if delay > 0 { usleep(delay) }
        }
        if let targetPSN {
            // Delivery is async; hold the synthetic focus until Chromium's renderer has taken the mouse-up.
            let settle = timing.rendererSettleMicros
            if settle > 0 { usleep(settle) }
            let restored = !AXEngine.isSameProcess(observed.identity) || activate(s, psn: targetPSN, window: window, focused: false)
            if !restored {
                sessionLock.lock()
                pendingCleanup = PendingCleanup(id: operation, window: observed, psn: targetPSN)
                sessionLock.unlock()
                return "click delivery is uncertain because temporary focus cleanup failed; inspect before continuing"
            }
        }
        return nil
    }

    /// A wheel burst posted to `pid` and tagged with `window`; the real pointer stays with the user.
    /// Positive `dy` scrolls up, positive `dx` left.
    static func scroll(dy: Int32, dx: Int32, pixels: Bool, at point: CGPoint, pid: pid_t, window: CGWindowID) -> Bool {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: pixels ? .pixel : .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return false }
        event.location = point
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
        if let s = symbols {
            let raw = Unmanaged.passUnretained(event).toOpaque()
            s.setIntField(raw, Field.targetPID, Int64(pid))
            s.setIntField(raw, Field.windowNumber, Int64(window))
        }
        event.postToPid(pid)
        return true
    }
}

import AppKit
import CoreGraphics

/// Background clicks through private SkyLight, for Chromium/Electron/Catalyst windows that ignore a plain
/// postToPid click (they hit-test against WindowServer's active window). Recipe from mac-computer-use (after
/// trycua/cua). Undocumented ABI: used by background runs, or by any run with BACKGROUND_CLICKS=1; every symbol is
/// probed at load, and it's fully off if any is missing rather than half-posting a sequence.
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

    private static let symbols: Symbols? = {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let postToPid: PostToPid = sym(sky, "SLEventPostToPid"),
              let setIntField: SetIntField = sym(sky, "SLEventSetIntegerValueField"),
              let setWindowLocation: SetWindowLocation = sym(sky, "CGEventSetWindowLocation"),
              let postRecord: PostRecord = sym(sky, "SLPSPostEventRecordTo"),
              let processForPID: ProcessForPID = sym(services, "GetProcessForPID") else { return nil }
        return Symbols(postToPid: postToPid, setIntField: setIntField, setWindowLocation: setWindowLocation,
                       postRecord: postRecord, processForPID: processForPID)
    }()

    static var isEnabled: Bool { Config.value("BACKGROUND_CLICKS") == "1" && symbols != nil }
    /// This macOS has every symbol the background path needs.
    static var isAvailable: Bool { symbols != nil }

    /// Independent optional capture capability. Never bypass Screen Recording permission.
    /// ABI reference: OCU SkyLightSPI.hardwareCaptureWindow (not a stable public macOS API).
    private typealias MainConnection = @convention(c) () -> UInt32
    private typealias HardwareCapture = @convention(c) (UInt32, UnsafePointer<CGWindowID>, Int32, UInt32) -> Unmanaged<CFArray>?
    private static let captureSymbols: (MainConnection, HardwareCapture)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(handle, "SLSMainConnectionID"), let capture = dlsym(handle, "SLSHWCaptureWindowList") else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self), unsafeBitCast(capture, to: HardwareCapture.self))
    }()

    static func capture(_ window: NativeWindowObservation) -> CGImage? {
        guard Config.value("BACKGROUND_NATIVE") == "1", CGPreflightScreenCaptureAccess(),
              window.staleness(includeContent: true) == nil, let (connection, capture) = captureSymbols else { return nil }
        var id = window.windowID
        guard let images = capture(connection(), &id, 1, 0x800)?.takeRetainedValue(), CFArrayGetCount(images) == 1,
              let pointer = CFArrayGetValueAtIndex(images, 0) else { return nil }
        let object = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        guard CFGetTypeID(object) == CGImage.typeID else { return nil }
        let image = unsafeBitCast(object, to: CGImage.self)
        guard image.width > 0, image.height > 0, window.staleness(includeContent: true) == nil else { return nil }
        // Reject backing stores with unexpected decoration/crop before coordinates are mapped to them.
        let ratio = Double(image.width) / Double(image.height)
        let wanted = Double(window.frame.width / window.frame.height)
        guard abs(ratio - wanted) <= max(0.005, wanted * 0.005) else { return nil }
        return image
    }

    /// Private CGEvent fields the Chromium-compatible path sets.
    private enum Field {
        static let gesturePhase: UInt32 = 0, clickState: UInt32 = 1, buttonNumber: UInt32 = 3, subtype: UInt32 = 7
        static let targetPID: UInt32 = 40, windowNumber: UInt32 = 51, clickGroupID: UInt32 = 58
        static let windowUnderPointer: UInt32 = 91, handlingWindowUnderPointer: UInt32 = 92
    }

    /// Focus/defocus record for SLPSPostEventRecordTo: gives the target a synthetic active state without touching
    /// the real frontmost app (defocusing that would fire resignKey and lose the user's first responder).
    private static func activationRecord(window: CGWindowID, focused: Bool) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 0xF8)
        r[0x04] = 0xF8
        r[0x08] = 0x0D
        for i in 0..<4 { r[0x3C + i] = UInt8(truncatingIfNeeded: window >> (8 * UInt32(i))) }
        r[0x8A] = focused ? 0x01 : 0x02
        return r
    }

    private static func activate(_ s: Symbols, psn: [UInt8], window: CGWindowID, focused: Bool) -> Bool {
        let record = activationRecord(window: window, focused: focused)
        return psn.withUnsafeBytes { p in record.withUnsafeBufferPointer { s.postRecord(p.baseAddress, $0.baseAddress) } } == 0
    }

    /// Legacy callers only check capability. Synthetic state is now scoped to an input operation,
    /// never left active by app selection or observation.
    @discardableResult
    static func focus(pid: pid_t, window: CGWindowID) -> Bool {
        guard symbols != nil, let app = NSRunningApplication(processIdentifier: pid), !app.isHidden else { return false }
        return NativeWindowObservation.capture(app, windowID: window) != nil
    }

    /// Derived record layout: yabai window_manager_make_key_window and OCU SkyLightSPI.
    /// https://github.com/iFurySt/open-computer-use/blob/main/packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SkyLightSPI.swift
    /// See THIRD_PARTY_NOTICES.md. Kept behind runtime capability checks and BACKGROUND_NATIVE opt-in.
    private static func keyWindowRecords(_ window: CGWindowID) -> [[UInt8]] {
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
                usleep(10_000)
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
        var psn = [UInt8](repeating: 0, count: 8)
        guard psn.withUnsafeMutableBytes({ s.processForPID(window.pid, $0.baseAddress) }) == 0 else {
            sessionLock.lock(); activeKeyboard = nil; sessionLock.unlock()
            return .failure(.init(reason: "the target process could not be resolved"))
        }
        let session = KeyboardSession(id: id, window: window, psn: psn)
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
        // Different channels deliver activation records and CGEvents. Retain the cross-version margin
        // documented by OCU, instead of assuming synchronous target processing.
        usleep(10_000)
        if let why = window.staleness() {
            session.finish()
            return .failure(.init(reason: why))
        }
        return .success(session)
    }

    /// Clicks `point` (global, top-left) in `window` of `pid` without moving the cursor or raising the app.
    /// Returns nil on success, otherwise why it didn't click.
    static func click(at point: CGPoint, pid: pid_t, window: CGWindowID, frame: CGRect) -> String? {
        guard let s = symbols else { return "background clicks unavailable: SkyLight symbols missing on this macOS" }
        guard frame.contains(point) else { return "background click point is outside the target window" }
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

        var psn: [UInt8]?
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            var out = [UInt8](repeating: 0, count: 8)
            guard out.withUnsafeMutableBytes({ s.processForPID(pid, $0.baseAddress) }) == 0 else { return "couldn't resolve the app's process" }
            guard activate(s, psn: out, window: window, focused: true) else {
                if !activate(s, psn: out, window: window, focused: false) {
                    sessionLock.lock(); pendingCleanup = PendingCleanup(id: operation, window: observed, psn: out); sessionLock.unlock()
                }
                return "couldn't confirm synthetic focus; no pointer input was sent"
            }
            psn = out
            usleep(40_000)
        }
        defer {
            if let psn {
                // Delivery is async; hold the synthetic focus until Chromium's renderer has taken the mouse-up.
                usleep(100_000)
                if AXEngine.isSameProcess(observed.identity), !activate(s, psn: psn, window: window, focused: false) {
                    sessionLock.lock()
                    pendingCleanup = PendingCleanup(id: operation, window: observed, psn: psn)
                    sessionLock.unlock()
                }
            }
        }

        let group = Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000)
        let offWindow = CGPoint(x: -1, y: -1)
        // A move, an off-window primer down/up that wakes the renderer, then the real click.
        let steps: [(CGEventType, Bool, Int64, Int64, useconds_t)] = [
            (.mouseMoved, true, 0, 2, 15_000), (.leftMouseDown, false, 1, 1, 1_000), (.leftMouseUp, false, 1, 2, 100_000),
            (.leftMouseDown, true, 1, 3, 1_000), (.leftMouseUp, true, 1, 3, 0),
        ]
        var prepared: [(CGEvent, useconds_t)] = []
        for (type, onTarget, clickState, phase, delay) in steps {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: onTarget ? point : offWindow,
                                  mouseButton: .left) else { return "background click event construction failed; inspect before retrying" }
            let raw = Unmanaged.passUnretained(e).toOpaque()
            for (field, value) in [(Field.gesturePhase, phase), (Field.clickState, clickState), (Field.buttonNumber, 0),
                                   (Field.subtype, 3), (Field.targetPID, Int64(pid)), (Field.windowNumber, Int64(window)),
                                   (Field.clickGroupID, group), (Field.windowUnderPointer, Int64(window)),
                                   (Field.handlingWindowUnderPointer, Int64(window))] {
                s.setIntField(raw, field, value)
            }
            let at = onTarget ? local : offWindow
            s.setWindowLocation(raw, at.x, at.y)
            prepared.append((e, delay))
        }
        guard observed.staleness() == nil, !Task.isCancelled else { return "the background click target changed before delivery" }
        // Construct the entire sequence before the first down event; allocation failure must not leave a button held.
        for (event, delay) in prepared {
            // Both channels: SkyLight reaches Chromium/Catalyst, the public one keeps AppKit happy.
            s.postToPid(pid, Unmanaged.passUnretained(event).toOpaque())
            event.postToPid(pid)
            if delay > 0 { usleep(delay) }
        }
        if let targetPSN = psn {
            usleep(100_000)
            let restored = !AXEngine.isSameProcess(observed.identity) || activate(s, psn: targetPSN, window: window, focused: false)
            psn = nil
            if !restored {
                sessionLock.lock()
                pendingCleanup = PendingCleanup(id: operation, window: observed, psn: targetPSN)
                sessionLock.unlock()
                return "click delivery is uncertain because temporary focus cleanup failed; inspect before continuing"
            }
        }
        return nil
    }
}

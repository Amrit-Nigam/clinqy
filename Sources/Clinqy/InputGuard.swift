import AppKit
import CoreGraphics

/// While Clinqy performs an action burst, swallows the user's hardware keyboard and mouse so a stray key or nudge
/// can't land mid-click or mid-word. Clinqy's own synthetic events pass (they carry this process's pid). Esc
/// cancels the run; a watchdog lets go if an action hangs. Off with INPUT_GUARD=0. Needs Accessibility (and
/// Input Monitoring on some systems): if the tap can't be created, nothing is blocked and runs carry on.
final class InputGuard: @unchecked Sendable {
    static let shared = InputGuard()

    static var isEnabled: Bool { !["0", "false", "no", "off"].contains(Config.value("INPUT_GUARD")?.lowercased() ?? "") }

    /// Longest an action may hold input before the guard lets go on its own (re-armed by every `arm()`).
    var watchdog: TimeInterval = 30

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var blocking = false
    private var lastHardware: Date?
    private var watchdogItem: DispatchWorkItem?
    private var onCancel: (@MainActor () -> Void)?

    /// Starts watching for a run. `onCancel` runs on the main thread if the user presses Esc while input is held.
    /// Returns false if the tap couldn't be created (no permission); the run should simply go on unguarded.
    @MainActor @discardableResult
    func start(onCancel: @escaping @MainActor () -> Void) -> Bool {
        withLock { self.onCancel = onCancel }
        guard Self.isEnabled else { return false }
        if tap != nil { return true }
        var mask: CGEventMask = 0
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .scrollWheel,
                                    .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                    .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        for type in types { mask |= CGEventMask(1) << type.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: inputGuardCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("Clinqy InputGuard: couldn't create the event tap (Accessibility/Input Monitoring); running unguarded")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    /// Holds hardware input for the next action and re-arms the watchdog. Call before each action burst.
    func arm() {
        guard tap != nil else { return }
        let item = DispatchWorkItem { [weak self] in
            NSLog("Clinqy InputGuard: watchdog fired, letting input through")
            self?.disarm()
        }
        withLock {
            watchdogItem?.cancel()
            watchdogItem = item
            blocking = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdog, execute: item)
    }

    /// Lets hardware input through again: between actions, and always before asking the user anything.
    func disarm() {
        withLock {
            watchdogItem?.cancel()
            watchdogItem = nil
            blocking = false
        }
    }

    /// Tears the tap down at run end (also on cancel/failure).
    @MainActor
    func stop() {
        disarm()
        withLock { onCancel = nil }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
    }

    var isBlocking: Bool { withLock { blocking } }

    // MARK: - Idle awareness

    /// True if the user touched the keyboard, mouse or trackpad within `seconds`, so the loop can pause and
    /// resume once they're idle. While the tap is up it sees exactly which events were theirs; otherwise the
    /// HID idle clock is used, ignoring input that's no newer than Clinqy's own last synthetic event.
    static func userIsActive(within seconds: TimeInterval) -> Bool {
        if shared.tap != nil {
            guard let last = shared.withLock({ shared.lastHardware }) else { return false }
            return Date().timeIntervalSince(last) < seconds
        }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
        guard idle < seconds else { return false }
        let sinceOurs = Date().timeIntervalSince(shared.withLock { shared.lastSynthetic })
        return sinceOurs > idle + 0.25
    }

    private var lastSynthetic = Date.distantPast

    /// Records that Clinqy just posted input, so the HID idle clock isn't mistaken for the user.
    static func noteSynthetic() { shared.withLock { shared.lastSynthetic = Date() } }

    // MARK: - Tap

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Clinqy's own events, whatever source state they were made with.
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return Unmanaged.passUnretained(event) }
        let held = withLock { () -> Bool in
            lastHardware = Date()
            return blocking
        }
        guard held else { return Unmanaged.passUnretained(event) }
        switch type {
        case .keyUp, .flagsChanged, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            // Releases always pass: swallowing one leaves a key or button stuck down.
            return Unmanaged.passUnretained(event)
        case .keyDown where event.getIntegerValueField(.keyboardEventKeycode) == 0x35
            && event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty:
            let cancel = withLock { () -> (@MainActor () -> Void)? in
                watchdogItem?.cancel()
                blocking = false
                return onCancel
            }
            if let cancel { DispatchQueue.main.async { MainActor.assumeIsolated { cancel() } } }
            return nil
        default:
            return nil
        }
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private func inputGuardCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputGuard>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}

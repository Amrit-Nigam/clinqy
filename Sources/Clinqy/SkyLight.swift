import AppKit
import CoreGraphics

/// Background clicks through private SkyLight, for Chromium/Electron/Catalyst windows that ignore a plain
/// postToPid click (they hit-test against WindowServer's active window). Recipe from mac-computer-use (after
/// trycua/cua). Undocumented ABI: only with BACKGROUND_CLICKS=1, every symbol probed at load, and fully off if
/// any is missing rather than half-posting a sequence. Never chosen automatically.
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

    /// Clicks `point` (global, top-left) in `window` of `pid` without moving the cursor or raising the app.
    /// Returns nil on success, otherwise why it didn't click.
    static func click(at point: CGPoint, pid: pid_t, window: CGWindowID, frame: CGRect) -> String? {
        guard Config.value("BACKGROUND_CLICKS") == "1" else { return "background clicks are off (BACKGROUND_CLICKS=1 enables them)" }
        guard let s = symbols else { return "background clicks unavailable: SkyLight symbols missing on this macOS" }
        guard frame.contains(point) else { return "background click point is outside the target window" }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return "couldn't create an event source" }
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)

        var psn: [UInt8]?
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            var out = [UInt8](repeating: 0, count: 8)
            guard out.withUnsafeMutableBytes({ s.processForPID(pid, $0.baseAddress) }) == 0 else { return "couldn't resolve the app's process" }
            guard activate(s, psn: out, window: window, focused: true) else { return "couldn't give the window synthetic focus" }
            psn = out
            usleep(40_000)
        }
        defer {
            if let psn {
                // Delivery is async; hold the synthetic focus until Chromium's renderer has taken the mouse-up.
                usleep(100_000)
                _ = activate(s, psn: psn, window: window, focused: false)
            }
        }

        let group = Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000)
        let offWindow = CGPoint(x: -1, y: -1)
        // A move, an off-window primer down/up that wakes the renderer, then the real click.
        let steps: [(CGEventType, Bool, Int64, Int64, useconds_t)] = [
            (.mouseMoved, true, 0, 2, 15_000), (.leftMouseDown, false, 1, 1, 1_000), (.leftMouseUp, false, 1, 2, 100_000),
            (.leftMouseDown, true, 1, 3, 1_000), (.leftMouseUp, true, 1, 3, 0),
        ]
        for (type, onTarget, clickState, phase, delay) in steps {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: onTarget ? point : offWindow,
                                  mouseButton: .left) else { continue }
            let raw = Unmanaged.passUnretained(e).toOpaque()
            for (field, value) in [(Field.gesturePhase, phase), (Field.clickState, clickState), (Field.buttonNumber, 0),
                                   (Field.subtype, 3), (Field.targetPID, Int64(pid)), (Field.windowNumber, Int64(window)),
                                   (Field.clickGroupID, group), (Field.windowUnderPointer, Int64(window)),
                                   (Field.handlingWindowUnderPointer, Int64(window))] {
                s.setIntField(raw, field, value)
            }
            let at = onTarget ? local : offWindow
            s.setWindowLocation(raw, at.x, at.y)
            // Both channels: SkyLight reaches Chromium/Catalyst, the public one keeps AppKit happy.
            s.postToPid(pid, raw)
            e.postToPid(pid)
            if delay > 0 { usleep(delay) }
        }
        return nil
    }
}

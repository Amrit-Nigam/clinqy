import AppKit

/// Native background routing: one pinned window of one app, driven with Accessibility first and
/// SkyLight window-targeted input otherwise. On by default; BACKGROUND_NATIVE=0 is the kill switch.
/// Symbols are probed at runtime and every private path fails closed to a foreground handoff.
@MainActor
enum NativeBackgroundCapability {
    nonisolated static var enabled: Bool { SkyLight.nativeEnabled }

    static func appRefusal(_ app: NSRunningApplication) -> String? {
        if app.isTerminated { return "The native target must be a running application." }
        return BackgroundPolicy.nativeAppRefusal(bundleID: app.bundleIdentifier, name: app.cleanName, hidden: app.isHidden,
                                                 isSelf: app.processIdentifier == getpid())
    }

    static func canObserve(_ app: NSRunningApplication, window: NativeWindowObservation?) -> String? {
        guard enabled else { return "Native background control is disabled (BACKGROUND_NATIVE=0); use foreground mode." }
        if let why = appRefusal(app) { return why }
        guard AXEngine.isTrusted else { return "Accessibility permission is required for this native target." }
        guard let window, window.pid == app.processIdentifier else { return "Choose one exact native window before acting." }
        return window.staleness()
    }

    /// Whether `open_app` may launch `url` without activating it (no Space switch, no raise).
    static func canLaunch(bundleID: String?, name: String?) -> String? {
        guard enabled else { return "Native background control is disabled (BACKGROUND_NATIVE=0); use foreground mode." }
        return BackgroundPolicy.nativeAppRefusal(bundleID: bundleID, name: name, hidden: false, isSelf: bundleID == Bundle.main.bundleIdentifier)
    }

    static func canPerform(_ action: [String: Any], window: NativeWindowObservation?, elements: [UIElementInfo],
                           coordinateCapture: Screenshot.Capture? = nil) -> String? {
        guard let window, let app = NSRunningApplication(processIdentifier: window.pid) else { return "No pinned native window is available; select a running app first." }
        if let reason = canObserve(app, window: window) { return reason }
        if case .refuse(let why) = decide(action, window: window, elements: elements, coordinateCapture: coordinateCapture) { return why }
        return nil
    }

    static func decide(_ action: [String: Any], window: NativeWindowObservation, elements: [UIElementInfo],
                       coordinateCapture: Screenshot.Capture? = nil) -> BackgroundPolicy.NativeDecision {
        var facts = BackgroundPolicy.NativeFacts()
        facts.hasWindow = true
        facts.skyLightAvailable = SkyLight.isAvailable
        if let keys = action["keys"] as? String { facts.chordValid = AXEngine.chordProblem(keys) == nil }
        if let id = action["id"] as? String, let element = AXEngine.lookup(id, in: elements),
           element.observationID == window.id, element.windowID == window.windowID,
           window.frame.contains(element.center), window.containsElement(element.element) {
            facts.elementInWindow = true
            facts.elementEnabled = element.enabled != false
            facts.elementSecure = Safety.isSecureField(element.element)
            facts.textRole = Hand.isTextRole(element.role)
            var settable = DarwinBoolean(false)
            facts.valueSettable = AXUIElementIsAttributeSettable(element.element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
            var names: CFArray?
            if AXUIElementCopyActionNames(element.element, &names) == .success { facts.elementActions = names as? [String] ?? [] }
        }
        if let x = (action["x"] as? NSNumber)?.doubleValue, let y = (action["y"] as? NSNumber)?.doubleValue {
            if let capture = coordinateCapture, capture.window.windowID == window.windowID, capture.window.identity == window.identity,
               let point = capture.geometry.screenPoint(x: x, y: y) {
                facts.pointInWindow = window.frame.contains(point)
            } else { facts.pointInWindow = false }
        }
        let kind = (action["do"] as? String ?? "").lowercased()
        if ["click", "right_click", "double_click"].contains(kind) {
            switch ClickOptions.parse(action) {
            case .failure: facts.pointerOptionsSupported = false
            case .success(var options):
                if kind == "right_click" { options.button = .right }
                if kind == "double_click" { options.count = 2 }
                facts.pointerOptionsSupported = options.isPlain && kind == "click" ? nil : Hand.skyCompatible(options)
            }
        }
        return BackgroundPolicy.nativeRoute(action, facts: facts)
    }
}

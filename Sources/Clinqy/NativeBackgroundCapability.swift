import AppKit

/// Experimental native routing is explicit and capability-scoped. A symbol existing is not a
/// blanket permission to control arbitrary apps or to fall back to foreground input.
@MainActor
enum NativeBackgroundCapability {
    static var enabled: Bool { Config.value("BACKGROUND_NATIVE") == "1" }

    static func canObserve(_ app: NSRunningApplication, window: NativeWindowObservation?) -> String? {
        guard enabled else { return "Native background control is disabled; use foreground mode or explicitly enable BACKGROUND_NATIVE=1." }
        guard app.processIdentifier != getpid(), !app.isTerminated, !app.isHidden else { return "The native target must be a running, visible application." }
        guard AXEngine.isTrusted else { return "Accessibility permission is required for this native target." }
        guard let window, window.pid == app.processIdentifier else { return "Choose one exact native window before acting." }
        return window.staleness()
    }

    static func canPerform(_ action: [String: Any], window: NativeWindowObservation?, elements: [UIElementInfo]) -> String? {
        guard let window, let app = NSRunningApplication(processIdentifier: window.pid) else { return "No pinned native window is available; select a running app first." }
        if let reason = canObserve(app, window: window) { return reason }
        let kind = (action["do"] as? String ?? "").lowercased()
        switch kind {
        case "look", "snap", "read", "verify", "wait": return nil
        case "key":
            guard SkyLight.isAvailable else { return "Background keyboard delivery is unavailable on this macOS." }
            guard let keys = action["keys"] as? String, AXEngine.chordProblem(keys) == nil else { return "Supply one valid shortcut." }
            return nil
        case "type", "click", "choose":
            guard let id = action["id"] as? String, let element = AXEngine.lookup(id, in: elements),
                  element.observationID == window.id, element.windowID == window.windowID,
                  window.containsElement(element.element), window.frame.contains(element.center) else {
                return "Native background actions require a current element in the pinned window; raw coordinates and guessed labels are not accepted."
            }
            guard element.enabled != false, !Safety.isSecureField(element.element) else { return "The target is disabled or secure." }
            if kind == "type" {
                guard Hand.isTextRole(element.role), SkyLight.isAvailable else { return "This target cannot accept isolated native text input." }
                if action["submit"] as? Bool == true { return "Verify the typed native field first, then request a separate submit action." }
                return nil
            }
            if kind == "choose" { return "Native dropdown choices require foreground mode until their open-menu ownership can be verified." }
            if case .success(let options) = ClickOptions.parse(action), options.isPlain { return nil }
            return "Native background click options are limited to a plain element click."
        case "scroll": return "Native background scrolling requires an explicitly observed scroll container; use foreground mode for this operation."
        default: return "This native action has no isolated background implementation; use foreground mode."
        }
    }
}

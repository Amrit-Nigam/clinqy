import Foundation

/// Pure capability routing: a background task never falls through to native focus, keyboard or clipboard input.
enum BackgroundPolicy {
    enum Route: Equatable { case api, browser, attention(String) }

    static func route(_ action: [String: Any], hasWorkerPage: Bool, allowTabDiscovery: Bool = false) -> Route {
        let kind = (action["do"] as? String ?? "").lowercased()
        let webID = (action["id"] as? String)?.lowercased().hasPrefix("w") == true
        switch kind {
        case "parallel_browser": return .api
        case "tab" where allowTabDiscovery && (action["op"] as? String ?? "list").lowercased() == "list":
            return .browser // Explicit existing-tab requests may discover URLs before creating a task page.
        case "open_url": return .browser
        case "open_app":
            let name = (action["name"] as? String ?? "").lowercased()
            if ["chrome", "google chrome", "arc", "brave", "brave browser", "edge", "microsoft edge", "browser"].contains(name) { return .browser }
            if name.contains("finder") { return .attention("Use the files action to find, list, rename or move files without opening Finder.") }
            return .attention("This task needs a native app. Its input cannot be isolated safely in background mode.")
        case "hover", "right_click", "double_click", "drag":
            let destinationIsWeb = (action["to_id"] as? String)?.hasPrefix("w") == true
            return hasWorkerPage && webID && (kind != "drag" || destinationIsWeb) ? .browser
                : .attention("Gestures need current element ids on the owned browser page; native gestures require foreground mode.")
        case "click", "type", "choose", "fill", "set_state":
            if hasWorkerPage, !(webID || (action["id"] == nil && kind == "type")) {
                // The task's own tab exists; this action just has no page-element target in background mode.
                return .attention(action["text"] != nil || action["x"] != nil
                    ? "Background tabs act on page element ids (w<number>) only, not on text labels or screen coordinates. Read the page and use the element's w-id."
                    : "Use a current page element id (w<number>) from the owned task tab. I won't use your active window.")
            }
            return hasWorkerPage ? .browser
                : .attention("No owned browser page target is available. I won't use your active window.")
        case "key":
            let key = (action["keys"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            let commands = ["cmd", "command", "meta", "super", "ctrl", "control", "alt", "option"]
            if commands.contains(where: { key.contains($0 + "+") }) && !["cmd+a", "command+a", "meta+a", "ctrl+a", "control+a"].contains(key) {
                return .attention("This shortcut can use shared browser or system state. Use page fields, direct uploads or file tools instead.")
            }
            return hasWorkerPage ? .browser : .attention("No owned browser page is available for this key.")
        case "verify":
            if action["path"] as? String != nil || action["user_confirms"] != nil { return .api }
            return hasWorkerPage && (!((action["value"] as? String) != nil) || webID) ? .browser
                : .attention("Verify a saved file path or an outcome on the owned browser page. I won't inspect your foreground window.")
        case "image" where action["path"] != nil: return .api
        case "images", "image": return hasWorkerPage ? .browser : .attention("Open an owned task page before reading its images.")
        case "read", "extract":
            return action["path"] != nil || action["file"] != nil ? .api : hasWorkerPage ? .browser : .attention("Give a file path or open a task browser page. I won't read your foreground document.")
        case "files":
            return ["show", "reveal"].contains((action["op"] as? String ?? "").lowercased())
                ? .attention("Revealing files opens Finder on your desktop. I can return their paths in the results instead.") : .api
        case "table":
            return (action["to"] as? String ?? "csv").lowercased() == "csv" ? .api : .attention("Write a CSV file in background mode. Spreadsheet windows and the shared clipboard need foreground access.")
        case "wait" where action["for"] == nil && action["condition"] == nil: return .api
        case "upload", "autofill", "review", "scroll", "tab", "look", "snap", "wait":
            return hasWorkerPage ? .browser : .attention("This action needs an owned browser task page. Open its URL first.")
        case "pdf":
            let paths = (action["files"] as? [String] ?? []) + [action["file"] as? String].compactMap { $0 }
            if paths.contains(where: { ["key", "keynote", "doc", "docx", "csv", "ppt", "pptx", "xls", "xlsx", "numbers", "pages"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) {
                return .attention("This conversion opens an iWork application. Use foreground mode for it.")
            }
            return .api
        case "delegate", "collect", "think", "dictionary", "remember_answer", "calendar", "media", "application", "remember", "recall", "event", "reminder", "ask", "show", "assert", "schedule": return .api
        case "email": return action["draft"] as? Bool == true ? .attention("A draft opens a Mail window. Use foreground mode to review it there.") : .api
        case "shell", "applescript": return .attention("Arbitrary scripts can change your desktop or shared input. Use the files, PDF, media or other supported actions in background mode.")
        default: return .attention("This action requires native desktop access and cannot run safely in background mode.")
        }
    }

    // MARK: - Native lane (pinned window of one app, no activation, no real pointer)

    /// How a permitted native action is delivered. Every lane leaves the user's frontmost app, key window,
    /// pointer and Space unchanged; `foreground` is never chosen here (only surfaces that accept nothing else).
    enum NativeLane: Equatable { case readOnly, semantic, keyboard, skyPointer, wheel }
    enum NativeDecision: Equatable { case allow(NativeLane), refuse(String) }

    /// What the caller established about the target before routing. Pure data, so the table is unit tested.
    struct NativeFacts: Equatable {
        /// The id resolved to a current element of the pinned observation and window.
        var elementInWindow = false
        var elementEnabled = true
        var elementSecure = false
        var textRole = false
        var valueSettable = false
        /// AX actions the element advertises (for secondary actions).
        var elementActions: [String] = []
        /// x/y mapped through the current capture and inside the pinned window; nil when no coordinates were given.
        var pointInWindow: Bool?
        /// Click options: nil = plain, true = left/right with count ≤ 2 and no modifiers/hold, false = anything else.
        var pointerOptionsSupported: Bool?
        var chordValid = false
        var skyLightAvailable = false
        var hasWindow = false
    }

    /// AX actions that are generic presses or would navigate away from the item rather than act on it.
    static let secondaryActionDenylist: Set<String> = ["AXPress", "AXCancel", "AXRaise"]
    /// Allowed secondary actions that press the element like AXPress: Agent asks first for a risky label, as for a click.
    static let pressLikeActions: Set<String> = ["AXConfirm", "AXPick"]

    static func nativeRoute(_ action: [String: Any], facts: NativeFacts) -> NativeDecision {
        let kind = (action["do"] as? String ?? "").lowercased()
        guard facts.hasWindow else { return .refuse("No pinned native window is available; select a running app first.") }
        let hasID = action["id"] != nil
        func element() -> String? {
            guard facts.elementInWindow else {
                return "Native background actions need a current element in the pinned window (or x/y on its latest screenshot); guessed labels are not accepted."
            }
            guard facts.elementEnabled, !facts.elementSecure else { return "The target is disabled or secure." }
            return nil
        }
        func pointer() -> NativeDecision {
            guard facts.skyLightAvailable else { return .refuse("Background pointer input is unavailable on this macOS.") }
            if facts.pointerOptionsSupported == false {
                return .refuse("Native background clicks support left or right button, single or double, without modifiers or hold.")
            }
            return .allow(.skyPointer)
        }
        switch kind {
        case "look", "snap", "read", "verify", "wait", "extract", "image": return .allow(.readOnly)
        case "key":
            guard facts.chordValid else { return .refuse("Supply one valid shortcut.") }
            return facts.skyLightAvailable ? .allow(.keyboard) : .refuse("Background keyboard delivery is unavailable on this macOS.")
        case "type", "fill":
            if let why = element() { return .refuse(why) }
            guard facts.textRole else { return .refuse("This target cannot accept isolated native text input.") }
            if action["submit"] as? Bool == true { return .refuse("Verify the typed native field first, then request a separate submit action.") }
            return facts.valueSettable ? .allow(.semantic) : facts.skyLightAvailable ? .allow(.keyboard)
                : .refuse("This field has no settable value and background keyboard delivery is unavailable.")
        case "set_value":
            if let why = element() { return .refuse(why) }
            return facts.valueSettable ? .allow(.semantic) : .refuse("This element's value is not settable through Accessibility.")
        case "set_state", "choose":
            if let why = element() { return .refuse(why) }
            return .allow(.semantic)
        case "secondary_action", "perform_action":
            if let why = element() { return .refuse(why) }
            guard let name = action["action"] as? String, facts.elementActions.contains(name), !secondaryActionDenylist.contains(name) else {
                return .refuse("Name one of the element's advertised secondary actions (for example AXShowMenu, AXIncrement, AXPick).")
            }
            return .allow(.semantic)
        case "click":
            if hasID {
                if let why = element() { return .refuse(why) }
                return facts.pointerOptionsSupported == nil ? .allow(.semantic) : pointer()
            }
            guard facts.pointInWindow == true else {
                return .refuse("Coordinates must come from the latest screenshot of the pinned window and land inside it.")
            }
            return pointer()
        case "right_click", "double_click":
            if hasID { if let why = element() { return .refuse(why) } }
            else if facts.pointInWindow != true { return .refuse("Gesture targets must be a current element or a point inside the pinned window.") }
            return pointer()
        case "scroll":
            return .allow(.wheel)
        case "hover", "drag":
            return .refuse("Native hover and drag need the real pointer; use foreground mode for this operation.")
        default:
            return .refuse("This native action has no isolated background implementation; use foreground mode.")
        }
    }

    /// Native apps that are never driven in the background: terminals (arbitrary command execution),
    /// system security/authorization prompts, and Clinqy itself. Hidden (cmd+H) apps are refused too:
    /// they never accept key-window records and unhiding them would change the user's desktop.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio", "dev.commandline.waveterm",
        "org.tabby", "com.termius-dmg.mac",
    ]
    static let securityBundleIDs: Set<String> = [
        "com.apple.securityagent", "com.apple.coreservices.uiagent", "com.apple.usernotificationcenter", "com.apple.loginwindow",
        "com.apple.localauthentication.uiagent", "com.apple.authorizationhost", "com.apple.keychainaccess", "com.apple.passwords",
        "com.apple.systempreferences.securityagent",
    ]

    static func nativeAppRefusal(bundleID: String?, name: String?, hidden: Bool, isSelf: Bool) -> String? {
        let id = (bundleID ?? "").lowercased(), title = (name ?? "").lowercased()
        if isSelf { return "Clinqy does not drive itself." }
        if terminalBundleIDs.contains(id) || ["terminal", "iterm", "iterm2", "warp", "ghostty", "kitty", "alacritty", "wezterm"].contains(title) {
            return "Terminals run arbitrary commands; they are never driven in the background. Use foreground mode or the shell action."
        }
        if securityBundleIDs.contains(id) || title == "securityagent" {
            return "System security and authorization prompts need you; Clinqy never answers them."
        }
        if hidden { return "The app is hidden (⌘H). Clinqy won't unhide it in the background; show it first or use foreground mode." }
        return nil
    }
}

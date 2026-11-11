import Foundation
import CoreGraphics

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
        case "click" where hasWorkerPage && action["id"] == nil && action["text"] == nil && isCoordinate(action):
            // x/y from this owned/adopted tab's latest screenshot: a trusted click sent to that tab only (no OS pointer).
            return .browser
        case "click", "type", "choose", "fill", "set_state":
            if hasWorkerPage, !(webID || (action["id"] == nil && kind == "type")) {
                // The task's own tab exists; this action just has no page-element target in background mode.
                return .attention(action["text"] != nil || action["x"] != nil
                    ? "Background tabs act on page element ids (w<number>), or on x/y from this tab's latest screenshot for a plain click; not on text labels. Read the page and use the element's w-id, or look and click its x/y."
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
    static func isCoordinate(_ action: [String: Any]) -> Bool {
        (action["x"] as? NSNumber) != nil && (action["y"] as? NSNumber) != nil
    }

    /// Screenshot pixel → CSS viewport point of the owned tab it was taken from. The screenshot is the viewport at
    /// device pixels (devicePixelRatio) and may have been downscaled for the model, so the ratio of the viewport's CSS
    /// size to the image's pixel size covers both. nil when the point is outside the image or the sizes are unknown.
    static func viewportPoint(x: Double, y: Double, image: CGSize, viewport: CGSize) -> CGPoint? {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0,
              x.isFinite, y.isFinite, x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let px = x * viewport.width / image.width, py = y * viewport.height / image.height
        guard px < viewport.width, py < viewport.height else { return nil }
        return CGPoint(x: px, y: py)
    }

    /// A background coordinate click may use a screenshot only of the same tab, document, viewport size and scroll.
    static func screenshotStillCurrent(shotTab: Int?, shotDocument: String?, shotViewport: CGSize, shotScrollY: Double,
                                       pageTab: Int?, pageDocument: String?, pageViewport: CGSize, pageScrollY: Double) -> Bool {
        guard let shotTab, shotTab == pageTab else { return false }
        if let shotDocument, let pageDocument, shotDocument != pageDocument { return false }
        return abs(shotViewport.width - pageViewport.width) < 1 && abs(shotViewport.height - pageViewport.height) < 1
            && abs(shotScrollY - pageScrollY) < 1
    }

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
            // submit:true presses Return in the pinned window through the isolated keyboard session (the text is
            // read back first and a consequential send still goes through approval in the executor).
            if action["submit"] as? Bool == true {
                return facts.skyLightAvailable ? .allow(.keyboard)
                    : .refuse("Background keyboard delivery is unavailable on this macOS, so Return can't be sent to the pinned window.")
            }
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

    /// A native click the model named by its visible text ("click Clinqy final choice item") instead of an e-id or
    /// screenshot point. In the pinned window it resolves to exactly one target: a control whose label is exactly
    /// that text, else text found exactly once inside one text area (selected there through Accessibility), else a
    /// control whose label uniquely contains it. Several matches or none are refused, never guessed.
    struct LabelCandidate: Equatable {
        var id: String
        var role: String
        var label: String
        /// The full text of a text field/area (nil for other controls).
        var text: String? = nil
    }
    enum LabelTarget: Equatable { case element(String), selectText(String, NSRange), ambiguous([String]), none }
    static let textRoles: Set<String> = ["AXTextArea", "AXTextField"]

    static func labelKey(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ ").union(.whitespacesAndNewlines))
            .lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func labelTarget(_ wanted: String, among candidates: [LabelCandidate]) -> LabelTarget {
        let key = labelKey(wanted)
        guard key.count >= 2 else { return .none }
        let controls = candidates.filter { !textRoles.contains($0.role) && !$0.label.isEmpty }
        let exact = controls.filter { labelKey($0.label) == key }
        if exact.count == 1 { return .element(exact[0].id) }
        if exact.count > 1 { return .ambiguous(exact.map(\.id)) }
        let needle = wanted.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’").union(.whitespacesAndNewlines))
        var inText: [(String, NSRange)] = []
        for field in candidates where textRoles.contains(field.role) {
            guard let text = field.text else { continue }
            let ns = text as NSString
            let first = ns.range(of: needle)
            guard first.location != NSNotFound else { continue }
            let after = first.location + first.length
            if ns.range(of: needle, options: [], range: NSRange(location: after, length: ns.length - after)).location != NSNotFound {
                inText.append((field.id, NSRange(location: NSNotFound, length: 0)))   // repeated inside this field
            } else { inText.append((field.id, first)) }
        }
        if inText.count == 1, inText[0].1.location != NSNotFound { return .selectText(inText[0].0, inText[0].1) }
        if !inText.isEmpty { return .ambiguous(inText.map(\.0)) }
        let partial = controls.filter { let label = labelKey($0.label); return label.count >= 3 && (label.contains(key) || key.contains(label)) }
        if partial.count == 1 { return .element(partial[0].id) }
        return partial.isEmpty ? .none : .ambiguous(partial.map(\.id))
    }

    /// The reason shown when a background action can't run. A target in a pinned native window gets the native
    /// lane's own reason: it never needed a browser page, so the browser routing message would be wrong.
    static func attentionReason(browser: String, nativeTarget: Bool, nativeRefusal: String?) -> String {
        guard nativeTarget else { return browser }
        return "The pinned native window can't take this in the background: "
            + (nativeRefusal ?? "this native action has no isolated background implementation.") + " I won't use your active window."
    }

    /// How text goes into a native field whose AX value setter is unavailable.
    enum TextEntryPlan: Equatable { case replace, insert, refuse(String) }

    /// Replace (select-all, then type) only text that can be read back; an empty field, or one that exposes no
    /// value and no characters (chat composers such as WhatsApp's "Compose message"), gets the text inserted at its
    /// caret. A field that visibly holds text it won't expose is refused: replacing it blind could lose that text.
    static func textEntryPlan(value: String?, characterCount: Int?) -> TextEntryPlan {
        if let value { return value.isEmpty ? .insert : .replace }
        if let characterCount, characterCount > 0 {
            return .refuse("the field holds text it doesn't expose, so replacing it could lose that text; clear it or use an insertion action")
        }
        return .insert
    }

    enum IdlessTypeTarget: Equatable { case remembered, focused, none }
    /// Where `type` without an id goes: the field last clicked/typed into in this run (still in the window), else an
    /// already focused text field in the observed window; with neither it fails rather than typing at an unknown caret.
    static func idlessTypeTarget(remembered: Bool, focusedTextField: Bool) -> IdlessTypeTarget {
        remembered ? .remembered : focusedTextField ? .focused : .none
    }

    /// List rows and cells whose AX press is often a no-op (chat lists, sidebars): selecting them, or a click on
    /// their centre, is what opens them.
    static let rowRoles: Set<String> = ["AXRow", "AXCell", "AXOutlineRow", "AXListItem", "AXGroup", "AXStaticText", "AXImage"]

    /// A delivered (not ambiguous) AX press that changed nothing on a row/cell gets one more try: select, then click.
    static func rowFallbackApplies(role: String, changed: Bool, method: String, uncertain: Bool) -> Bool {
        !changed && !uncertain && method == "axpress" && rowRoles.contains(role)
    }

    /// After the user switches a background run to foreground: the app the task already worked in (the pinned native
    /// window's app, else the run's background app). Never "whatever is frontmost", which is usually the user's own
    /// browser or chat; nil only when the task had no app yet (open_app will pick it).
    static func foregroundTarget<App>(contextApp: App?, pinnedApp: App?) -> App? { contextApp ?? pinnedApp }

    /// The window a Telegram card/question thumbnail shows: the target remembered for Telegram, else the window the
    /// background lane pinned for this run (a native app such as WhatsApp). nil when neither exists.
    static func screenshotWindow<App>(telegram: (app: App, id: UInt32)?, pinnedApp: App?, pinnedWindow: UInt32?) -> (app: App, id: UInt32)? {
        if let telegram { return telegram }
        guard let pinnedApp, let pinnedWindow else { return nil }
        return (pinnedApp, pinnedWindow)
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

/// Whether a requested native text field holds focus well enough to type into it, and what to do when it can't be
/// shown to. Background apps often don't update the app-wide AXFocusedUIElement (WhatsApp's composer in the hidden
/// lane), so there the pinned window's own focused element counts too, after a successful AXFocused set.
enum FocusVerification {
    /// How a reported focused element relates to the requested field.
    enum Relation: Equatable {
        case target        // the field itself
        case inside        // an editable descendant of the field
        case otherText     // a different text input (a search field, another composer)
        case other         // something that isn't a text input
        case unreadable    // nothing reported
    }

    static func accepts(app: Relation, window: Relation, focusSet: Bool, background: Bool) -> Bool {
        if app == .target || app == .inside { return true }
        // Another text input holding the app's focus is never overruled by the window's report.
        guard background, focusSet, app != .otherText else { return false }
        return window == .target || window == .inside
    }

    enum Fallback: Equatable { case setValue, refuse(String) }

    /// Background only, when focus can't be verified: write the requested field's own AX value exactly as `set_value`
    /// does, and read it back after the write, so the text can only land in that field. Keystrokes are never sent to an
    /// unverified focus, and nothing is entered while another text input visibly holds the focus (Return would go there).
    /// The field's value need not be readable *before* the write: an empty chat composer (WhatsApp) often reports no
    /// AXValue until it holds text, yet `set_value` writes and reads it back fine (round 9). Only the read-back after
    /// the write gates Return.
    static func fallback(background: Bool, valueSettable: Bool, secure: Bool, focusInOtherField: Bool) -> Fallback {
        guard background else { return .refuse("the requested field did not acquire verifiable focus; look again before typing") }
        guard !secure else { return .refuse("secure fields are never written through Accessibility") }
        guard !focusInOtherField else { return .refuse("another text field holds the focus, so nothing was typed; click the requested field first") }
        guard valueSettable else {
            return .refuse("the requested field did not acquire verifiable focus and its value can't be set through Accessibility; nothing was typed")
        }
        return .setValue
    }
}

/// Putting the user's pointer back after a real click: the saved position keeps its fractional part, and a restore
/// that lands anywhere else (a warp rounding to whole pixels) needs one exact move.
enum PointerRestore {
    static func needsExactMove(saved: CGPoint, now: CGPoint) -> Bool {
        abs(saved.x - now.x) > 0.001 || abs(saved.y - now.y) > 0.001
    }
}

/// A pinned native window that reads as stale right before input (often only because activating the app in the
/// foreground re-rendered it): re-resolve it once by its window ID before refusing. Only the same process and the same
/// window, fresh again, is accepted; a restarted app, a closed/replaced/hidden/minimized window, or a modal sheet still
/// refuses.
enum StaleWindowRecovery {
    static func retries(reason: String) -> Bool {
        let hard = ["restarted", "hidden", "minimized", "modal sheet", "closed or replaced"]
        return !hard.contains { reason.contains($0) }
    }

    static func accepts(sameProcess: Bool, sameWindowID: Bool, freshNow: Bool) -> Bool { sameProcess && sameWindowID && freshNow }
}

/// Where a background run continues when one of its own tabs goes away, and when an open_url would only duplicate a
/// page the run already has open. Both prefer the run's existing owned tabs over reopening the start URL: a fresh copy
/// of a page loses its state (and a test recorder sees a new zero-state page).
enum OwnedTabRecovery {
    /// The owned tab to continue on after `closed` went away: its opener when that is still owned, else the most
    /// recently opened owned tab (largest id), never the closed tab itself.
    static func fallback(closed: Int, opener: Int?, owned: [Int]) -> Int? {
        let remaining = owned.filter { $0 != closed }
        if let opener, remaining.contains(opener) { return opener }
        return remaining.max()
    }

    /// Two URLs show the same page: scheme, host, port, path (trailing slash ignored) and query match; the fragment
    /// is ignored. Anything unparsable never matches.
    static func samePage(_ a: String, _ b: String) -> Bool {
        guard let x = URLComponents(string: a), let y = URLComponents(string: b),
              let xs = x.scheme?.lowercased(), let ys = y.scheme?.lowercased(), xs == ys,
              let xh = x.host?.lowercased(), let yh = y.host?.lowercased(), !xh.isEmpty, xh == yh else { return false }
        let defaultPort: (String) -> Int? = { ["http": 80, "https": 443][$0] }
        guard (x.port ?? defaultPort(xs)) == (y.port ?? defaultPort(ys)) else { return false }
        let path: (URLComponents) -> String = { c in
            let p = c.percentEncodedPath
            return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : (p.isEmpty ? "/" : p)
        }
        return path(x) == path(y) && (x.percentEncodedQuery ?? "") == (y.percentEncodedQuery ?? "")
    }

    /// An owned tab already showing `url`: the current tab first, then the earliest-opened one.
    static func existingTab(for url: String, current: Int?, tabs: [(id: Int, url: String)]) -> Int? {
        let matches = tabs.filter { samePage($0.url, url) }.map(\.id)
        if let current, matches.contains(current) { return current }
        return matches.min()
    }
}

/// A finish that reports it could not do the task at all is never a success: when the run's own browser/task surface
/// failed (bridge error, no window, no extension) and no task page was ever reached and no input was delivered, an
/// answer saying it couldn't reach/open/access something is an inability, not a result. Structured state decides
/// eligibility; the wording only distinguishes "couldn't" from a legitimate read-only answer.
enum InabilityFinishPolicy {
    static func indicatesInability(_ answer: String) -> Bool {
        answer.range(of: #"(?i)\b(couldn['’]?t|could not|can['’]?t|cannot|can not|unable to|was unable to|wasn['’]?t able to|failed to|not able to)\s+(reach|access|connect|open|load|get to|use|find|start|control|read|see)\b"#,
                     options: .regularExpression) != nil
            || answer.range(of: #"(?i)\b(no current window|extension (is )?(not connected|unavailable|disconnected)|not connected to (the )?(browser|extension))\b"#,
                            options: .regularExpression) != nil
    }

    static func mustFail(answer: String, deliveredMutations: Int, surfaceFailures: Int, taskSurfaceReached: Bool) -> Bool {
        deliveredMutations == 0 && surfaceFailures > 0 && !taskSurfaceReached && indicatesInability(answer)
    }
}

/// Receipt identity belongs to one run. A queued background job carries only the receipt it was submitted with; the
/// foreground controller's receipt is set only when that submission starts a foreground run, and is never read or
/// cleared on behalf of another run.
enum RunReceiptRouting {
    /// The receipt a dispatched (isolated) job gets: exactly its own submission's.
    static func dispatched(submitted: String?) -> String? { submitted }
    /// The foreground controller's receipt after a submission: a new foreground run takes its own (possibly none);
    /// an auto-continuation keeps the current one; a dispatched job or a refused submission leaves it untouched.
    static func foreground(current: String?, submitted: String?, startsForegroundRun: Bool, autoContinuation: Bool) -> String? {
        guard startsForegroundRun, !autoContinuation else { return current }
        return submitted
    }
    enum CancelTarget: Equatable { case job, foreground, none }
    /// A receipt-scoped cancel stops exactly the run that owns that receipt.
    static func cancelTarget(receipt: String, jobOwnsReceipt: Bool, foregroundReceipt: String?) -> CancelTarget {
        if jobOwnsReceipt { return .job }
        return foregroundReceipt == receipt ? .foreground : .none
    }
}

/// An explicit direct-control target: `app` (name or bundle id) and `tab` (browser tab id or URL substring).
enum ControlTargetSelection {
    /// The running app named exactly (case-insensitive name or bundle id); nil when none or ambiguous.
    static func app(named query: String, among apps: [(name: String?, bundleID: String?)]) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        let byBundle = apps.indices.filter { apps[$0].bundleID?.lowercased() == q }
        if byBundle.count == 1 { return byBundle[0] }
        let byName = apps.indices.filter { apps[$0].name?.lowercased() == q }
        return byName.count == 1 ? byName[0] : nil
    }

    /// The tab named by id (all digits) or a case-insensitive URL substring; nil when none matches or several do.
    static func tab(_ query: String, among tabs: [(id: Int, url: String)]) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let id = Int(q), q.allSatisfy(\.isNumber) { return tabs.contains { $0.id == id } ? id : nil }
        let matches = tabs.filter { $0.url.range(of: q, options: .caseInsensitive) != nil }
        return matches.count == 1 ? matches[0].id : nil
    }
}

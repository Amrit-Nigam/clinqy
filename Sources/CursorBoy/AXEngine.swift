import AppKit
import ApplicationServices

/// A clickable/typeable element found in the frontmost app's accessibility tree.
struct UIElementInfo {
    let id: String
    let role: String
    let label: String
    /// Frame in global top-left-origin coordinates (the same space CGEvent uses).
    let frame: CGRect
    let element: AXUIElement

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

enum AXEngine {
    static let userName = NSFullUserName()

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTab", "AXComboBox",
        "AXMenuBarItem", "AXDisclosureTriangle", "AXCell", "AXRow", "AXImage", "AXSegmentedControl",
        "AXStaticText", "AXMenuItem", "AXHeading", "AXGroup",
    ]

    /// Collects visible actionable elements from `app`, breadth-first, up to `limit`.
    static func elements(of app: NSRunningApplication, limit: Int = 200) -> [UIElementInfo] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)

        var roots: [AXUIElement] = []
        if let window: AXUIElement = attr(root, kAXFocusedWindowAttribute) {
            roots.append(window)
        } else if let windows: [AXUIElement] = attr(root, kAXWindowsAttribute), let first = windows.first {
            roots.append(first)
        }
        if let menuBar: AXUIElement = attr(root, kAXMenuBarAttribute) { roots.append(menuBar) }

        let screenBounds = NSScreen.screens.reduce(CGRect.null) { $0.union(flipped($1.frame)) }
        var queue = roots.map { ($0, 0) }
        var found: [UIElementInfo] = []
        var visited = 0

        while !queue.isEmpty, found.count < limit, visited < 4000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role: String = attr(element, kAXRoleAttribute) ?? ""

            if actionableRoles.contains(role), let frame = frame(of: element),
               frame.width > 2, frame.height > 2, screenBounds.intersects(frame) {
                let label = label(of: element, role: role)
                // Unlabeled images/rows/cells are noise; unlabeled inputs are still useful.
                let isInput = role == "AXTextField" || role == "AXTextArea" || role.contains("Search") || role == "AXComboBox"
                if !label.isEmpty || isInput {
                    found.append(UIElementInfo(
                        id: "e\(found.count)", role: role,
                        label: label.isEmpty ? "(unlabeled \(role.dropFirst(2)))" : label,
                        frame: frame, element: element))
                }
            }

            // Don't descend into closed menus from the menu bar.
            if role == "AXMenuBarItem" { continue }
            if depth < 30, let children: [AXUIElement] = attr(element, kAXChildrenAttribute) {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return found
    }

    private static func label(of element: AXUIElement, role: String) -> String {
        var parts: [String] = []
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute] {
            if let s: String = attr(element, key), !s.isEmpty, !parts.contains(s) { parts.append(s) }
        }
        if parts.isEmpty, let v: String = attr(element, kAXValueAttribute), !v.isEmpty {
            parts.append(String(v.prefix(80)))
        }
        if parts.isEmpty, let titleEl: AXUIElement = attr(element, kAXTitleUIElementAttribute),
           let t: String = attr(titleEl, kAXValueAttribute) ?? attr(titleEl, kAXTitleAttribute) {
            parts.append(t)
        }
        // Rows and cells often keep their text in a child static text.
        if parts.isEmpty, role == "AXCell" || role == "AXRow",
           let children: [AXUIElement] = attr(element, kAXChildrenAttribute) {
            for child in children.prefix(4) {
                if let v: String = attr(child, kAXValueAttribute), !v.isEmpty { parts.append(v); break }
            }
        }
        let joined = parts.joined(separator: " — ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{200F}", with: "")
        // Apps call the user's own chat "You"; name it so models can match "message amrit nigam".
        let named = joined.replacingOccurrences(of: #"with You\b"#, with: "with \(userName) (You)", options: .regularExpression)
        return String(named.prefix(140))
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = attr(element, kAXPositionAttribute),
              let sizeValue: AXValue = attr(element, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private static func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Converts a Cocoa (bottom-left origin) rect to global top-left coordinates.
    static func flipped(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Title of the focused window and a description of the focused element, for Jev's state.
    static func focusSummary(of app: NSRunningApplication) -> (window: String, focused: String) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var window = ""
        if let w: AXUIElement = attr(root, kAXFocusedWindowAttribute), let t: String = attr(w, kAXTitleAttribute) {
            window = t
        }
        var focused = "nothing"
        if let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) {
            let role: String = attr(f, kAXRoleAttribute) ?? "?"
            focused = "\(role.dropFirst(2)): \(label(of: f, role: role))"
        }
        return (window, focused)
    }

    /// Current text value of the focused element, used to verify typing landed.
    static func focusedValue(of app: NSRunningApplication) -> String? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) else { return nil }
        return attr(f, kAXValueAttribute)
    }

    /// Cheap signature of what's on screen; if it doesn't change after an action, the action missed.
    static func fingerprint(of app: NSRunningApplication) -> Int {
        // Light walk: role + title + description + value only (a full label read is ~3x slower).
        var hasher = Hasher()
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var queue: [AXUIElement] = []
        if let window: AXUIElement = attr(root, kAXFocusedWindowAttribute) { queue.append(window) }
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let el = queue.removeFirst()
            visited += 1
            hasher.combine(attr(el, kAXRoleAttribute) as String?)
            hasher.combine(attr(el, kAXTitleAttribute) as String?)
            hasher.combine(attr(el, kAXDescriptionAttribute) as String?)
            hasher.combine(attr(el, kAXValueAttribute) as String?)
            if let children: [AXUIElement] = attr(el, kAXChildrenAttribute) { queue.append(contentsOf: children) }
        }
        if let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) {
            hasher.combine(attr(f, kAXRoleAttribute) as String?)
            hasher.combine(attr(f, kAXValueAttribute) as String?)
        }
        return hasher.finalize()
    }

    // MARK: - Input

    static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(15_000)
        up?.post(tap: .cghidEventTap)
    }

    /// Keyboard events go to `pid` when set (so they can't land in whatever window happens to be focused).
    static var targetPid: pid_t?

    private static func post(_ event: CGEvent?) {
        guard let event else { return }
        if let pid = targetPid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
    }

    /// Presses a control through Accessibility (exact, no mouse movement). Returns false if unsupported.
    static func axPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String], actions.contains(kAXPressAction as String) else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Gives keyboard focus to a text box through Accessibility.
    static func focus(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for chunk in text.chunked(by: 16) {
            let utf16 = Array(chunk.utf16)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                post(event)
            }
            usleep(4_000)
        }
    }

    /// Enters text reliably: short text is typed, longer text is pasted (fast keystroke bursts get dropped),
    /// with the user's clipboard restored afterwards.
    static func enter(_ text: String) {
        guard text.count > 12 else { type(text); return }
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(text, forType: .string)
        press(0x09, flags: .maskCommand)   // ⌘V
        usleep(250_000)
        board.clearContents()
        if let saved { board.setString(saved, forType: .string) }
    }

    /// True if the focused field holds `text` (or reports nothing, as some fields don't).
    static func fieldHolds(_ text: String, in app: NSRunningApplication) -> Bool {
        guard let value = focusedValue(of: app), !value.isEmpty else { return true }
        let clean = { (s: String) in s.filter { !$0.isWhitespace } }
        return clean(value).contains(clean(text))
    }

    static func pressReturn() { press(0x24) }

    /// Scrolls the app's focused window; positive is up.
    static func scroll(_ lines: Int32, in app: NSRunningApplication) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var point = CGPoint(x: 600, y: 400)
        if let w: AXUIElement = attr(root, kAXFocusedWindowAttribute), let f = frame(of: w) {
            point = CGPoint(x: f.midX, y: f.midY)
        }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
        event?.location = point
        event?.post(tap: .cghidEventTap)
    }

    static func selectAll() { press(0x00, flags: .maskCommand) }

    static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
            event?.flags = flags
            post(event)
        }
    }
}

private extension String {
    func chunked(by size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in self {
            current.append(ch)
            if current.count >= size { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

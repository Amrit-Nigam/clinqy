import AppKit
import ApplicationServices

/// A clickable/typeable element found in the frontmost app's accessibility tree.
struct UIElementInfo: @unchecked Sendable {
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

    static var isTrusted: Bool {
        // Global cap on how long any Accessibility call may block (default is 6 s per call).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        return AXIsProcessTrusted()
    }

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

    nonisolated(unsafe) private static var enabledElectron = Set<pid_t>()

    /// Electron apps (Cursor, VS Code, Slack, Discord…) only publish their UI to Accessibility when asked.
    static func enableManualAccessibility(_ app: NSRunningApplication) {
        guard !enabledElectron.contains(app.processIdentifier) else { return }
        enabledElectron.insert(app.processIdentifier)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

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

    /// US-layout key for each printable ASCII character: (key code, needs Shift).
    private static let charKeys: [Character: (CGKeyCode, Bool)] = {
        var map: [Character: (CGKeyCode, Bool)] = [" ": (0x31, false), "\n": (0x24, false), "\t": (0x30, false)]
        let plain: [(String, CGKeyCode)] = [
            ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05), ("z", 0x06), ("x", 0x07),
            ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D), ("e", 0x0E), ("r", 0x0F), ("y", 0x10),
            ("t", 0x11), ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("6", 0x16), ("5", 0x17), ("=", 0x18),
            ("9", 0x19), ("7", 0x1A), ("-", 0x1B), ("8", 0x1C), ("0", 0x1D), ("]", 0x1E), ("o", 0x1F), ("u", 0x20),
            ("[", 0x21), ("i", 0x22), ("p", 0x23), ("l", 0x25), ("j", 0x26), ("'", 0x27), ("k", 0x28), (";", 0x29),
            ("\\", 0x2A), (",", 0x2B), ("/", 0x2C), ("n", 0x2D), ("m", 0x2E), (".", 0x2F), ("`", 0x32),
        ]
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
        ]
        for (ch, code) in plain {
            let c = Character(ch)
            map[c] = (code, false)
            if c.isLetter { map[Character(ch.uppercased())] = (code, true) }
        }
        for (ch, base) in shifted { if let (code, _) = map[base] { map[ch] = (code, true) } }
        return map
    }()

    /// Types text one character at a time the way a keyboard does: the real key (with Shift when needed)
    /// plus the character itself, so apps that read key codes and apps that read text both get it right.
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for ch in text {
            let utf16 = Array(String(ch).utf16)
            let (code, shift) = charKeys[ch] ?? (0, false)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown)
                event?.flags = shift ? .maskShift : []
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

    /// Pastes text through the clipboard, restoring what was there.
    static func paste(_ text: String) {
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(text, forType: .string)
        press(0x09, flags: .maskCommand)
        usleep(250_000)
        board.clearContents()
        if let saved { board.setString(saved, forType: .string) }
    }

    /// Frame of the app's focused (or first) window.
    static func windowFrame(of app: NSRunningApplication) -> CGRect? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        if let w: AXUIElement = attr(root, kAXFocusedWindowAttribute) { return frame(of: w) }
        if let ws: [AXUIElement] = attr(root, kAXWindowsAttribute), let w = ws.first { return frame(of: w) }
        return nil
    }

    /// Sets the focused text field's value directly (for fields that ignore synthetic keystrokes).
    static func setFocusedValue(_ text: String, in app: NSRunningApplication) -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) else { return false }
        return AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, text as CFString) == .success
    }

    /// Frame of the element that has keyboard focus.
    static func focusedFrame(of app: NSRunningApplication) -> CGRect? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) else { return nil }
        return frame(of: f)
    }

    /// The Dock icon for an app, if it's in the Dock.
    static func dockItem(named name: String) -> (element: AXUIElement, frame: CGRect)? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        let wanted = name.lowercased()
        for list in (attr(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for item in (attr(list, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                guard let title: String = attr(item, kAXTitleAttribute),
                      title.replacingOccurrences(of: "\u{200E}", with: "").lowercased() == wanted,
                      let f = frame(of: item) else { continue }
                return (item, f)
            }
        }
        return nil
    }

    /// True if the focused field holds `text` (or reports nothing, as some fields don't).
    /// True if the focused field holds `text`, allowing for autocorrect, capitalisation and smart punctuation
    /// (or if the field doesn't report its contents at all, as some don't).
    static func fieldHolds(_ text: String, in app: NSRunningApplication) -> Bool {
        guard let value = focusedValue(of: app), !value.isEmpty else { return true }
        let clean = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let want = clean(text), have = clean(value)
        if want.isEmpty || have.contains(want) { return true }
        // Mostly there (a word autocorrected) counts; a clearly partial or missing text doesn't.
        let common = zip(want, have.suffix(want.count)).filter { $0 == $1 }.count
        return Double(common) / Double(want.count) >= 0.85
    }

    /// Current frame of an element, or nil if it no longer exists.
    static func liveFrame(of element: AXUIElement) -> CGRect? { frame(of: element) }

    /// On-screen frame of the browser's page area (the largest AXWebArea in the focused window).
    static func webAreaFrame(of app: NSRunningApplication) -> CGRect? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = attr(root, kAXFocusedWindowAttribute) else { return nil }
        var queue = [window], best: CGRect?, visited = 0
        while !queue.isEmpty, visited < 1500 {
            let el = queue.removeFirst()
            visited += 1
            if (attr(el, kAXRoleAttribute) as String?) == "AXWebArea", let f = frame(of: el), f.width > 100 {
                if best.map({ f.width * f.height > $0.width * $0.height }) ?? true { best = f }
                continue   // don't descend into page content
            }
            if let children: [AXUIElement] = attr(el, kAXChildrenAttribute) { queue.append(contentsOf: children) }
        }
        return best
    }

    /// Loose text comparison that tolerates autocorrect, case and punctuation.
    static func similar(_ have: String, _ want: String) -> Bool {
        let clean = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let w = clean(want), h = clean(have)
        if w.isEmpty || h.contains(w) { return true }
        let common = zip(w, h.suffix(w.count)).filter { $0 == $1 }.count
        return Double(common) / Double(w.count) >= 0.85
    }

    /// Text currently selected in the app's focused element, if any.
    static func selectedText(of app: NSRunningApplication) -> String? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute),
              let text: String = attr(f, kAXSelectedTextAttribute) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The file the app's focused window has open (Preview, TextEdit, Pages, Word…), if it says.
    static func documentURL(of app: NSRunningApplication) -> URL? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let w: AXUIElement = attr(root, kAXFocusedWindowAttribute) ?? (attr(root, kAXWindowsAttribute) as [AXUIElement]?)?.first,
              let doc: String = attr(w, kAXDocumentAttribute), let url = URL(string: doc) else { return nil }
        return url
    }

    /// Role and label of whatever is on screen at a point (for recording what the user clicked).
    static func describe(at point: CGPoint) -> (role: String, label: String) {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return ("something", "") }
        let role: String = attr(element, kAXRoleAttribute) ?? "AXUnknown"
        var text = label(of: element, role: role)
        // Many click targets are an unlabeled image or text inside a labeled button/row: use the parent's label.
        if text.isEmpty, let parent: AXUIElement = attr(element, kAXParentAttribute) {
            let pr: String = attr(parent, kAXRoleAttribute) ?? ""
            text = label(of: parent, role: pr)
        }
        return (String(role.dropFirst(2)), text)
    }

    /// Role and label of the focused element (for recording where the user typed).
    static func focusedDescription(of app: NSRunningApplication) -> (role: String, label: String) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) else { return ("field", "") }
        let role: String = attr(f, kAXRoleAttribute) ?? "AXTextField"
        let subrole: String = attr(f, kAXSubroleAttribute) ?? ""
        return (subrole == "AXSecureTextField" ? "AXSecureTextField" : String(role.dropFirst(2)), label(of: f, role: role))
    }

    /// Role of the element with keyboard focus (e.g. "AXTextArea"), if any.
    static func focusedRole(of app: NSRunningApplication) -> String? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f: AXUIElement = attr(root, kAXFocusedUIElementAttribute) else { return nil }
        return attr(f, kAXRoleAttribute)
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

    private static let keyCodes: [String: CGKeyCode] = [
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
        "esc": 0x35, "escape": 0x35, "forwarddelete": 0x75, "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
        "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
        "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    /// Presses a combo like "cmd+shift+t", "return" or "ctrl+a". Returns false for an unknown key.
    @discardableResult
    static func press(combo: String) -> Bool {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: key = keyCodes[part]
            }
        }
        guard let key else { return false }
        press(key, flags: flags)
        return true
    }

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

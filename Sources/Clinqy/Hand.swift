import AppKit

/// Carries out actions the way a person would, with the buddy as the visible hand: it travels to the Dock
/// to open an app, to the address bar to go somewhere, types at a human rhythm, and hovers before it clicks.
/// Your real mouse is left where you put it.
@MainActor
final class Hand {
    private let buddy: Buddy
    /// Extra time to stay put at the end (e.g. while pointing something out).
    var lingerBeforeHome: TimeInterval = 0
    /// The run's request, so session-ending chords are pressed only when it asked for them.
    var request = ""
    /// Set when switching apps was the point of the task ("open Spotify"): the run's end then leaves it in front.
    var keepFrontApp = false
    /// Why Hand last refused to act (password field, sensitive app, blocked chord, stale target), for the step's message.
    private(set) var refusal: String?

    private var runCursor: CGPoint?
    private var runFrontApp: NSRunningApplication?
    /// Where Clinqy last left the real pointer without putting it back (scrolling moves it).
    private var cursorLeftAt: CGPoint?

    init(buddy: Buddy) { self.buddy = buddy }

    private func trace(_ s: String) {
        if ProcessInfo.processInfo.environment["CB_TRACE"] != nil { print("    · \(s)"); fflush(stdout) }
    }

    private func refuse(_ why: String) -> String {
        refusal = why
        trace("refused: \(why)")
        return why
    }

    // MARK: - Run

    /// Notes the pointer and frontmost app so `endRun` can put things back the way the user had them.
    func beginRun(request: String) {
        self.request = request
        keepFrontApp = false
        refusal = nil
        cursorLeftAt = nil
        runCursor = Buddy.mouse()
        let front = NSWorkspace.shared.frontmostApplication
        runFrontApp = front?.processIdentifier == getpid() ? nil : front
    }

    /// Releases any button left down, puts the pointer back if Clinqy moved it and the user hasn't since, and
    /// brings back the app the user was in (unless `keepFrontApp`). Safe to call on cancel and failure.
    func endRun() {
        Self.releaseButtons()
        if let start = runCursor, let left = cursorLeftAt, Self.near(Buddy.mouse(), left, 2) {
            CGWarpMouseCursorPosition(start)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        if !keepFrontApp, let app = runFrontApp, !app.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            // Plain activate() is ignored while Clinqy isn't frontmost; bringToFront opens it, which always works.
            Task { await Launcher.bringToFront(app) }
        }
        runCursor = nil
        runFrontApp = nil
        cursorLeftAt = nil
    }

    // MARK: - Pointer

    /// How a click at a point is delivered.
    enum ClickMode: Sendable {
        /// Moves the real pointer, clicks, and puts it back. The default: web pages and many apps trust only real events.
        case real
        /// Posted straight to the app (postToPid): the pointer never moves, and the window needn't be frontmost.
        case pid
        /// Private SkyLight path for Chromium/Electron windows in the background. Only with BACKGROUND_CLICKS=1;
        /// never picked automatically.
        case background
    }

    /// Clicks an element: Accessibility press first, a real click if that did nothing.
    /// Returns why it didn't click (something else now at that spot), or nil.
    @discardableResult
    func click(_ el: UIElementInfo, in app: NSRunningApplication, fingerprint: Int) async -> String? {
        await buddy.travel(to: el.center, framing: el.frame)
        try? await Task.sleep(for: .milliseconds(80))   // aim
        buddy.click()
        let element = el.element
        var pressed = await Task.detached { AXEngine.axPress(element) }.value
        if pressed {
            pressed = false
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(60))
                if await AXEngine.fingerprintAsync(of: app) != fingerprint { pressed = true; break }
            }
        }
        if !pressed {
            if let why = await hitCheck(el.center, pid: app.processIdentifier, windowOf: element) { return refuse(why) }
            realClick(at: el.center)
        }
        return nil
    }

    /// Clicks a screen point, with the buddy travelling there first. Given the target `pid` (and the `window` as
    /// scanned), first checks the window is unchanged and the point still shows that app, so a moved window or a
    /// popup that slid in isn't clicked by mistake. Returns why it didn't click (re-scan and retry), or nil.
    @discardableResult
    func click(at point: CGPoint, pid: pid_t? = nil, window: WindowSnapshot? = nil, mode: ClickMode = .real) async -> String? {
        if let why = window?.staleness() { return refuse(why) }
        if let pid, let why = await hitCheck(point, pid: pid, window: window?.element) { return refuse(why) }
        await buddy.travel(to: point)
        try? await Task.sleep(for: .milliseconds(80))
        buddy.click()
        switch mode {
        case .real:
            realClick(at: point)
        case .pid:
            guard let pid else { return refuse("a click sent to an app needs its pid") }
            Self.postClick(at: point, pid: pid)
        case .background:
            guard let pid, let (id, frame) = Self.windowInfo(pid: pid, containing: point) else {
                return refuse("no window of the target app at that point for a background click")
            }
            if let why = SkyLight.click(at: point, pid: pid, window: id, frame: frame) { return refuse(why) }
        }
        return nil
    }

    /// Puts the caret in a text box: travel, click, focus. Returns why it didn't, or nil.
    @discardableResult
    func focus(_ el: UIElementInfo, in app: NSRunningApplication) async -> String? {
        await buddy.travel(to: el.center, framing: el.frame)
        try? await Task.sleep(for: .milliseconds(90))
        buddy.click()
        if let why = await hitCheck(el.center, pid: app.processIdentifier, windowOf: el.element) {
            // Something covers the field: focusing through Accessibility alone is still safe.
            _ = AXEngine.focus(el.element)
            return Self.isTextRole(AXEngine.focusedRole(of: app)) ? nil : refuse(why)
        }
        realClick(at: el.center)
        _ = AXEngine.focus(el.element)
        try? await Task.sleep(for: .milliseconds(120))
        // If the caret didn't land in a text box, click once more like a person would.
        if !Self.isTextRole(AXEngine.focusedRole(of: app)) {
            realClick(at: el.center)
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    static func isTextRole(_ role: String?) -> Bool {
        guard let role else { return true }   // unknown: don't second-guess
        return ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea"].contains(role)
    }

    /// A real click, with the user's pointer put back afterwards.
    private func realClick(at point: CGPoint) {
        let saved = Buddy.mouse()
        Self.postRealClick(at: point)
        usleep(25_000)
        CGWarpMouseCursorPosition(saved)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Down and up through the HID stream; the up is posted however the down went, so the button is never left held.
    nonisolated private static func postRealClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        defer {
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        usleep(15_000)
    }

    /// A click posted to the app itself: the real pointer stays put. The window number fields let AppKit route it
    /// to the right window even when it isn't frontmost.
    nonisolated private static func postClick(at point: CGPoint, pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let window = windowInfo(pid: pid, containing: point)?.id
        func post(_ type: CGEventType) {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            if let window {
                e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
                e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
            }
            e.postToPid(pid)
        }
        post(.leftMouseDown)
        defer { post(.leftMouseUp) }
        usleep(15_000)
    }

    /// Lets go of any mouse button still down (a click interrupted by a crash, cancel or error).
    nonisolated static func releaseButtons() {
        let point = CGEvent(source: nil)?.location ?? .zero
        for (button, type) in [(CGMouseButton.left, CGEventType.leftMouseUp), (.right, .rightMouseUp)]
        where CGEventSource.buttonState(.combinedSessionState, button: button) {
            CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                    mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Pre-click checks

    /// What's under `point` must belong to `pid` (and to the element's window, when known), or the click would
    /// land on something else: another app's popup, a window that moved. Runs off the main thread.
    private func hitCheck(_ point: CGPoint, pid: pid_t, windowOf element: AXUIElement) async -> String? {
        let window: AXUIElement? = Self.axAttr(element, kAXWindowAttribute)
        return await hitCheck(point, pid: pid, window: window)
    }

    private func hitCheck(_ point: CGPoint, pid: pid_t, window: AXUIElement?) async -> String? {
        struct Box: @unchecked Sendable { let window: AXUIElement? }
        let box = Box(window: window)
        return await Task.detached { Self.hitMismatch(at: point, pid: pid, window: box.window) }.value
    }

    /// Why the element at `point` isn't the target app's (or target window's), or nil. Inconclusive answers
    /// (no element, Clinqy's own overlay) pass: this guards against clicking the wrong thing, not against clicking.
    nonisolated static func hitMismatch(at point: CGPoint, pid: pid_t, window: AXUIElement?) -> String? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(hit, &owner) == .success, owner != getpid() else { return nil }
        // Web content can answer from the browser's own helper process (Safari's WebContent, Chromium helpers).
        let helper = NSRunningApplication(processIdentifier: owner).map { app in
            let id = app.bundleIdentifier?.lowercased() ?? ""
            return id.hasPrefix("com.apple.webkit") || id.contains(".helper") || id.contains("framework")
        } ?? true
        if owner != pid, !helper {
            let other = NSRunningApplication(processIdentifier: owner)?.cleanName ?? "another app"
            let target = NSRunningApplication(processIdentifier: pid)?.cleanName ?? "the target app"
            return "\(other) is on top at that spot, not \(target); look again before clicking"
        }
        if let window, let hitWindow: AXUIElement = axAttr(hit, kAXWindowAttribute), !CFEqual(hitWindow, window) {
            return "a different \(NSRunningApplication(processIdentifier: pid)?.cleanName ?? "app") window is at that spot now; look again"
        }
        return nil
    }

    /// A window as it was when scanned, to check it's still there and in the same place before clicking into it.
    struct WindowSnapshot: @unchecked Sendable {
        let element: AXUIElement
        let frame: CGRect
        let pid: pid_t

        /// The app's focused (or first) window, as it is now.
        static func capture(_ app: NSRunningApplication) -> WindowSnapshot? {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            let window: AXUIElement? = axAttr(root, kAXFocusedWindowAttribute)
                ?? (axAttr(root, kAXWindowsAttribute) as [AXUIElement]?)?.first
            guard let window, let frame = AXEngine.liveFrame(of: window) else { return nil }
            return WindowSnapshot(element: window, frame: frame, pid: app.processIdentifier)
        }

        /// Why the window no longer matches the scan (closed, or moved/resized by more than 2 pt), or nil.
        func staleness() -> String? {
            guard let now = AXEngine.liveFrame(of: element) else { return "the window was closed since the last look; look again" }
            let moved = abs(now.minX - frame.minX) > 2 || abs(now.minY - frame.minY) > 2
                || abs(now.width - frame.width) > 2 || abs(now.height - frame.height) > 2
            return moved ? "the window moved or resized since the last look; look again" : nil
        }
    }

    /// The on-screen normal-level window of `pid` containing `point`: its number and bounds.
    nonisolated static func windowInfo(pid: pid_t, containing point: CGPoint) -> (id: CGWindowID, frame: CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list where (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid
            && info[kCGWindowLayer as String] as? Int == 0 {
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point) else { continue }
            return (CGWindowID(id), frame)
        }
        return nil
    }

    nonisolated private static func axAttr<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    nonisolated private static func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    /// Presses a combo. Refuses (false, with `refusal` set) a lock/log-out/force-quit chord the request didn't ask for.
    @discardableResult
    func press(_ keys: String) -> Bool {
        refusal = nil
        if let why = Safety.blockedChord(keys, request: request) { _ = refuse(why); return false }
        buddy.click()
        return AXEngine.press(combo: keys)
    }

    func scroll(up: Bool, in app: NSRunningApplication) async {
        if let frame = AXEngine.windowFrame(of: app) {
            await buddy.travel(to: CGPoint(x: frame.midX, y: frame.midY))
        }
        for _ in 0..<4 {
            AXEngine.scroll(up ? 3 : -3, in: app)
            try? await Task.sleep(for: .milliseconds(70))
        }
        // Scrolling moves the real pointer to the window's middle; the run's end puts it back if the user doesn't.
        cursorLeftAt = Buddy.mouse()
        try? await Task.sleep(for: .milliseconds(200))
    }


    // MARK: - Keyboard

    /// Replaces the focused field's text, typed at a human rhythm, and confirms it landed.
    /// Falls back to pasting once; never leaves half a message behind for a Return to send.
    func type(_ text: String, in app: NSRunningApplication) async -> Bool {
        refusal = nil
        buddy.setTyping(true)
        defer { buddy.setTyping(false) }
        // Browser editors whose text Accessibility can't see (Google Docs shows only zero-width spaces): typing
        // can't be checked, and the check-then-clear fallback would wipe the document. Paste it once, fast.
        let invisible = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}"))
        if Launcher.isBrowser(app), (AXEngine.focusedValue(of: app) ?? "").trimmingCharacters(in: invisible).isEmpty {
            AXEngine.targetPid = app.processIdentifier
            defer { AXEngine.targetPid = nil }
            AXEngine.paste(text)
            return true
        }
        // Long text (an answer list, a write-up) is pasted: typing 2,000 characters takes minutes and trips the
        // watchdog halfway, leaving half a message behind. Pasted line breaks don't send in chat apps.
        if text.count > 300, !Self.codeEditorIDs.contains(app.bundleIdentifier ?? "") {
            AXEngine.targetPid = app.processIdentifier
            defer { AXEngine.targetPid = nil }
            if !(AXEngine.focusedValue(of: app) ?? "").isEmpty {
                AXEngine.selectAll()
                try? await Task.sleep(for: .milliseconds(60))
            }
            AXEngine.paste(text)
            return await landed(text, in: app)
        }
        // Multi-line text is still typed (that's the point of watching it), with Shift+Return for line breaks.
        if text.contains("\n") {
            AXEngine.targetPid = app.processIdentifier
            defer { AXEngine.targetPid = nil }
            AXEngine.selectAll()
            try? await Task.sleep(for: .milliseconds(80))
            let code = Self.codeEditorIDs.contains(app.bundleIdentifier ?? "")
            await enterText(text, codeEditor: code)
            return await landed(text, in: app)
        }
        // Replace existing text only when there is some: ⌘A where there's nothing to select just beeps.
        if let existing = AXEngine.focusedValue(of: app), !existing.isEmpty {
            AXEngine.selectAll()
            try? await Task.sleep(for: .milliseconds(60))
        }

        // Keys go only to the target app, never to whatever else might grab focus meanwhile.
        AXEngine.targetPid = app.processIdentifier
        defer { AXEngine.targetPid = nil }
        await keystrokes(text)
        if Task.isCancelled || refusal != nil { return false }
        if await landed(text, in: app) { return true }

        // Some apps only accept keys through the system stream: retry by pasting that way,
        // replacing (never appending to) what's there.
        AXEngine.targetPid = nil
        AXEngine.selectAll()
        try? await Task.sleep(for: .milliseconds(60))
        AXEngine.paste(text)
        if await landed(text, in: app) { return true }
        AXEngine.selectAll()
        AXEngine.press(0x33)
        return false
    }

    /// Apps whose editors auto-indent what's typed.
    static let codeEditorIDs: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.sublimetext.4", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.google.android.studio",
    ]

    /// Enters text into the focused field, always typed so it can be watched.
    /// Line breaks are Shift+Return (a new line without sending in chat apps). In code editors, which re-indent
    /// typed code, each line is typed without its leading spaces and the exact code is swapped in at the end.
    func enterText(_ text: String, codeEditor: Bool = false) async {
        guard text.contains("\n") else { return await keystrokes(text) }
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if Task.isCancelled { return }
            if i > 0 {
                AXEngine.press(combo: "shift+return")
                try? await Task.sleep(for: .milliseconds(60))
            }
            await keystrokes(codeEditor ? line.trimmingCharacters(in: .whitespaces) : line)
        }
        if codeEditor {
            // The editor's auto-indent and auto-closing brackets have had their say; now make it exactly right.
            try? await Task.sleep(for: .milliseconds(200))
            AXEngine.selectAll()
            try? await Task.sleep(for: .milliseconds(60))
            AXEngine.paste(text)
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Types at a human rhythm (keys go wherever AXEngine.targetPid points). Stops, with `refusal` set, the moment
    /// a password field takes secure input: focus can move mid-word.
    func keystrokes(_ text: String) async {
        let base = text.count > 80 ? 10.0 : text.count > 30 ? 20.0 : 32.0
        refusal = nil
        for ch in text {
            if Task.isCancelled { return }
            AXEngine.type(String(ch))
            var ms = base + Double.random(in: 0...(base * 0.9))
            if ch == " " { ms += base * 0.5 }
            if ".,!?".contains(ch) { ms += 70 }
            try? await Task.sleep(for: .milliseconds(Int(ms)))
        }
    }

    private func landed(_ text: String, in app: NSRunningApplication) async -> Bool {
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(70))
            if AXEngine.fieldHolds(text, in: app) { return true }
        }
        return false
    }

    // MARK: - Apps

    /// Opens an app like a person: click its Dock icon, or use Spotlight if it isn't in the Dock.
    func openApp(named name: String) async -> NSRunningApplication? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let running = NSWorkspace.shared.runningApplications.first { $0.cleanName?.lowercased() == wanted }
        let url = running?.bundleURL ?? Launcher.find(named: wanted)
        guard let url else { return nil }
        let appName = url.deletingPathExtension().lastPathComponent

        if let running, NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier,
           AXEngine.windowFrame(of: running) != nil {
            return running
        }

        trace("openApp \(appName) dock=\(AXEngine.dockItem(named: appName) != nil)")
        if let dock = AXEngine.dockItem(named: appName) {
            await buddy.travel(to: CGPoint(x: dock.frame.midX, y: dock.frame.midY), framing: dock.frame)
            try? await Task.sleep(for: .milliseconds(140))
            buddy.click()
            let item = dock.element
            _ = await Task.detached { AXEngine.axPress(item) }.value
        } else {
            await spotlight(appName)
        }
        if let app = await waitForFront(bundleURL: url, seconds: 5) { return app }
        return await Launcher.launch(url)
    }

    private func spotlight(_ query: String) async {
        // Typing blind into a password prompt is worse than launching the app directly (the caller falls back).
        guard Safety.secureInputBlock() == nil else { return }
        let screen = NSScreen.main?.frame ?? .zero
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let spot = CGPoint(x: screen.midX - 180, y: primaryHeight - screen.maxY + screen.height * 0.3)
        await buddy.travel(to: spot)
        press("cmd+space")
        try? await Task.sleep(for: .milliseconds(450))
        buddy.setTyping(true)
        for ch in query {
            AXEngine.type(String(ch))
            try? await Task.sleep(for: .milliseconds(Int.random(in: 45...95)))
        }
        buddy.setTyping(false)
        try? await Task.sleep(for: .milliseconds(550))
        press("return")
    }

    private func waitForFront(bundleURL: URL, seconds: Double) async -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleURL == bundleURL {
                // Give it a moment to put a window up.
                for _ in 0..<20 where AXEngine.windowFrame(of: front) == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if AXEngine.windowFrame(of: front) == nil { return nil }
                return front
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }

    // MARK: - Web

    /// Goes to a website like a person: bring up the browser, open a tab, type the address, press Return.
    func openURL(_ url: URL, current: NSRunningApplication?, newTab: Bool = true) async -> NSRunningApplication? {
        var browser: NSRunningApplication?
        if let current, Launcher.isBrowser(current) {
            await Launcher.bringToFront(current)
            browser = current
        } else if let name = Launcher.defaultBrowserName {
            browser = await openApp(named: name)
        }
        guard let browser else {
            await Launcher.openURL(url)
            return NSWorkspace.shared.frontmostApplication
        }

        trace("browser \(browser.cleanName ?? "?") front=\(NSWorkspace.shared.frontmostApplication?.cleanName ?? "-")")
        // A new tab for a fresh destination; otherwise edit the current tab's address like a person would.
        press(newTab ? "cmd+t" : "cmd+l")
        try? await Task.sleep(for: .milliseconds(420))
        trace("after cmd+t focused=\(AXEngine.focusedFrame(of: browser).map { "\($0)" } ?? "nil")")
        // Go to where the address goes: the focused field if it's plausibly the address bar (top of the
        // window), otherwise Arc's command bar in the upper middle, or the usual toolbar spot.
        let window = AXEngine.windowFrame(of: browser)
        if let field = AXEngine.focusedFrame(of: browser), field.width > 40,
           let window, field.midY < window.minY + window.height * 0.4 {
            await buddy.travel(to: CGPoint(x: field.minX + min(80, field.width / 2), y: field.midY), framing: field)
        } else if let window {
            let arc = browser.bundleIdentifier == "company.thebrowser.Browser"
            await buddy.travel(to: CGPoint(x: window.midX - (arc ? 200 : 0), y: window.minY + (arc ? window.height * 0.3 : 44)))
        }

        trace("traveled; front=\(NSWorkspace.shared.frontmostApplication?.cleanName ?? "-")")
        var address = url.absoluteString
        for prefix in ["https://www.", "https://", "http://"] where address.hasPrefix(prefix) {
            address = String(address.dropFirst(prefix.count))
            break
        }
        if address.hasSuffix("/") { address.removeLast() }
        if Safety.secureInputBlock() != nil {
            press("esc")
            await Launcher.openURL(url)
            return browser
        }
        buddy.setTyping(true)
        // Deliver keys straight to the browser so they can't land in some other window.
        AXEngine.targetPid = browser.processIdentifier
        for ch in address {
            AXEngine.type(String(ch))
            try? await Task.sleep(for: .milliseconds(Int.random(in: 22...60)))
        }
        AXEngine.targetPid = nil
        buddy.setTyping(false)
        try? await Task.sleep(for: .milliseconds(150))
        let value = AXEngine.focusedValue(of: browser) ?? ""
        trace("typed; focused value=\(value.debugDescription)")

        // If the keys went astray, fill the field directly; failing that, open the tab through the browser.
        // Arc's command bar reports an empty value even when the text is there, so only a readable
        // mismatch counts as a miss.
        if !value.isEmpty, !value.lowercased().contains(address.prefix(6).lowercased()) {
            if AXEngine.setFocusedValue(address, in: browser),
               (AXEngine.focusedValue(of: browser) ?? "").lowercased().contains(address.prefix(6).lowercased()) {
                trace("filled field via accessibility")
            } else {
                trace("falling back to opening the URL directly")
                AXEngine.press(combo: "esc")
                try? await Task.sleep(for: .milliseconds(150))
                await Launcher.openURL(url)
                try? await Task.sleep(for: .milliseconds(900))
                return browser
            }
        }
        try? await Task.sleep(for: .milliseconds(200))
        press("return")
        // Wait for the page to start loading rather than a fixed pause.
        let startURL = Launcher.frontURLHint
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(100))
            if Launcher.frontURLHint != startURL { break }
        }
        try? await Task.sleep(for: .milliseconds(250))
        trace("returned")
        return browser
    }
}

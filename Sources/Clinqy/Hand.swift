import AppKit

/// Carries out actions the way a person would, with the buddy as the visible hand: it travels to the Dock
/// to open an app, to the address bar to go somewhere, types at a human rhythm, and hovers before it clicks.
/// Your real mouse is left where you put it.
@MainActor
final class Hand {
    private let buddy: Buddy
    /// Extra time to stay put at the end (e.g. while pointing something out).
    var lingerBeforeHome: TimeInterval = 0

    init(buddy: Buddy) { self.buddy = buddy }

    private func trace(_ s: String) {
        if ProcessInfo.processInfo.environment["CB_TRACE"] != nil { print("    · \(s)"); fflush(stdout) }
    }

    // MARK: - Pointer

    func click(_ el: UIElementInfo, in app: NSRunningApplication, fingerprint: Int) async {
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
        if !pressed { realClick(at: el.center) }
    }

    /// A real click at a screen point, with the buddy travelling there first.
    func click(at point: CGPoint) async {
        await buddy.travel(to: point)
        try? await Task.sleep(for: .milliseconds(80))
        buddy.click()
        realClick(at: point)
    }

    /// Puts the caret in a text box: travel, click, focus.
    func focus(_ el: UIElementInfo, in app: NSRunningApplication) async {
        await buddy.travel(to: el.center, framing: el.frame)
        try? await Task.sleep(for: .milliseconds(90))
        buddy.click()
        realClick(at: el.center)
        _ = AXEngine.focus(el.element)
        try? await Task.sleep(for: .milliseconds(120))
        // If the caret didn't land in a text box, click once more like a person would.
        if !Self.isTextRole(AXEngine.focusedRole(of: app)) {
            realClick(at: el.center)
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    static func isTextRole(_ role: String?) -> Bool {
        guard let role else { return true }   // unknown: don't second-guess
        return ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea"].contains(role)
    }

    /// A real click, with the user's pointer put back afterwards.
    private func realClick(at point: CGPoint) {
        let saved = Buddy.mouse()
        AXEngine.click(at: point)
        usleep(25_000)
        CGWarpMouseCursorPosition(saved)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    @discardableResult
    func press(_ keys: String) -> Bool {
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
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - Keyboard

    /// Replaces the focused field's text, typed at a human rhythm, and confirms it landed.
    /// Falls back to pasting once; never leaves half a message behind for a Return to send.
    func type(_ text: String, in app: NSRunningApplication) async -> Bool {
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
        if Task.isCancelled { return false }
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

    /// Types at a human rhythm (keys go wherever AXEngine.targetPid points).
    func keystrokes(_ text: String) async {
        let base = text.count > 80 ? 10.0 : text.count > 30 ? 20.0 : 32.0
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

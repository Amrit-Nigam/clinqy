import AppKit

/// Background tasks use supported direct tools and owned browser tabs only. Native app
/// input, shared clipboard use and arbitrary scripts require attention and an explicit foreground switch.
/// This type also retains experimental native-window bookkeeping; those mechanisms are not a guarantee that
/// arbitrary native apps can run without focus. Local work requires an awake Mac and a running Clinqy process.
@MainActor
enum Background {
    final class State {
        var active = false
        var app: NSRunningApplication?
        var appSince = Date.distantPast
        var tab: BrowserBridge.TabInfo?
        var userWindows: [pid_t: Set<CGWindowID>] = [:]
        var windowsAtStart: Set<CGWindowID> = []
        var usesExtension = true
        var browserOverride: String?
    }
    private static let primaryState = State()
    private static var state: State { TaskExecution.current?.service(State.self, make: State.init) ?? primaryState }
    /// This run is a background run.
    private(set) static var active: Bool { get { state.active } set { state.active = newValue } }
    /// The app the run works in now (its window may well sit behind the user's).
    static var app: NSRunningApplication? {
        get { state.app }
        set {
            state.app = newValue
            // Browser jobs never write the foreground controller's global native-input destination.
            if TaskExecution.current == nil { AXEngine.backgroundPid = active ? newValue?.processIdentifier : nil }
            if newValue != nil { appSince = Date() }
        }
    }
    /// When the run last moved into an app: launching one can bring it forward for a moment, which isn't the user.
    private static var appSince: Date { get { state.appSince } set { state.appSince = newValue } }
    /// Clinqy's tab in its own browser window: every page read and page action of the run is pinned to it.
    static var tab: BrowserBridge.TabInfo? { get { state.tab } set { state.tab = newValue } }
    /// Per app the run worked in: the windows it already had then (the user's), which never move. Any other window
    /// of that app (one the run opened: ⌘N, a dialog) goes to Clinqy's hidden screen.
    private static var userWindows: [pid_t: Set<CGWindowID>] { get { state.userWindows } set { state.userWindows = newValue } }

    /// Every window on the Mac when the run started: a window that appears later in an app the user isn't in (one a
    /// script or shell `open` brought up) is the run's.
    private static var windowsAtStart: Set<CGWindowID> { get { state.windowsAtStart } set { state.windowsAtStart = newValue } }

    /// Notes the windows `app` has before the run first touches it (`had`: as they were before a launch).
    static func track(_ app: NSRunningApplication, had: Set<CGWindowID>? = nil) {
        guard active, userWindows[app.processIdentifier] == nil else { return }
        userWindows[app.processIdentifier] = had ?? Hand.windowIDs(pid: app.processIdentifier)
    }

    /// Moves the windows the run's apps opened since onto Clinqy's hidden screen (browsers place their own).
    static func sweep() {
        guard active, AgentScreen.bounds != nil else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list where info[kCGWindowLayer as String] as? Int == 0 {
            guard let id = (info[kCGWindowNumber as String] as? Int).map(CGWindowID.init), !windowsAtStart.contains(id),
                  let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), pid != front, pid != getpid(),
                  userWindows[pid] == nil, let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular, !Launcher.isBrowser(app) else { continue }
            track(app, had: Hand.windowIDs(pid: pid).intersection(windowsAtStart))
        }
        for (pid, had) in userWindows {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, !Launcher.isBrowser(app) else { continue }
            let onIt = Set(AgentScreen.windows().map(\.id))
            AgentScreen.adopt(app, keep: had.union(onIt))
        }
    }

    /// When a background run last ended (or the app started): the hidden screen is emptied a while after.
    private(set) static var lastRun = Date()
    /// Where the last background run worked, to show the user when they tap its notification.
    private(set) static var last: (tab: BrowserBridge.TabInfo?, app: NSRunningApplication?)

    /// Every request runs in the background: the menu's toggle, or BACKGROUND_TASKS=1.
    static var always: Bool {
        get { UserDefaults.standard.bool(forKey: "backgroundMode") || ["1", "on", "yes", "true"].contains((Config.value("BACKGROUND_TASKS") ?? "").lowercased()) }
        set { UserDefaults.standard.set(newValue, forKey: "backgroundMode") }
    }

    /// The browser background runs work in, by app name (Dashboard → Background, or BACKGROUND_BROWSER): Chrome
    /// unless set otherwise.
    static var browserName: String {
        state.browserOverride ?? Config.value("BACKGROUND_BROWSER") ?? UserDefaults.standard.string(forKey: "backgroundBrowser") ?? "Google Chrome"
    }

    /// Captured at run start so a settings change cannot switch browsers mid-task.
    private(set) static var usesExtension: Bool { get { state.usesExtension } set { state.usesExtension = newValue } }
    static var extensionPreferred: Bool {
        (Config.value("BACKGROUND_WEB_MODE") ?? UserDefaults.standard.string(forKey: "backgroundWebMode") ?? "extension") != "headless"
    }

    static func chooseBrowser(_ name: String?) { state.browserOverride = name }

    static func begin(_ on: Bool) {
        usesExtension = extensionPreferred
        if on {
            BrowserBridge.shared.beginBackgroundRun()
            if !usesExtension { ChromeWorker.shared.runStarted() }
        }
        active = on
        app = nil
        tab = nil
        userWindows = [:]
        let list = on ? CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] : []
        windowsAtStart = Set(list.compactMap { ($0[kCGWindowNumber as String] as? Int).map(CGWindowID.init) })
    }

    static func end() {
        if active, app != nil || tab != nil { last = (tab, app) }
        if active {
            lastRun = Date()
            if usesExtension {
                BrowserBridge.shared.endBackgroundRun()
            } else {
                let keep = tab?.connection == ChromeWorker.shared.identity ? tab?.id : nil
                let run = ChromeWorker.shared.generation
                Task { await ChromeWorker.shared.runEnded(keep: keep, generation: run) }
            }
        }
        active = false
        userWindows = [:]
        app = nil
        tab = nil
    }

    /// Something the user should hear about an app they switched to that the run is using (no window of its own to give).
    static var onBusyApp: (String) -> Void = { _ in }

    /// Watches the user switching apps (Dock, ⌘Tab, a click) for ones whose windows are on Clinqy's hidden screen.
    static func watchSwitches() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in await userSwitched(to: app) }
        }
    }

    /// The user came to an app that has windows on the hidden screen, where they'd see none of it. The run is done
    /// with it: its windows come to them. The run is in it now: Finder or a browser opens a fresh window for them on
    /// their screen while the run keeps its own; other apps (a new window there is a new chat or document) stay with
    /// the run, and the user is told it's theirs when the task is done.
    private static func userSwitched(to app: NSRunningApplication) async {
        let pid = app.processIdentifier
        guard pid != getpid(), AgentScreen.windows().contains(where: { $0.pid == pid }) else { return }
        // The user's doing: a click, or ⌘Tab's modifier, a moment ago. Clinqy's own input goes to apps directly, not
        // through the system's stream; and an app the run just moved into can come forward by itself as it launches.
        let since = [CGEventType.leftMouseDown, .rightMouseDown, .flagsChanged]
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        guard since < 1.5, !(active && self.app?.processIdentifier == pid && Date().timeIntervalSince(appSince) < 2) else { return }

        guard active, self.app?.processIdentifier == pid else {
            AgentScreen.giveBack(app)
            // Mid-run in another app: these are the user's now, so the run's sweep mustn't take them back.
            if active { userWindows[pid, default: []].formUnion(Hand.windowIDs(pid: pid)) }
            return
        }
        guard app.bundleIdentifier == "com.apple.finder" || Launcher.isBrowser(app) else {
            Agent.writeLog("the user switched to \(app.cleanName ?? "an app") while the run is using it")
            onBusyApp("Clinqy is using \(app.cleanName ?? "this app") in the background — it's yours when the task is done")
            return
        }
        let before = Hand.windowIDs(pid: pid)
        AXEngine.pressNewWindow(in: pid)
        var new: Set<CGWindowID> = []
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            new = Hand.windowIDs(pid: pid).subtracting(before)
            if !new.isEmpty { break }
        }
        guard !new.isEmpty else { return Agent.writeLog("the user switched to \(app.cleanName ?? "?"), but no new window opened for them") }
        // Theirs: the run's sweep leaves it be.
        userWindows[pid, default: []].formUnion(new)
        let main = CGDisplayBounds(CGMainDisplayID()).insetBy(dx: 60, dy: 60)
        for window in AXEngine.windows(of: app) {
            guard let id = AXEngine.windowID(of: window), new.contains(id) else { continue }
            if AgentScreen.contains(AXEngine.liveFrame(of: window) ?? .zero) { AXEngine.place(window, in: main) }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        Agent.writeLog("the user switched to \(app.cleanName ?? "?") while the run is using it: opened a window of their own")
    }

    /// Whether the user has come to watch: the run's window is the one in front. The buddy then works there as usual.
    static func isWatched() async -> Bool {
        guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        guard let tab else { return true }
        return await BrowserBridge.shared.tabCommand("tabInfo", on: tab, ["tabId": tab.id])?["focused"] as? Bool == true
    }

    /// Brings the last background run's window to the front: its tab in Clinqy's browser window, or its app.
    static func showLast() async {
        let target = active ? (tab, app) : (last.tab, last.app)
        if target.0?.connection == ChromeWorker.shared.identity { AgentScreenView.shared.show(); return }
        if let tab = target.0 {
            await BrowserBridge.shared.revealTaskTab(tab)
        }
        if let app = target.1, !app.isTerminated { await Launcher.bringToFront(app) }
    }

    /// What the request itself says about where to work, typed or spoken, whatever the toggle is: true for "in the
    /// background: …", "do it in the background, …", "… as a background task"; false for "don't use background",
    /// "not a background task", "not in bg: …", "foreground: …", "… in front of me". nil when it says nothing.
    /// Phrases that only choose the mode are taken off; ones that are part of the task ("… on my screen") are left in.
    /// Mid-sentence, a phrase counts only where it ends a clause, so "change the text, not the background color" and
    /// "blur the people in the background" stay tasks.
    static func choice(_ request: inout String) -> Bool? {
        // Words that can sit between "not" and "background": "don't use", "not as a", "do not run this in the".
        let filler = #"(?:(?:do|run|use|using|put|keep|make|go|work|it|it's|this|that|one|is|be|in|into|as|a|an|the|on|my|please|just)\s+){0,5}"#
        let no = #"(?:don'?t|dont|do not|not|no|never|without|avoid)"#
        let mode = #"(?:\s+(?:mode|task|job|run|tab|window|screen))?"#
        let ends = #"(?=\s*(?:[,.;:!?)]|$|and\b|but\b|then\b|please\b|&))"#
        let lead = #"^\(?(?:please\s+)?"#
        let leadEnd = #"\)?(?:[\s,.;:!-]+|$)"#
        let away = #"(?:\s+(?:from|out of)\s+(?:the\s+)?(?:screen|sight|view))"#
        let negative = #"(?:(?:this|it)\s+is\s+|it'?s\s+)?"# + no + #"\s+"# + filler + #"(?:background|bg)"# + mode
        let front = #"(?:(?:do|run|work)\s+(?:this\s+|it\s+|that\s+)?)?(?:in\s+(?:the\s+)?foreground|foreground(?:\s+mode)?|in\s+front(?:\s+of\s+me)?|visibly)"#
        // "in the background" as the place to work: on its own it can be part of the task ("the people in the
        // background"), so mid-sentence it needs "do/run it" before it or "mode/task" after it.
        let doIt = #"(?:(?:please\s+|just\s+)?(?:do|run|work\s+on|handle|keep)\s+(?:this|it|that)(?:\s+one)?\s+)"#
        let inBg = #"(?:in|as|into)\s+(?:a\s+|an\s+|the\s+)?(?:background|bg)"#
        let notTask = #"(?<!people|person|man|woman|thing|things|object|objects|car|cars|tree|trees|stuff|image|photo|picture|music|noise|sound|everything|anything|someone|something)"#
        let cut: [(String, Bool)] = [
            // Negatives first: "don't do it in the background" also contains "in the background".
            (lead + negative + leadEnd, false),
            (#"[\s,.;:-]*(?:and\s+|but\s+|please\s+)*"# + negative + #"(?:\s+please)?"# + ends, false),
            (lead + front + leadEnd, false),
            (#"[\s,.;:-]*(?:and\s+|but\s+|please\s+)*"# + front + #"(?:\s+please)?"# + ends, false),
            // "in the background open gmail" (spoken, no comma); a bare "background"/"bg" needs a colon or comma, so
            // "background check on …" stays a request.
            (lead + doIt + "?" + inBg + mode + away + "?" + leadEnd, true),
            (#"^\(?(?:background(?:\s+(?:mode|task))?|bg)\)?\s*[,:;-]\s*"#, true),
            (#"[\s,.;:-]*(?:and\s+|please\s+)*"# + doIt + inBg + mode + away + "?" + #"(?:\s+please)?"# + ends, true),
            (#"[\s,.;:-]*(?:and\s+|please\s+)*"# + inBg + #"\s+(?:mode|task|job)(?:\s+please)?"# + ends, true),
            (notTask + #"[\s,]+(?:and\s+|please\s+)*(?:in\s+(?:the\s+)?background|in\s+bg)(?:\s+please)?[\s.!]*$"#, true),
        ]
        // Quoted text is what to type or send (message him: "not in the background"), never the mode.
        let text = request
        let quoted = matches(#""[^"]*"|“[^”]*”"#, in: text)
        let unquoted = { (pattern: String) in matches("(?i)" + pattern, in: text).first { r in !quoted.contains { $0.overlaps(r) } } }
        for (pattern, wants) in cut {
            guard let r = unquoted(pattern) else { continue }
            let edge = r.lowerBound == request.startIndex || r.upperBound == request.endIndex
            request.replaceSubrange(r, with: edge ? "" : " ")
            request = request.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"^[\s,.;:-]+|[\s,;:-]+$"#, with: "", options: .regularExpression)
            return wants
        }
        if unquoted(#"\b(in front of me|on my screen|in the foreground|where i can see( it)?|let me (watch|see))\b"#) != nil { return false }
        return nil
    }

    private static func matches(_ pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }
}

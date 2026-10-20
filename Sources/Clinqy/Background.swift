import AppKit

/// A run that works out of the user's way: nothing is brought to the front, the pointer and keyboard stay theirs, and
/// the buddy stays with them instead of flying to each click. Web pages are worked in Clinqy's own browser window
/// (opened without focus, behind theirs) with input sent to that tab through the extension; other apps get clicks
/// and keys posted to their process, with SkyLight's focus-without-raise where a window has to think it's active.
/// The user hears back through notifications: when it's done, and when it needs them.
@MainActor
enum Background {
    /// This run is a background run.
    private(set) static var active = false
    /// The app the run works in now (its window may well sit behind the user's).
    static var app: NSRunningApplication? {
        didSet { AXEngine.backgroundPid = active ? app?.processIdentifier : nil }
    }
    /// Clinqy's tab in its own browser window: every page read and page action of the run is pinned to it.
    static var tab: BrowserBridge.TabInfo?
    /// Per app the run worked in: the windows it already had then (the user's), which never move. Any other window
    /// of that app (one the run opened: ⌘N, a dialog) goes to Clinqy's hidden screen.
    private static var userWindows: [pid_t: Set<CGWindowID>] = [:]

    /// Every window on the Mac when the run started: a window that appears later in an app the user isn't in (one a
    /// script or shell `open` brought up) is the run's.
    private static var windowsAtStart: Set<CGWindowID> = []

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
        Config.value("BACKGROUND_BROWSER") ?? UserDefaults.standard.string(forKey: "backgroundBrowser") ?? "Google Chrome"
    }

    static func begin(_ on: Bool) {
        active = on
        app = nil
        tab = nil
        userWindows = [:]
        let list = on ? CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] : []
        windowsAtStart = Set(list.compactMap { ($0[kCGWindowNumber as String] as? Int).map(CGWindowID.init) })
    }

    static func end() {
        if active, app != nil || tab != nil { last = (tab, app) }
        if active { lastRun = Date() }
        active = false
        userWindows = [:]
        app = nil
        tab = nil
    }

    /// Whether the user has come to watch: the run's window is the one in front. The buddy then works there as usual.
    static func isWatched() async -> Bool {
        guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        guard let tab else { return true }
        return await BrowserBridge.shared.tabCommand("tabInfo", on: tab, ["tabId": tab.id])?["focused"] as? Bool == true
    }

    /// Brings the last background run's window to the front: its tab in Clinqy's browser window, or its app.
    static func showLast() async {
        if let tab = last.tab {
            await BrowserBridge.shared.tabCommand("switchTab", on: tab, ["tabId": tab.id])
        }
        if let app = last.app, !app.isTerminated { await Launcher.bringToFront(app) }
    }

    /// The request wants to be done where the user can see it, even with background mode on: "foreground: …" (taken
    /// off), or "… in front of me", "… on my screen", "… in the foreground" anywhere in it (left in: they're part of
    /// what was asked).
    static func wantsForeground(_ request: inout String) -> Bool {
        if let r = request.range(of: #"(?i)^\(?(foreground|in front)\)?\s*[:,-]\s*"#, options: .regularExpression) {
            request.removeSubrange(r)
            return true
        }
        return request.range(of: #"(?i)\b(in front of me|on my screen|in the foreground|where i can see( it)?|let me watch)\b"#,
                             options: .regularExpression) != nil
    }

    /// Takes "in the background: …", "background: …", "bg: …" or a trailing "… in the background" off a request.
    static func strip(_ request: inout String) -> Bool {
        let lead = #"(?i)^\(?(in the background|in background|background|bg)\)?\s*[:,-]\s*"#
        let trail = #"(?i)[,\s]+(in the background|in background)\s*[.!]?\s*$"#
        for pattern in [lead, trail] {
            if let r = request.range(of: pattern, options: .regularExpression) {
                request.removeSubrange(r)
                request = request.trimmingCharacters(in: .whitespacesAndNewlines)
                return true
            }
        }
        return false
    }
}

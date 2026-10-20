import AppKit
import ObjectiveC

/// A screen only Clinqy uses: a virtual display (CoreGraphics' private CGVirtualDisplay, as BetterDisplay makes them)
/// where background runs open their windows. The user never sees it or gets switched to it; it touches their main
/// screen only at its bottom-right corner, so the pointer can't wander onto it. Windows on it render like on any screen
/// (pages aren't throttled as hidden ones are), and the live view (`AgentScreenView`) shows them.
/// It stays while any window is on it (removing a display drops its windows onto the user's screen), until it has
/// sat idle a while: then `clearOut` empties it and it goes. Quitting Clinqy empties it first too.
@MainActor
enum AgentScreen {
    private static var display: AnyObject?
    private(set) static var id: CGDirectDisplayID?
    private static var idleCheck: Timer?

    /// Its bounds in global top-left coordinates (CGEvent/Accessibility space), making it if needed.
    /// nil when this macOS can't make one (the caller works behind the user's windows instead).
    static func ensure() -> CGRect? {
        if let id, CGDisplayIsActive(id) != 0 || CGDisplayIsOnline(id) != 0 { return CGDisplayBounds(id) }
        guard let made = make() else { return nil }
        display = made.display
        id = made.id
        arrange()
        Agent.writeLog("made Clinqy's hidden screen (display \(made.id)) at \(CGDisplayBounds(made.id))")
        startIdleCheck()
        return CGDisplayBounds(made.id)
    }

    /// Where it is now, if it exists.
    static var bounds: CGRect? { id.map(CGDisplayBounds) }

    static func contains(_ rect: CGRect) -> Bool {
        guard let b = bounds else { return false }
        return b.contains(CGPoint(x: rect.midX, y: rect.midY))
    }

    /// Diagonal off the main screen's bottom-right corner: touching it at one point only.
    private static func arrange() {
        guard let id else { return }
        let main = CGDisplayBounds(CGMainDisplayID())
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayOrigin(config, id, Int32(main.maxX), Int32(main.maxY))
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    private static func make() -> (display: AnyObject, id: CGDirectDisplayID)? {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type else { return nil }
        let alloc = { (c: NSObject.Type) in c.perform(NSSelectorFromString("alloc")).takeUnretainedValue() }
        let descriptor = descriptorClass.init()
        descriptor.setValue(DispatchQueue.main, forKey: "queue")
        descriptor.setValue("Clinqy Workspace", forKey: "name")
        descriptor.setValue(1920, forKey: "maxPixelsWide")
        descriptor.setValue(1200, forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: NSSize(width: 520, height: 325)), forKey: "sizeInMillimeters")
        descriptor.setValue(0xC11A, forKey: "productID")
        descriptor.setValue(0xC11A, forKey: "vendorID")
        descriptor.setValue(1, forKey: "serialNum")

        typealias InitDisplay = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        typealias InitMode = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let initDisplay = NSSelectorFromString("initWithDescriptor:"), initMode = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let apply = NSSelectorFromString("applySettings:")
        guard displayClass.instancesRespond(to: initDisplay), displayClass.instancesRespond(to: apply),
              modeClass.instancesRespond(to: initMode) else { return nil }
        guard let display = unsafeBitCast(class_getMethodImplementation(displayClass, initDisplay), to: InitDisplay.self)(
            alloc(displayClass), initDisplay, descriptor) else { return nil }
        let mode = unsafeBitCast(class_getMethodImplementation(modeClass, initMode), to: InitMode.self)(alloc(modeClass), initMode, 1440, 900, 60)
        let settings = settingsClass.init()
        settings.setValue(0, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")
        guard unsafeBitCast(class_getMethodImplementation(displayClass, apply), to: Apply.self)(display, apply, settings),
              let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0 else { return nil }
        return (display, id)
    }

    /// The windows on it now (number, owner, bounds).
    static func windows() -> [(id: CGWindowID, pid: pid_t, frame: CGRect)] {
        guard let b = bounds else { return [] }
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0, let id = info[kCGWindowNumber as String] as? Int,
                  let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init),
                  let d = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: d),
                  frame.width > 40, frame.height > 40, b.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
            return (CGWindowID(id), pid, frame)
        }
    }

    /// Clinqy's browser window (kept across runs), so a later run can put it back here if it wandered.
    private static var browserWindow: (pid: pid_t, id: CGWindowID)?

    /// Moves `app`'s windows that aren't in `keep` (the ones the user already had) onto it, fitted inside.
    /// Returns the windows moved.
    @discardableResult
    static func adopt(_ app: NSRunningApplication, keep: Set<CGWindowID> = []) -> Set<CGWindowID> {
        guard let b = ensure() else { return [] }
        return move(Hand.windowIDs(pid: app.processIdentifier).subtracting(keep), of: app, into: b)
    }

    /// The browser window a background run works in: the one it just opened (not among `had`), or the one earlier
    /// runs used. Put on this screen if it isn't (the browser placed it on the main one).
    /// `frame`: where the browser says the window is, to find it when it's neither new nor known.
    static func adoptBrowserWindow(_ browser: NSRunningApplication, had: Set<CGWindowID>, frame: CGRect?) {
        guard let b = ensure() else { return }
        let now = Hand.windowIDs(pid: browser.processIdentifier)
        if let new = now.subtracting(had).first {
            browserWindow = (browser.processIdentifier, new)
        } else if let frame, browserWindow?.pid != browser.processIdentifier || !now.contains(browserWindow!.id),
                  let match = AXEngine.windows(of: browser).first(where: { w in
                      AXEngine.liveFrame(of: w).map { abs($0.minX - frame.minX) <= 2 && abs($0.minY - frame.minY) <= 2
                          && abs($0.width - frame.width) <= 2 && abs($0.height - frame.height) <= 2 } ?? false }),
                  let id = AXEngine.windowID(of: match) {
            browserWindow = (browser.processIdentifier, id)
        }
        guard let mine = browserWindow, mine.pid == browser.processIdentifier, now.contains(mine.id) else { return }
        let onIt = windows().contains { $0.id == mine.id }
        if !onIt { move([mine.id], of: browser, into: b) }
    }

    @discardableResult
    private static func move(_ ids: Set<CGWindowID>, of app: NSRunningApplication, into b: CGRect) -> Set<CGWindowID> {
        var moved: Set<CGWindowID> = []
        for window in AXEngine.windows(of: app) {
            guard let id = AXEngine.windowID(of: window), ids.contains(id) else { continue }
            AXEngine.place(window, in: b.insetBy(dx: 20, dy: 20))
            moved.insert(id)
        }
        if !moved.isEmpty { Agent.writeLog("    moved \(moved.count) window\(moved.count == 1 ? "" : "s") of \(app.cleanName ?? "?") to Clinqy's hidden screen") }
        return moved
    }

    /// Brings every window on it to the user's main screen (they asked to take over), centred.
    static func bringHere() {
        Task { await BrowserBridge.shared.releaseBackgroundWindows() }
        let main = CGDisplayBounds(CGMainDisplayID())
        for w in windows() {
            guard let app = NSRunningApplication(processIdentifier: w.pid) else { continue }
            for window in AXEngine.windows(of: app) where AXEngine.windowID(of: window) == w.id {
                AXEngine.place(window, in: main.insetBy(dx: 60, dy: 60))
            }
            app.activate()
        }
    }

    /// How long it stays after the last background run (with the live view closed) before it's emptied and removed.
    /// (Dashboard → Background; 0 = keep it until Clinqy quits.)
    static var idleAfter: TimeInterval {
        let minutes = UserDefaults.standard.object(forKey: "backgroundIdleMinutes") as? Int ?? 10
        return minutes <= 0 ? .infinity : TimeInterval(minutes * 60)
    }

    /// Every half minute: once no background run has needed it for `idleAfter` and nobody is watching, empty it;
    /// remove it as soon as nothing is on it.
    private static func startIdleCheck() {
        idleCheck?.invalidate()
        idleCheck = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard display != nil, !Background.active, !AgentScreenView.shared.isOpen else { return }
                if Date().timeIntervalSince(Background.lastRun) > idleAfter, !windows().isEmpty { clearOut() }
                guard windows().isEmpty else { return }
                remove("nothing on it")
            }
        }
    }

    /// Empties it without anything landing on the user's screen: a browser's windows here are Clinqy's own and
    /// close; any other app's go to the Dock, minimized, so unsaved work is never lost.
    static func clearOut() {
        let here = windows()
        guard !here.isEmpty else { return }
        for w in here {
            guard let app = NSRunningApplication(processIdentifier: w.pid),
                  let window = AXEngine.windows(of: app).first(where: { AXEngine.windowID(of: $0) == w.id }) else { continue }
            if Launcher.isBrowser(app), let close: AXUIElement = AXEngine.attribute(window, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(close, kAXPressAction as CFString)
            } else {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
        Agent.writeLog("emptied Clinqy's hidden screen: \(here.count) window\(here.count == 1 ? "" : "s") closed or minimized")
    }

    /// Quitting: empty it, wait a moment for the windows to go, then let it go with the app.
    static func quit() {
        guard display != nil else { return }
        clearOut()
        for _ in 0..<15 where !windows().isEmpty { usleep(100_000) }
        remove("Clinqy is quitting")
    }

    private static func remove(_ why: String) {
        Agent.writeLog("removed Clinqy's hidden screen (\(why))")
        idleCheck?.invalidate()
        idleCheck = nil
        display = nil
        id = nil
    }
}

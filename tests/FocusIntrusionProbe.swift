import AppKit
@preconcurrency import ScreenCaptureKit

// Phase 0.2/0.3 focus-intrusion probe. A disposable AppKit fixture is put in FRONT and counts what a
// person would notice (resign active/key, stray clicks or keys, pointer moves, frontmost changes) while
// Clinqy's production SkyLight click and keyboard session drive TextEdit BEHIND it. Live only: it needs
// Accessibility, opens TextEdit on a temporary file, and quits both afterwards. Not part of CI.

enum Launcher { static func isBrowser(_ app: NSRunningApplication) -> Bool { false } }
enum Safety {
    static func redacted(_ value: String?, role: String, subrole: String?) -> String? { value }
    static func redacted(_ value: String?, of element: AXUIElement) -> String? { value }
    static func isSecureField(_ element: AXUIElement) -> Bool { false }
}

// MARK: - Front fixture (child process)

@MainActor private final class FrontFixture: NSObject, NSTextFieldDelegate {
    final class ClickView: NSView {
        var onDown: () -> Void = {}
        override func mouseDown(with event: NSEvent) { onDown() }
        override func rightMouseDown(with event: NSEvent) { onDown() }
    }
    let statePath: String
    var window: NSWindow!
    var field: NSTextField!
    var resignActive = 0, resignKey = 0, mouseDowns = 0, textChanges = 0
    init(statePath: String) { self.statePath = statePath }

    func write() {
        let state: [String: Any] = [
            "active": NSApp.isActive, "key": window.isKeyWindow, "resignActive": resignActive, "resignKey": resignKey,
            "mouseDowns": mouseDowns, "textChanges": textChanges, "field": field.stringValue,
            "firstResponderIsField": window.firstResponder === field.currentEditor(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state) { try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic) }
    }

    func controlTextDidChange(_ obj: Notification) { textChanges += 1; write() }

    func start(cover: CGRect) {
        NSApp.setActivationPolicy(.regular)
        // `cover` is global top-left; AppKit is bottom-left of the primary screen.
        let primary = NSScreen.screens.first?.frame.height ?? 900
        let rect = CGRect(x: cover.minX - 40, y: primary - cover.maxY - 40, width: cover.width + 80, height: cover.height + 80)
        window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Clinqy focus-intrusion fixture"
        let view = ClickView(frame: CGRect(origin: .zero, size: rect.size))
        view.onDown = { [weak self] in self?.mouseDowns += 1; self?.write() }
        field = NSTextField(string: "front")
        field.frame = CGRect(x: 20, y: rect.height - 60, width: 240, height: 24)
        field.delegate = self
        view.addSubview(field)
        window.contentView = view
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resignActive += 1; self?.write() }
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resignKey += 1; self?.write() }
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.write() } }
    }
}

// MARK: - Probe driver

private struct FixtureState {
    var active = false, key = false, resignActive = 0, resignKey = 0, mouseDowns = 0, textChanges = 0, field = ""
    init(path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        active = json["active"] as? Bool ?? false; key = json["key"] as? Bool ?? false
        resignActive = json["resignActive"] as? Int ?? 0; resignKey = json["resignKey"] as? Int ?? 0
        mouseDowns = json["mouseDowns"] as? Int ?? 0; textChanges = json["textChanges"] as? Int ?? 0
        field = json["field"] as? String ?? ""
    }
}

@MainActor private func spin(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
private func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

@MainActor private func symbolReport() {
    let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    for name in ["SLEventPostToPid", "SLEventSetIntegerValueField", "CGEventSetWindowLocation", "SLPSPostEventRecordTo",
                 "SLSMainConnectionID", "SLSHWCaptureWindowList", "SLSPackagesEnableWindowOcclusionNotifications"] {
        print("SYMBOL \(name): \(sky.flatMap { dlsym($0, name) } != nil)")
    }
    for name in ["GetProcessForPID", "_AXUIElementGetWindow", "_AXObserverAddNotificationAndCheckRemote"] {
        print("SYMBOL \(name): \(services.flatMap { dlsym($0, name) } != nil)")
    }
}

@MainActor private func captureTimings(_ window: NativeWindowObservation) async {
    typealias Main = @convention(c) () -> UInt32
    typealias HW = @convention(c) (UInt32, UnsafePointer<CGWindowID>, Int32, UInt32) -> Unmanaged<CFArray>?
    guard CGPreflightScreenCaptureAccess() else { print("SKIP: capture timings need Screen Recording"); return }
    if let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
       let m = dlsym(sky, "SLSMainConnectionID"), let h = dlsym(sky, "SLSHWCaptureWindowList") {
        let main = unsafeBitCast(m, to: Main.self), hw = unsafeBitCast(h, to: HW.self)
        var times: [Int] = [], sizes = ""
        for _ in 0..<5 {
            var id = window.windowID
            let t = Date()
            let images = hw(main(), &id, 1, 0x800)?.takeRetainedValue()
            times.append(ms(since: t))
            if let images, CFArrayGetCount(images) > 0 {
                let image = unsafeBitCast(CFArrayGetValueAtIndex(images, 0), to: CGImage.self)
                sizes = "\(image.width)x\(image.height)"
            }
        }
        print("MEASURED: SLSHWCaptureWindowList covered TextEdit ms=\(times) image=\(sizes.isEmpty ? "none" : sizes)")
    }
    var sck: [Int] = []
    for _ in 0..<3 {
        let t = Date()
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let target = content.windows.first(where: { $0.windowID == window.windowID }) else { print("MEASURED: SCK window unavailable"); return }
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width); config.height = Int(target.frame.height); config.showsCursor = false
        _ = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        sck.append(ms(since: t))
    }
    print("MEASURED: SCK enumerate+capture ms=\(sck)")
}

@main struct FocusIntrusionProbe {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--front"), args.count > index + 5 {
            let values = args[(index + 2)...(index + 5)].compactMap { Double($0) }
            let fixture = FrontFixture(statePath: args[index + 1])
            _ = NSApplication.shared
            fixture.start(cover: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
            NSApp.run()
            return
        }
        symbolReport()
        guard AXIsProcessTrusted() else { print("SKIP: Accessibility not granted to this executable; no live input sent."); return }
        guard NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.TextEdit" }) == nil else {
            print("SKIP: TextEdit is already running; the probe will not touch the user's documents."); return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-probe-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("probe.txt"), statePath = dir.appendingPathComponent("front.json").path
        try "hello world\n".write(to: file, atomically: true, encoding: .utf8)
        var fixtureProcess: Process?
        var textEdit: NSRunningApplication?
        defer {
            if let fixtureProcess, fixtureProcess.isRunning { fixtureProcess.terminate(); fixtureProcess.waitUntilExit() }
            if let textEdit, !textEdit.isTerminated {
                textEdit.terminate()
                for _ in 0..<60 where !textEdit.isTerminated { spin(0.05) }
                if !textEdit.isTerminated { textEdit.forceTerminate() }
            }
            try? FileManager.default.removeItem(at: dir)
            print("CLEANUP: TextEdit quit=\(textEdit?.isTerminated ?? true), fixture quit=\(!(fixtureProcess?.isRunning ?? false))")
        }

        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-g", "-a", "TextEdit", file.path]
        try opener.run(); opener.waitUntilExit()
        var window: NativeWindowObservation?
        for _ in 0..<80 {
            spin(0.1)
            textEdit = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.TextEdit" }
            if let app = textEdit, let found = AXEngine.windows(of: app).compactMap({ AXEngine.windowID(of: $0) }).first,
               let observed = NativeWindowObservation.capture(app, windowID: found) { window = observed; break }
        }
        guard let app = textEdit, var target = window else { print("FAIL: TextEdit window never appeared"); return }
        func textArea() -> AXUIElement? {
            var queue: [AXUIElement] = [target.element]
            while !queue.isEmpty {
                let node = queue.removeFirst()
                if (AXEngine.attribute(node, kAXRoleAttribute) as String?) == "AXTextArea" { return node }
                queue += (AXEngine.attribute(node, kAXChildrenAttribute) as [AXUIElement]?) ?? []
            }
            return nil
        }
        guard let area = textArea(), let areaFrame = AXEngine.liveFrame(of: area) else { print("FAIL: no TextEdit text area"); return }

        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: args[0])
        fixture.arguments = ["--front", statePath] + [target.frame.minX, target.frame.minY, target.frame.width, target.frame.height].map { String(Double($0)) }
        try fixture.run()
        fixtureProcess = fixture
        var state = FixtureState(path: statePath)
        for _ in 0..<60 where !(state.active && state.key) { spin(0.05); state = FixtureState(path: statePath) }
        spin(0.3)
        state = FixtureState(path: statePath)
        let fixtureFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier
        print("SETUP: fixture active=\(state.active) key=\(state.key) frontmost=\(fixtureFront)")
        guard state.active, state.key else { print("SKIP: fixture could not become the active key window; intrusion counts would be meaningless."); return }

        let inputTypes: [CGEventType] = [.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel]
        let hidBefore = inputTypes.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
        let pointer = CGEvent(source: nil)?.location
        let baseline = state
        var range = CFRange(location: 0, length: 0)
        if let value = AXValueCreate(.cfRange, &range) { AXUIElementSetAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, value) }
        spin(0.1)
        guard let fresh = NativeWindowObservation.capture(app, windowID: target.windowID) else { print("FAIL: TextEdit window lost"); return }
        target = fresh

        // 1. Production SkyLight click at the bottom of the text area: caret should move to the end.
        let clickPoint = CGPoint(x: areaFrame.midX, y: min(areaFrame.maxY - 10, target.frame.maxY - 30))
        let clickStart = Date()
        let clickResult = SkyLight.click(at: clickPoint, pid: app.processIdentifier, window: target.windowID, frame: target.frame)
        let clickMs = ms(since: clickStart)
        spin(0.3)
        let value: String = AXEngine.attribute(area, kAXValueAttribute) ?? ""
        var caret = -1
        if let raw: AXValue = AXEngine.attribute(area, kAXSelectedTextRangeAttribute) {
            var r = CFRange(); if AXValueGetValue(raw, .cfRange, &r) { caret = r.location }
        }
        let afterClick = FixtureState(path: statePath)
        print("CLICK: result=\(clickResult ?? "delivered") returnMs=\(clickMs) caretMovedToEnd=\(caret == (value as NSString).length) (caret \(caret), length \((value as NSString).length))")
        print("CLICK front: lostActive=\(afterClick.resignActive - baseline.resignActive) lostKey=\(afterClick.resignKey - baseline.resignKey) strayMouseDowns=\(afterClick.mouseDowns - baseline.mouseDowns)")

        // 2. Production keyboard session: target-only focus + key-window records, then pid-posted keys.
        guard let keyTarget = NativeWindowObservation.capture(app, windowID: target.windowID) else { print("FAIL: TextEdit window lost"); return }
        let keyStart = Date()
        var keyResult = "delivered"
        switch SkyLight.beginKeyboard(in: keyTarget) {
        case .failure(let error): keyResult = error.reason
        case .success(let session):
            AXEngine.type("ZQ", to: app.processIdentifier)
            if !session.finish() { keyResult = "cleanup failed" }
        }
        let keyMs = ms(since: keyStart)
        spin(0.3)
        let typed: String = AXEngine.attribute(area, kAXValueAttribute) ?? ""
        let afterKeys = FixtureState(path: statePath)
        print("KEYS: result=\(keyResult) returnMs=\(keyMs) textArrived=\(typed.contains("ZQ"))")
        print("KEYS front: lostActive=\(afterKeys.resignActive - afterClick.resignActive) lostKey=\(afterKeys.resignKey - afterClick.resignKey) strayKeysInFrontField=\(afterKeys.field != baseline.field)")

        let hidAfter = inputTypes.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
        let pointerMoved = CGEvent(source: nil)?.location != pointer
        let frontNow = NSWorkspace.shared.frontmostApplication?.processIdentifier
        print("TOTAL: lostActive=\(afterKeys.resignActive - baseline.resignActive) lostKey=\(afterKeys.resignKey - baseline.resignKey) pointerMoved=\(pointerMoved) frontmostChanged=\(frontNow != fixture.processIdentifier) fixtureStillActive=\(afterKeys.active) fixtureStillKey=\(afterKeys.key)")
        if hidAfter != hidBefore { print("NOTE: physical HID input happened during the probe; pointer result may be inconclusive") }
        await captureTimings(keyTarget)
    }
}

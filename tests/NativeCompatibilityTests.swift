import AppKit
@preconcurrency import ScreenCaptureKit
import Vision

// Callback state is shared with ScreenCaptureKit's completion queue.
private final class CaptureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var storedContent: SCShareableContent?
    private var storedImage: CGImage?
    var finished: Bool { lock.withLock { done } }
    var content: SCShareableContent? { lock.withLock { storedContent } }
    var image: CGImage? { lock.withLock { storedImage } }
    func complete(content: SCShareableContent?) { lock.withLock { storedContent = content; done = true } }
    func complete(image: CGImage?) { lock.withLock { storedImage = image; done = true } }
}

// This fixture creates native AppKit windows rather than a browser.
enum Launcher { static func isBrowser(_ app: NSRunningApplication) -> Bool { false } }

// Fixture controls contain only test strings; production redaction is irrelevant to this isolated driver probe.
enum Safety {
    static func redacted(_ value: String?, role: String, subrole: String?) -> String? { value }
    static func redacted(_ value: String?, of element: AXUIElement) -> String? { value }
    static func isSecureField(_ element: AXUIElement) -> Bool { false }
}

@MainActor private final class Fixture: NSObject {
    var windows: [NSWindow] = []
    var presses = 0
    @objc func press(_ sender: NSButton) { presses += 1; sender.title = "Fixture count \(presses)" }
    @objc func coverSmall(_ sender: NSButton) { windows[0].orderBack(nil) }
    func start() {
        NSApplication.shared.setActivationPolicy(.accessory)
        for (index, size) in [CGSize(width: 320, height: 180), CGSize(width: 640, height: 380)].enumerated() {
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 100 + index * 50, y: 100 + index * 50), size: size),
                                  styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Clinqy disposable fixture \(index)"
            let button = NSButton(title: "Fixture count 0", target: self, action: #selector(press(_:)))
            button.frame = CGRect(x: 30, y: 30, width: 220, height: 40)
            window.contentView?.addSubview(button)
            for column in 0..<2 {
                let field = NSTextField(string: "fixture field \(column)")
                field.frame = CGRect(x: 20 + column * 150, y: 90, width: 130, height: 24)
                window.contentView?.addSubview(field)
            }
            let coverButton = NSButton(title: "Cover fixture", target: self, action: #selector(coverSmall(_:)))
            coverButton.frame = CGRect(x: 20, y: 125, width: 150, height: 24)
            window.contentView?.addSubview(coverButton)
            window.orderBack(nil)
            windows.append(window)
        }
        print(windows.map { String($0.windowNumber) }.joined(separator: ",")); fflush(stdout)
    }
}

@main struct NativeCompatibilityTests {
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--fixture") {
            let fixture = Fixture()
            fixture.start()
            NSApplication.shared.run()
            return
        }
        guard AXIsProcessTrusted() else {
            print("SKIP: native fixture requires Accessibility permission for this test executable; no permission prompt or input was issued.")
            return
        }
        guard CGSessionCopyCurrentDictionary() != nil, !NSScreen.screens.isEmpty else {
            print("SKIP: native fixture requires a logged-in graphical macOS session; no fixture or input was created.")
            return
        }
        var checks = 0
        enum Failure: Error { case check(String) }
        func check(_ value: Bool, _ label: String) throws { guard value else { throw Failure.check(label) }; checks += 1 }
        func windows(excluding pid: pid_t) -> [CGWindowID] {
            let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            return rows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
                .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pointer = CGEvent(source: nil)?.location
        let clipboard = NSPasteboard.general.changeCount
        let beforeOrder = windows(excluding: -1)
        let measuredFrom = Date()
        let inputTypes: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        let inputCounts = inputTypes.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--fixture"]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 { line.append(byte) }
        let ids = String(decoding: line, as: UTF8.self).split(separator: ",").compactMap { UInt32($0) }
        try check(ids.count == 2, "fixture created two independently addressable windows")
        guard let app = NSRunningApplication(processIdentifier: process.processIdentifier) else { throw Failure.check("fixture application disappeared") }
        // AppKit publishes window IDs before its first layout has settled. Retry only
        // unavailable/stale observations; never retry away a wrong-target assertion.
        func readyWindow(_ id: CGWindowID) throws -> (NativeWindowObservation, [UIElementInfo]) {
            for _ in 0..<40 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                if let observation = NativeWindowObservation.capture(app, windowID: id) {
                    let controls = AXEngine.elements(of: app, window: observation)
                    if !controls.isEmpty, observation.staleness() == nil { return (observation, controls) }
                }
            }
            throw Failure.check("fixture window never exposed stable controls")
        }
        let (small, controls) = try readyWindow(ids[0])
        let (large, _) = try readyWindow(ids[1])
        try check(small.windowID != large.windowID && small.frame.width < large.frame.width, "exact small window is not replaced by largest same-process window")
        try check(!controls.isEmpty && controls.allSatisfy { $0.windowID == small.windowID && $0.observationID == small.id }, "all controls belong to the exact observation")
        guard let button = controls.first(where: { $0.role == "AXButton" && $0.label == "Fixture count 0" }) else { throw Failure.check("fixture button not exposed") }
        try check(AXEngine.axPressDelivery(button.element) == .delivered, "one semantic action delivered only to fixture")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try check(small.staleness(includeContent: true) != nil, "changed fixture content invalidates earlier observation")
        let (currentLarge, largeControls) = try readyWindow(large.windowID)
        try check(largeControls.contains { $0.label == "Fixture count 0" }, "same-labelled control in other window is unchanged")
        let (_, refreshedControls) = try readyWindow(small.windowID)
        let fields = refreshedControls.filter { $0.role == "AXTextField" }.sorted { $0.frame.minX < $1.frame.minX }
        try check(fields.count == 2, "fixture exposes two independent text fields")
        try check(AXEngine.focus(fields[0].element), "focus delivered to exact disposable field")
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        try check(AXEngine.focusedWithin(fields[0].element, in: app), "exact requested focused field is accepted")
        try check(!AXEngine.focusedWithin(fields[1].element, in: app), "another text field is rejected despite its editable role")
        try check(!AXEngine.focusedWithin(button.element, in: app), "non-input target is not accepted as text focus")
        let setResult = AXUIElementSetAttributeValue(fields[0].element, kAXValueAttribute as CFString, "semantic background value" as CFString)
        let readValue: String = AXEngine.attribute(fields[0].element, kAXValueAttribute) ?? ""
        try check(setResult == .success && readValue == "semantic background value", "AX value set verified in exact fixture field")
        let otherValue: String = AXEngine.attribute(fields[1].element, kAXValueAttribute) ?? ""
        try check(otherValue == "fixture field 1", "AX value set leaves sibling field unchanged")
        let keyFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let keyPointer = CGEvent(source: nil)?.location
        if AXEngine.focusedWithin(fields[0].element, in: app) {
            // PID-only delivery: no global event stream, clipboard, or activation fallback.
            AXEngine.targetPid = app.processIdentifier
            AXEngine.type("Z")
            AXEngine.targetPid = nil
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let typedValue: String = AXEngine.attribute(fields[0].element, kAXValueAttribute) ?? ""
            print("MEASURED: PID keyboard changed exact focused field: \(typedValue != readValue)")
            try check((AXEngine.attribute(fields[1].element, kAXValueAttribute) as String?) == otherValue, "PID keyboard leaves sibling field unchanged")
            print("MEASURED: PID keyboard foreground unchanged: \(NSWorkspace.shared.frontmostApplication?.processIdentifier == keyFront), pointer unchanged: \(CGEvent(source: nil)?.location == keyPointer)")
        } else { print("SKIP: exact focus not retained, no PID keyboard input sent") }
        AXEngine.place(currentLarge.element, in: currentLarge.frame.offsetBy(dx: 12, dy: 0))
        try check(currentLarge.staleness() != nil, "moving the exact fixture window invalidates old geometry")
        // Cover the small fixture with the large fixture without raising either above user windows.
        let (captureTarget, captureControls) = try readyWindow(small.windowID)
        guard let coverButton = captureControls.first(where: { $0.label == "Cover fixture" }) else { throw Failure.check("cover control unavailable") }
        try check(AXEngine.axPressDelivery(coverButton.element) == .delivered, "semantic cover action delivered to fixture")
        let (cover, _) = try readyWindow(large.windowID)
        AXEngine.place(cover.element, in: CGRect(x: captureTarget.frame.minX - 10, y: captureTarget.frame.minY - 10,
                                               width: cover.frame.width, height: cover.frame.height))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let order = rows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let covered = order.firstIndex(of: large.windowID).map { largeIndex in
            order.firstIndex(of: small.windowID).map { largeIndex < $0 } ?? false
        } ?? false
        if covered {
            let (coverNow, _) = try readyWindow(large.windowID)
            let (coveredWindow, coveredControls) = try readyWindow(small.windowID)
            try check(coverNow.frame.contains(coveredWindow.frame), "large fixture fully covers the small fixture bounds")
            guard let coveredField = coveredControls.first(where: { $0.role == "AXTextField" }),
                  let coveredButton = coveredControls.first(where: { $0.label == "Fixture count 1" }) else { throw Failure.check("covered semantic targets unavailable") }
            let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let pointerBefore = CGEvent(source: nil)?.location
            try check(AXEngine.axPressDelivery(coveredButton.element) == .delivered, "covered semantic press delivered")
            let set = AXUIElementSetAttributeValue(coveredField.element, kAXValueAttribute as CFString, "covered value" as CFString)
            try check(set == .success && (AXEngine.attribute(coveredField.element, kAXValueAttribute) as String?) == "covered value", "covered semantic value verified")
            try check(coveredWindow.windowID == small.windowID, "covered semantic target retains exact window identity")
            print("MEASURED: covered AX actions foreground unchanged: \(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBefore), pointer unchanged: \(CGEvent(source: nil)?.location == pointerBefore)")
        }
        if covered, CGPreflightScreenCaptureAccess() {
            let inventory = CaptureProbe()
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { result, _ in
                inventory.complete(content: result)
            }
            let deadline = Date().addingTimeInterval(5)
            while !inventory.finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            guard inventory.finished, let target = inventory.content?.windows.first(where: { $0.windowID == small.windowID }) else {
                throw Failure.check("covered fixture unavailable to ScreenCaptureKit")
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(target.frame.width * 2); configuration.height = Int(target.frame.height * 2)
            configuration.showsCursor = false
            let capture = CaptureProbe()
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration) { image, _ in
                capture.complete(image: image)
            }
            let captureDeadline = Date().addingTimeInterval(5)
            while !capture.finished && Date() < captureDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            guard let image = capture.image else { throw Failure.check("covered fixture screenshot failed") }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            try check(text.contains("Fixture count 2"), "covered exact-window pixels contain updated small-window button")
            try check(!text.contains("Fixture count 0"), "covering-window button is absent from exact-window capture")
            print("MEASURED: covered window capture OCR verified the semantic action result without raising the window")
            let minimized = AXUIElementSetAttributeValue(captureTarget.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            if minimized == .success {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                let isMinimized: Bool = AXEngine.attribute(captureTarget.element, kAXMinimizedAttribute) ?? false
                try check(isMinimized, "fixture minimized state verified")
                let minimizedInventory = CaptureProbe()
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { result, _ in
                    minimizedInventory.complete(content: result)
                }
                let minimizedDeadline = Date().addingTimeInterval(5)
                while !minimizedInventory.finished && Date() < minimizedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
                print("MEASURED: minimized fixture in on-screen capture inventory: \(minimizedInventory.content?.windows.contains(where: { $0.windowID == small.windowID }) ?? false); no minimized image accepted as fresh evidence")
            } else { print("SKIP: fixture did not accept semantic minimize") }
        } else {
            print("SKIP: covered capture probe requires Screen Recording permission and fixture stacking with the large window above the small window")
        }
        let inputNow = inputTypes.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
        if inputNow != inputCounts {
            print("SKIP: foreground/pointer/clipboard/window-order isolation measurement was inconclusive because HID input occurred during the \(String(format: "%.2f", Date().timeIntervalSince(measuredFrom)))s probe; target/focus checks still ran.")
        } else {
            try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == front, "foreground app unchanged")
            try check(CGEvent(source: nil)?.location == pointer, "system pointer unchanged")
            try check(NSPasteboard.general.changeCount == clipboard, "shared clipboard unchanged")
            try check(windows(excluding: process.processIdentifier) == beforeOrder, "existing user windows preserve their order")
        }
        print("PASS: \(checks) native fixture compatibility checks (this fixture only; no general native-app support implied)")
    }
}

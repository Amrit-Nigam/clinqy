import AppKit

/// Watches the user do something (apps, clicks, typing, keys) and keeps a readable transcript of it,
/// so it can be turned into a reusable skill. Typing in password fields is never recorded.
@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()

    @Published private(set) var isRecording = false
    @Published private(set) var steps: [String] = []

    private var monitors: [Any] = []
    private var appObserver: NSObjectProtocol?
    private var typed = ""
    private var typedInto = ""
    private var started = Date()

    func start() {
        guard !isRecording else { return }
        steps = []
        typed = ""
        started = Date()
        isRecording = true
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            steps.append("Started in \(app.cleanName ?? "?")\(Self.windowNote(app))")
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                Recorder.shared.flushTyping()
                Recorder.shared.steps.append("Switched to \(app.cleanName ?? "?")\(Self.windowNote(app))")
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            let point = Buddy.mouse()
            let right = event.type == .rightMouseDown
            MainActor.assumeIsolated { Recorder.shared.recordClick(at: point, right: right) }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            let chars = event.characters ?? ""
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            let code = event.keyCode
            MainActor.assumeIsolated { Recorder.shared.recordKey(chars: chars, code: code, flags: flags) }
        }) { monitors.append(m) }
    }

    /// Stops watching and returns the transcript.
    func stop() -> [String] {
        guard isRecording else { return steps }
        flushTyping()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        isRecording = false
        return steps
    }

    // MARK: - Events

    private func recordClick(at point: CGPoint, right: Bool) {
        flushTyping()
        let (role, label) = AXEngine.describe(at: point)
        let app = NSWorkspace.shared.frontmostApplication?.cleanName ?? "?"
        let what = label.isEmpty ? "\(role) at (\(Int(point.x)), \(Int(point.y)))" : "\(role) “\(label.prefix(80))”"
        steps.append("\(right ? "Right-clicked" : "Clicked") \(what) in \(app)")
    }

    private func recordKey(chars: String, code: UInt16, flags: NSEvent.ModifierFlags) {
        let named: [UInt16: String] = [0x24: "Return", 0x30: "Tab", 0x35: "Escape", 0x33: "Delete",
                                       0x7B: "Left", 0x7C: "Right", 0x7D: "Down", 0x7E: "Up"]
        if !flags.isEmpty || named[code] != nil {
            // Deleting while typing just edits the text being recorded.
            if code == 0x33, flags.isEmpty, !typed.isEmpty { typed.removeLast(); return }
            flushTyping()
            var combo = ""
            if flags.contains(.control) { combo += "ctrl+" }
            if flags.contains(.option) { combo += "opt+" }
            if flags.contains(.command) { combo += "cmd+" }
            combo += named[code] ?? chars.lowercased()
            steps.append("Pressed \(combo)")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let (role, label) = AXEngine.focusedDescription(of: app)
        if role == "AXSecureTextField" {
            if typedInto != "secure" { flushTyping(); typedInto = "secure"; steps.append("Typed a password (not recorded)") }
            return
        }
        let target = label.isEmpty ? role : "\(role) “\(label.prefix(60))”"
        if target != typedInto { flushTyping(); typedInto = target }
        typed += chars
    }

    private func flushTyping() {
        if !typed.isEmpty, typedInto != "secure" {
            steps.append("Typed “\(typed)” into \(typedInto.isEmpty ? "the focused field" : typedInto)")
        }
        typed = ""
        typedInto = ""
    }

    private static func windowNote(_ app: NSRunningApplication) -> String {
        let title = AXEngine.focusSummary(of: app).window
        return title.isEmpty ? "" : " (window “\(title.prefix(70))”)"
    }
}

import AppKit

/// AppKit catches Objective-C exceptions that reach the run loop, logs them and carries on. One that unwound
/// through a Swift task leaves the concurrency runtime's executor tracking pointing at a dead stack frame, and the
/// app segfaults seconds later at the next actor check (MainActor.assumeIsolated), far from the cause. So each one
/// is written to ~/Library/Logs/Clinqy/exceptions.log, and after one of those Clinqy restarts itself cleanly
/// instead of vanishing.
final class ClinqyApplication: NSApplication {
    /// Set when the app finishes launching (a `static let` would only be set at its first read: the first exception).
    private nonisolated(unsafe) static var launched = Date.distantFuture

    override func finishLaunching() {
        Self.launched = Date()
        super.finishLaunching()
    }

    override func reportException(_ exception: NSException) {
        super.reportException(exception)
        let stack = exception.callStackSymbols
        let poisoned = stack.contains { $0.contains("libswift_Concurrency") }
        Self.record(exception, stack: stack, restarting: poisoned)
        guard poisoned else { return }
        // A failure right at launch would only loop; then let it fail as it would have.
        guard Date().timeIntervalSince(Self.launched) > 30 else { return }
        Self.relaunch()
    }

    private static func record(_ exception: NSException, stack: [String], restarting: Bool) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clinqy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("exceptions.log")
        let entry = "\(Date()) \(exception.name.rawValue): \(exception.reason ?? "")\(restarting ? " — restarting" : "")\n"
            + stack.joined(separator: "\n") + "\n\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
        NSLog("Clinqy: caught exception %@: %@", exception.name.rawValue, exception.reason ?? "")
    }

    /// Opens a fresh copy once this one is gone, then leaves without running any more Swift (the runtime is unsound).
    private static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        _exit(0)
    }
}

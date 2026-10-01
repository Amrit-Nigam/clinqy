import AppKit

/// Opening and focusing apps and URLs.
@MainActor
enum Launcher {
    static let browserIDs: Set<String> = [
        "company.thebrowser.Browser", "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.dia",
    ]

    static var defaultBrowserName: String? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?
            .deletingPathExtension().lastPathComponent
    }

    /// Title of the frontmost window: cheap way to notice a page change.
    static var frontURLHint: String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "" }
        return AXEngine.focusSummary(of: app).window
    }

    static func isBrowser(_ app: NSRunningApplication) -> Bool { browserIDs.contains(app.bundleIdentifier ?? "") }

    /// Brings a running app (or finds and launches one by name) to the front with its window loaded.
    static func open(appNamed name: String) async -> NSRunningApplication? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let url = NSWorkspace.shared.runningApplications
            .first { $0.cleanName?.lowercased() == wanted }?.bundleURL ?? find(named: wanted)
        guard let url else { return nil }
        return await launch(url)
    }

    static func launch(_ url: URL) async -> NSRunningApplication? {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: config) else { return nil }
        // `open` on a running app whose windows are closed brings a window back.
        _ = await Shell.run("/usr/bin/open", [url.path])
        for _ in 0..<40 {
            if app.isActive, AXEngine.elements(of: app, limit: 5, menuBar: true).count > 1 { break }
            app.activate()
            try? await Task.sleep(for: .milliseconds(100))
        }
        return app
    }

    static func bringToFront(_ app: NSRunningApplication) async {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else { return }
        // Plain activate() is ignored while we aren't frontmost; opening the app always works.
        if let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            app.activate()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Opens a URL as a real tab (Arc would otherwise show external links in its "Little Arc" popup).
    static func openURL(_ url: URL) async {
        let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        if browser?.lastPathComponent == "Arc.app" {
            let script = "tell application \"Arc\" to tell front window to make new tab with properties {URL:\"\(url.absoluteString)\"}\ntell application \"Arc\" to activate"
            if await Shell.run("/usr/bin/osascript", ["-e", script]).status == 0 { return }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let browser {
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func find(named name: String) -> URL? {
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "\(fm.homeDirectoryForCurrentUser.path)/Applications", "/Applications/Utilities"]
        var fuzzy: URL?
        for dir in dirs {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                let base = item.dropLast(4).lowercased()
                if base == name { return URL(fileURLWithPath: "\(dir)/\(item)") }
                if fuzzy == nil, name.count >= 3, base.hasPrefix(name) || base.contains(name) {
                    fuzzy = URL(fileURLWithPath: "\(dir)/\(item)")
                }
            }
        }
        return fuzzy
    }
}

/// Runs a command off the main thread with a time limit.
enum Shell {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus, process.terminationReason == .uncaughtSignal ? text + "\n(timed out)" : text)
        }.value
    }
}

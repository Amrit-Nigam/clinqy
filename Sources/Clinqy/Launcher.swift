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
            if app.isActive, AXEngine.elements(of: app, limit: 5).count > 1 { break }
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

/// Durable facts the agent learns about the user ("mom = WhatsApp chat 'Mom ❤️'"), one per line.
enum Memory {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/clinqy/memory.md")

    static var facts: [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "- ")) }.filter { !$0.isEmpty }
    }

    /// Facts always worth sending: who the user is and how to reach/represent them.
    private static let corePattern = #"(?i)\b(the user is|name is|phone number|mobile number|default browser|messages people|based in|resume)\b"#

    /// Related words, so "order food" finds Swiggy and "apply" finds the resume.
    private static let related: [String: [String]] = [
        "food": ["swiggy", "zomato", "order", "eat", "hungry", "meal", "delivery", "protein", "subway"],
        "order": ["swiggy", "zomato", "food", "amazon", "buy", "delivery"],
        "apply": ["resume", "college", "cgpa", "internship", "internships", "experience", "linkedin", "github", "portfolio", "student", "won", "preference"],
        "application": ["resume", "college", "cgpa", "internships", "linkedin", "github", "portfolio", "student", "won", "preference"],
        "internship": ["resume", "internships", "cgpa", "college", "student", "linkedin", "github", "stack"],
        "form": ["resume", "college", "linkedin", "github", "preference", "email"],
        "job": ["resume", "internship", "experience", "linkedin"],
        "mail": ["gmail", "email", "account"], "gmail": ["email", "account", "somaiya"],
        "sign": ["account", "password", "incognito", "2-step", "verification", "email"],
        "login": ["account", "password", "incognito", "email"],
        "call": ["phone", "whatsapp", "meet"], "message": ["whatsapp", "chat"], "text": ["whatsapp", "chat"],
        "crypto": ["wallet", "okx", "testnet", "web3", "faucet"], "wallet": ["okx", "crypto"],
        "game": ["miaoo", "cat"], "cat": ["miaoo"],
        "music": ["youtube", "spotify", "lofi"], "play": ["youtube", "spotify", "miaoo"],
        "phone": ["iphone", "mirroring"], "iphone": ["mirroring"],
        "family": ["mother", "father", "find"], "mom": ["mother"], "mother": ["find"], "dad": ["father"],
        "college": ["kjsce", "somaiya", "lms", "codecell"], "class": ["kjsce", "somaiya", "lms", "meet"],
        "deliver": ["address"], "address": ["delivery", "swiggy"],
        "code": ["cursor", "github", "project"], "github": ["code", "repo"],
    ]

    private static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "into", "open", "please",
                                            "can", "you", "me", "my", "his", "her", "use", "get", "go", "to", "a", "an", "is"]

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 && !stop.contains($0) })
    }

    /// The facts worth sending for this request: the core ones plus those sharing words (or related words) with it.
    static func relevant(to context: String, limit: Int = 15) -> (facts: [String], omitted: Int) {
        let all = facts
        var want = words(context)
        for w in want { for (key, more) in related where w.hasPrefix(key) || key.hasPrefix(w) && w.count >= 4 { want.formUnion(more) } }
        var chosen: [String] = []
        var scored: [(String, Int)] = []
        for fact in all {
            if fact.range(of: corePattern, options: .regularExpression) != nil { chosen.append(fact); continue }
            let fw = words(fact)
            let score = fw.filter { f in want.contains { f.hasPrefix($0) || $0.hasPrefix(f) && f.count >= 4 } }.count
            if score > 0 { scored.append((fact, score)) }
        }
        chosen += scored.sorted { $0.1 > $1.1 }.prefix(max(0, limit - chosen.count)).map(\.0)
        return (chosen, all.count - chosen.count)
    }

    /// Searches everything remembered (for the agent's recall action).
    static func search(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return facts }
        let hits = relevant(to: q, limit: 40).facts.filter { fact in
            fact.range(of: corePattern, options: .regularExpression) == nil || !words(fact).isDisjoint(with: words(q))
        }
        return hits.isEmpty ? relevant(to: q, limit: 40).facts : hits
    }

    static func add(_ fact: String) {
        var all = facts.filter { $0 != fact }
        all.append(fact)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? all.suffix(60).map { "- \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

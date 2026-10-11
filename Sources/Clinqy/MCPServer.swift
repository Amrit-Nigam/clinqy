import AppKit

/// `Clinqy mcp`: Clinqy as an MCP server on stdio, so other agents (Antigravity CLI, Claude Code, Codex, Cursor…) can hand it
/// on-screen tasks. Dependency-free: newline-delimited JSON-RPC 2.0, as the MCP stdio transport specifies.
/// This process only relays: tasks go to the running app over clinqy:// links (like the `clinqy` command),
/// because the app holds the permissions, the browser extension and the cursor.
enum MCPServer {
    static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
    Clinqy operates the user's own Mac and browser (their logins, their tabs) with a visible companion cursor.
    clinqy_look first to see what's in front (read-only). clinqy_run for anything that needs clicking or typing: \
    describe the goal in plain words ("fill the signup form with my details", "open github and star this repo"); \
    Clinqy plans and verifies each step itself and asks the user before paying, sending or submitting. \
    One task at a time. clinqy_stats: how recent runs went.
    """

    private static func tool(_ name: String, _ title: String, _ description: String, _ props: [String: Any], required: [String] = [],
                             readOnly: Bool) -> [String: Any] {
        ["name": name, "title": title, "description": description,
         "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false],
         "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": !readOnly, "idempotentHint": readOnly,
                         "openWorldHint": !readOnly]]
    }

    static let tools: [[String: Any]] = [
        tool("clinqy_run", "Do a task on the Mac",
             "Carry out a natural-language task on the user's Mac with Clinqy: it clicks, types and reads in the frontmost app or "
             + "browser tab, and returns its steps and final answer. Not saved to the user's history or memory. dry=true only points "
             + "at what it would click or type.",
             ["task": ["type": "string", "description": "What to do, in plain words."],
              "dry": ["type": "boolean", "description": "Rehearse: point at each click and keystroke without doing it."],
              "timeout": ["type": "integer", "description": "Seconds to wait for the task to finish (default 300)."]],
             required: ["task"], readOnly: false),
        tool("clinqy_look", "Look at the screen",
             "What's in front right now, read-only. In a browser (with the Clinqy extension): the tab's title, URL, every field, button and "
             + "link with its w-id, values and errors, and the visible text; mode=read gives the page's full text. In other apps: the "
             + "window, focused element and visible controls from Accessibility.",
             ["mode": ["type": "string", "enum": ["page", "read", "url"], "description": "page (default), read (full text) or url."]],
             readOnly: true),
        tool("clinqy_stats", "Run statistics",
             "Success rate, time per run, model vs action time per turn, and the most common failure reasons (read-only). "
             + "last=true breaks down the most recent run turn by turn.",
             ["days": ["type": "number", "description": "How many days back (default 7)."],
              "last": ["type": "boolean", "description": "Only the most recent run, turn by turn."]],
             readOnly: true),
    ]

    /// Where JSON-RPC replies go: the real stdout, kept aside while stdout itself points at stderr.
    nonisolated(unsafe) private static var out: FileHandle!
    private static let writeQueue = DispatchQueue(label: "clinqy.mcp.write")
    /// Request ids of tasks in flight, so a cancel from the client stops the task in the app.
    nonisolated(unsafe) private static var running: Set<String> = []
    private static let lock = NSLock()

    static func serve() -> Never {
        // The protocol owns stdout: any stray print() would corrupt it, so stdout now goes to stderr.
        out = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)
        Thread.detachNewThread {
            // Requests run concurrently (a long clinqy_run mustn't block ping); at end of input, answer them all first.
            let inFlight = DispatchGroup()
            while let line = readLine(strippingNewline: true) {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                guard let msg = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
                    send(error(nil, -32700, "parse error")); continue
                }
                for m in (msg as? [[String: Any]]) ?? [(msg as? [String: Any]) ?? [:]] {
                    inFlight.enter()
                    Task.detached {
                        if let reply = await handle(m) { send(reply) }
                        inFlight.leave()
                    }
                }
            }
            inFlight.wait()
            exit(0)
        }
        // The main run loop keeps NSWorkspace (frontmost app) current.
        RunLoop.main.run()
        exit(0)
    }

    private static func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        writeQueue.sync { out.write(data + Data("\n".utf8)) }
    }

    private static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private static func text(_ s: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": s]], "isError": isError]
    }

    static func handle(_ msg: [String: Any]) async -> [String: Any]? {
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        guard let id = msg["id"] else {
            if method == "notifications/cancelled", let rid = params["requestId"] {
                let key = "\(rid)"
                let wasRunning = lock.withLock { running.remove(key) != nil }
                if wasRunning { openLink("cancel", [:]) }
            }
            return nil   // other notifications need no answer
        }
        let result: [String: Any]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            result = ["protocolVersion": versions.contains(asked) ? asked : versions[0],
                      "capabilities": ["tools": ["listChanged": false]],
                      "serverInfo": ["name": "clinqy", "title": "Clinqy", "version": appVersion],
                      "instructions": instructions]
        case "ping": result = [:]
        case "tools/list": result = ["tools": tools]
        case "resources/list": result = ["resources": []]
        case "prompts/list": result = ["prompts": []]
        case "tools/call":
            let args = params["arguments"] as? [String: Any] ?? [:]
            switch params["name"] as? String ?? "" {
            case "clinqy_run":
                guard let task = (args["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty
                else { return ["jsonrpc": "2.0", "id": id, "result": text("task is required", isError: true)] }
                let key = "\(id)"
                lock.withLock { _ = running.insert(key) }
                defer { lock.withLock { _ = running.remove(key) } }
                result = await run(task, dry: args["dry"] as? Bool == true, timeout: (args["timeout"] as? NSNumber)?.doubleValue ?? 300)
            case "clinqy_look": result = await look(mode: args["mode"] as? String ?? "page")
            case "clinqy_stats": result = text(Stats.report(days: (args["days"] as? NSNumber)?.doubleValue ?? 7, last: args["last"] as? Bool == true))
            case let other: return error(id, -32602, "unknown tool: \(other)")
            }
        default: return error(id, -32601, "method not found: \(method)")
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    // MARK: - Talking to the running app

    private static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clinqy")
    private static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clinqy/agent.log")

    /// The app, not this relay process (both are the same binary).
    private static var appRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.amritnigam.clinqy")
            .contains { $0.processIdentifier != getpid() && !$0.isTerminated }
    }

    private static func ensureApp() async -> Bool {
        if appRunning { return true }
        shell("/usr/bin/open", ["-g", "-b", "com.amritnigam.clinqy"])
        for _ in 0..<20 where !appRunning { try? await Task.sleep(for: .milliseconds(250)) }
        try? await Task.sleep(for: .seconds(2))   // let it register its URL handler and start the bridge
        return appRunning
    }

    /// Opens clinqy://<host>?… with the CLI token, in the background (like `open -g`), so focus stays where it is.
    @discardableResult
    static func openLink(_ host: String, _ query: [String: String]) -> Bool {
        let token = (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/clinqy/cli-token"),
                                 encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Encode everything but unreserved characters: "&", "=", "+" and "#" in a task must stay part of it.
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: safe) ?? "" }
        let q = (query.sorted { $0.key < $1.key } + [("token", token)]).map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
        guard let url = URL(string: "clinqy://\(host)?\(q)") else { return false }
        return shell("/usr/bin/open", ["-g", url.absoluteString]) == 0
    }

    @discardableResult
    private static func shell(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// agent.log from byte `offset` on (the app rotates it at 5 MB: a shorter file means start over).
    private static func readLog(from offset: inout UInt64) -> String {
        guard let h = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        try? h.seek(toOffset: offset)
        let data = (try? h.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        return String(decoding: data, as: UTF8.self)
    }

    static func run(_ task: String, dry: Bool, timeout: Double) async -> [String: Any] {
        guard await ensureApp() else { return text("Clinqy isn't installed or wouldn't start (build it with ./build.sh).", isError: true) }
        var offset = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? UInt64) ?? 0
        guard openLink("run", ["task": task, "test": "1"].merging(dry ? ["dry": "1"] : [:]) { a, _ in a }) else {
            return text("Couldn't open the clinqy:// link.", isError: true)
        }
        // The app ignores a task while another runs, so first see this one start ("=== <task>").
        let head = String(task.prefix(40))
        var started = false, lines: [String] = []
        let begun = Date(), deadline = begun.addingTimeInterval(max(10, timeout))
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { break }
            for line in readLog(from: &offset).split(separator: "\n").map(String.init) {
                if !started {
                    if line.hasPrefix("=== "), line.contains(head) { started = true }
                    continue
                }
                if line.hasPrefix("=== ") { break }   // a later run: ours ended without a verdict line
                let body = line.replacingOccurrences(of: #"^\[ *[0-9.]+s\] "#, with: "", options: .regularExpression)
                if body.hasPrefix("✓ ") || body.hasPrefix("✗ ") {
                    let ok = body.hasPrefix("✓")
                    let steps = lines.isEmpty ? "" : "Steps:\n" + lines.joined(separator: "\n") + "\n\n"
                    return text(steps + (ok ? "Done: " : "Failed: ") + body.dropFirst(2), isError: !ok)
                }
                if body.hasPrefix("  → ") { lines.append("- " + body.dropFirst(4)) }
                else if body.hasPrefix("    ✗ ") { lines.append("  (failed: \(body.dropFirst(6)))") }
            }
            if !started, Date().timeIntervalSince(begun) > 15 {
                return text("Clinqy didn't start the task: it's probably busy with another one (or the link was refused). Try again when it's idle.", isError: true)
            }
        }
        let so = lines.isEmpty ? "" : "\nSo far:\n" + lines.joined(separator: "\n")
        return text("Still running after \(Int(timeout)) s; it keeps going in the app (stop it from the menu bar)." + so, isError: true)
    }

    /// The browser tab through the extension; other apps (or no extension) through Accessibility.
    static func look(mode: String) async -> [String: Any] {
        let front = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        let isBrowser = await MainActor.run { front.map(Launcher.isBrowser) ?? false }
        var browserAnswer: String?
        if isBrowser, await ensureApp() {
            let id = "m\(getpid())-\(Int.random(in: 1000...999_999))"
            let file = support.appendingPathComponent("cli/\(id).txt")
            if openLink("browser", ["cmd": ["read", "url"].contains(mode) ? mode : "page", "id": id]) {
                for _ in 0..<60 {
                    if let s = try? String(contentsOf: file, encoding: .utf8) {
                        try? FileManager.default.removeItem(at: file)
                        browserAnswer = s
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            if let s = browserAnswer, !s.hasPrefix("ERROR:") { return text(s) }
        }
        guard let front else { return text(browserAnswer ?? "Nothing is in front.", isError: true) }
        guard AXIsProcessTrusted() else {
            return text((browserAnswer.map { $0 + "\n" } ?? "") + "Frontmost app: \(front.localizedName ?? "?"). "
                        + "(This process has no Accessibility permission, so it can't list the app's controls.)", isError: browserAnswer != nil)
        }
        AXEngine.enableManualAccessibility(front)
        let focus = AXEngine.focusSummary(of: front)
        let els = AXEngine.elements(of: front, limit: 150)
        var lines = ["\(front.localizedName ?? "?") — \(focus.window)", "Focused: \(focus.focused)"]
        if let b = browserAnswer { lines.append("(browser: \(b.dropFirst(7)))") }
        lines += els.map { "\($0.id) \($0.role.dropFirst(2)): \($0.label)" }
        return text(lines.joined(separator: "\n"))
    }
}

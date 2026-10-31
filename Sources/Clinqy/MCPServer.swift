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
    For direct control without an inner model, start clinqy_observe with the user's task. It returns a session,
    single-use observation and screenshot. Call clinqy_act, clinqy_wait or clinqy_verify with both tokens;
    observe again after every action. Never repeat input after a timeout; inspect and verify instead.
    Finish with clinqy_release complete=true only after verifying the final goal. complete=false stops.
    Direct control uses one foreground controller; delegated browser jobs run in independent background tabs. clinqy_stats: how recent runs went.
    """

    private static func tool(_ name: String, _ title: String, _ description: String, _ props: [String: Any], required: [String] = [],
                             readOnly: Bool) -> [String: Any] {
        ["name": name, "title": title, "description": description,
         "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false],
         "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": !readOnly,
                         "idempotentHint": readOnly && !["clinqy_observe", "clinqy_verify", "clinqy_wait"].contains(name),
                         "openWorldHint": !readOnly]]
    }

    static let directActionSchema: [String: Any] = ["type": "object", "additionalProperties": false,
        "properties": [
            "do": ["type": "string", "enum": ControlProtocol.actions.sorted()],
            "id": ["type": "string"], "to_id": ["type": "string"],
            "x": ["type": "number", "minimum": 0], "y": ["type": "number", "minimum": 0],
            "to_x": ["type": "number", "minimum": 0], "to_y": ["type": "number", "minimum": 0],
            "text": ["type": "string"], "keys": ["type": "string"], "name": ["type": "string"],
            "url": ["type": "string"], "path": ["type": "string"], "contains": ["type": "string"],
            "value": ["type": "string"], "submit": ["type": "boolean"], "dir": ["type": "string", "enum": ["up", "down"]],
            "for": ["type": "string"], "gone": ["type": "boolean"], "seconds": ["type": "number", "minimum": 0, "maximum": 15]
        ]]

    static let tools: [[String: Any]] = [
        tool("clinqy_run", "Do a task on the Mac",
             "Carry out a natural-language task on the user's Mac with Clinqy: it clicks, types and reads in the frontmost app or "
             + "browser tab, and returns its steps and final answer. Not saved to the user's history or memory. dry=true only points "
             + "at what it would click or type. background=true works out of the user's way: web pages in Clinqy's own browser "
             + "tab or headless Chrome worker. Native input requires an explicit foreground handoff.",
             ["task": ["type": "string", "description": "What to do, in plain words."],
              "dry": ["type": "boolean", "description": "Rehearse: point at each click and keystroke without doing it."],
              "background": ["type": "boolean", "description": "Work behind the user's windows without taking their screen, mouse or keyboard."],
              "timeout": ["type": "integer", "description": "Seconds to wait for the task to finish (default 300)."]],
             required: ["task"], readOnly: false),
        tool("clinqy_look", "Look at the screen",
             "What's in front right now, read-only. In a browser (with the Clinqy extension): the tab's title, URL, every field, button and "
             + "link with its w-id, values and errors, and the visible text; mode=read gives the page's full text. In other apps: the "
             + "window, focused element and visible controls from Accessibility.",
             ["mode": ["type": "string", "enum": ["page", "read", "url"], "description": "page (default), read (full text) or url."]],
             readOnly: true),
        tool("clinqy_observe", "Observe for direct control",
             "Start with task (the user's goal), then use session for subsequent observations. Returns semantic ids, a single-use observation token and a JPEG image when available. Reserves the foreground controller for 120 seconds. No inner model.",
             ["task": ["type": "string"], "session": ["type": "string"], "image": ["type": "boolean", "default": true]], readOnly: true),
        tool("clinqy_act", "Perform one precise action",
             "One action through Clinqy's existing target validation and approval path. Requires a fresh single-use observation. Returns delivery/status separately; unverified input must be checked before further mutation. Observe after each call, including errors; never automatically replay a timeout.",
             ["session": ["type": "string"], "observation": ["type": "string"], "action": directActionSchema],
             required: ["session", "observation", "action"], readOnly: false),
        tool("clinqy_verify", "Verify the task result",
             "Check current text, exact URL, field value/id or a modified saved file (optional contains). Resolves uncertain input only with independent postcondition evidence. Requires session, observation and condition.",
             ["session": ["type": "string"], "observation": ["type": "string"], "condition": directActionSchema],
             required: ["session", "observation", "condition"], readOnly: true),
        tool("clinqy_wait", "Wait for visible text",
             "Wait up to 15 seconds for text to appear or disappear. This does not verify a pending side effect. Requires a fresh observation; observe again afterward.",
             ["session": ["type": "string"], "observation": ["type": "string"], "text": ["type": "string"],
              "gone": ["type": "boolean"], "seconds": ["type": "number", "minimum": 0, "maximum": 15]],
             required: ["session", "observation", "text"], readOnly: true),
        tool("clinqy_release", "Release direct control",
             "complete=true requires a verified final goal; complete=false stops without claiming success. Does not undo actions. The session also expires after 120 seconds of inactivity.",
             ["session": ["type": "string"], "complete": ["type": "boolean", "default": false]], required: ["session"], readOnly: false),
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
    nonisolated(unsafe) private static var running: [String: String] = [:]
    nonisolated(unsafe) private static var controlRequests: [String: String] = [:]
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
                let receipt = lock.withLock { running.removeValue(forKey: key) }
                if let receipt { openLink("cancel", ["receipt": receipt]) }
                if let session = lock.withLock({ controlRequests[key] }) { openLink("control-cancel", ["session": session]) }
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
                let receipt = UUID().uuidString
                lock.withLock { running[key] = receipt }
                defer { lock.withLock { _ = running.removeValue(forKey: key) } }
                result = await run(task, dry: args["dry"] as? Bool == true, background: args["background"] as? Bool == true,
                                   timeout: (args["timeout"] as? NSNumber)?.doubleValue ?? 300, receipt: receipt)
            case "clinqy_observe", "clinqy_act", "clinqy_verify", "clinqy_wait", "clinqy_release":
                let name = params["name"] as? String ?? ""
                var body = args
                body["op"] = String(name.dropFirst("clinqy_".count))
                if name == "clinqy_verify" { body["action"] = args["condition"] }
                if name == "clinqy_wait" { body["action"] = ["do": "wait", "for": args["text"] ?? "", "gone": args["gone"] ?? false, "seconds": args["seconds"] ?? 15] }
                let key = "\(id)"
                if let session = args["session"] as? String { lock.withLock { controlRequests[key] = session } }
                defer { lock.withLock { _ = controlRequests.removeValue(forKey: key) } }
                result = await control(body)
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

    static func run(_ task: String, dry: Bool, background: Bool = false, timeout: Double, receipt: String = UUID().uuidString) async -> [String: Any] {
        guard await ensureApp() else { return text("Clinqy couldn't start. Build/install the app first.", isError: true) }
        let requestedMode = await MainActor.run { var text = task; return Background.choice(&text) }
        let useBackground = requestedMode ?? (background || (!dry && BrowserTaskRouting.isBrowserTask(task)))
        guard let file = RunReceipt.url(receipt),
              openLink("run", ["task": (requestedMode == nil && useBackground ? "in the background: " : "") + task, "test": "1", "id": receipt]
                .merging(dry ? ["dry": "1"] : [:]) { value, _ in value }) else { return text("Couldn't deliver task", isError: true) }
        defer { try? FileManager.default.removeItem(at: file) }
        let deadline = Date().addingTimeInterval(max(10, timeout))
        while Date() < deadline && !Task.isCancelled {
            if let data = try? Data(contentsOf: file), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let ok = result["ok"] as? Bool == true
                let steps = (result["steps"] as? [String] ?? []).map { "- " + $0 }.joined(separator: "\n")
                return text((steps.isEmpty ? "" : steps + "\n\n") + (ok ? "Done: " : "Needs checking: ") + (result["answer"] as? String ?? ""), isError: !ok)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return text("No final result yet. This task may still be queued or running; inspect its own task card before retrying.", isError: true)
    }

    /// Local file relay keeps large JSON arguments and images out of URL limits. A timed-out mutation
    /// must be inspected, not resent. The app claims each unique request before execution.
    static func control(_ arguments: [String: Any]) async -> [String: Any] {
        if let why = ControlProtocol.validateRequest(arguments) { return text(why, isError: true) }
        guard await ensureApp() else { return text("Clinqy couldn't start. Build/install the updated app first.", isError: true) }
        let id = UUID().uuidString
        let dir = support.appendingPathComponent("cli", isDirectory: true)
        let request = dir.appendingPathComponent(id + ".request.json"), response = dir.appendingPathComponent(id + ".response.json")
        var body = arguments
        body["deadline"] = Date().addingTimeInterval(180).timeIntervalSince1970
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let data = try JSONSerialization.data(withJSONObject: body)
            guard data.count <= 200_000 else { return text("Control request is too large", isError: true) }
            try data.write(to: request, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
        } catch { return text("Couldn't write control request", isError: true) }
        defer { try? FileManager.default.removeItem(at: request); try? FileManager.default.removeItem(at: response) }
        guard openLink("control", ["id": id]) else { return text("Couldn't deliver control request", isError: true) }
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline && !Task.isCancelled {
            if let data = try? Data(contentsOf: response), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return result }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return text("Control response unavailable. The action may have been delivered. Do not replay it; observe the existing session and verify the real outcome.", isError: true)
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

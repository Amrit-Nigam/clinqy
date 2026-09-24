import Foundation

/// GPT-backed step decider: used when Jev is unsure, and for anything that needs written text.
enum Planner {
    struct Step {
        enum Kind: String { case click, type, key, scroll, open_url, open_app, applescript, done, fail }
        let kind: Kind
        let element: Int?
        let text: String?
        let key: String?
        let reason: String
    }

    enum PlannerError: Error, LocalizedError {
        case missingKey, http(Int, String), bad(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: return "OPENAI_API_KEY not set (~/.config/cursorboy/env)"
            case .http(let c, let b): return "GPT HTTP \(c): \(b.prefix(200))"
            case .bad(let m): return "GPT returned something unusable: \(m)"
            }
        }
    }

    /// Claude Code CLI (uses the user's Claude login) is preferred; OpenAI is the fallback.
    static var claudePath: String? {
        if let explicit = Config.value("CLAUDE_PATH") { return explicit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var useClaude: Bool { Config.value("PLANNER") != "openai" && claudePath != nil }
    static var isAvailable: Bool { useClaude || Config.value("OPENAI_API_KEY") != nil }
    static var model: String { Config.value("OPENAI_MODEL") ?? "gpt-4.1-mini" }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static let system = """
    You operate a Mac app for the user through its accessibility tree. Each turn you get the user's request, \
    the app, the focused element, the actions already taken, and the visible elements as "e<N> <Role>: <label>". \
    Reply with ONE next action as JSON:
    {"action":"click","element":"e12","reason":"..."}
    {"action":"type","element":"e7","text":"exact text to type","reason":"..."}   (clicks e7 first, then types; replaces its contents)
    {"action":"key","key":"return|escape|tab|up|down|cmd+f|cmd+n|cmd+t|cmd+w|cmd+l|cmd+enter","reason":"..."}
    {"action":"scroll","key":"up|down","reason":"..."}
    {"action":"open_url","text":"https://...","reason":"..."}   (opens a web address in this app; use it for websites and web searches in a browser, e.g. https://www.youtube.com/results?search_query=technoblade — it's the fastest route)
    {"action":"done","reason":"..."}   (only when every part of the request is visibly complete)
    {"action":"fail","reason":"..."}   (the request can't be done here)
    A screenshot of the window is attached with red boxes tagged e<N> matching the list; use it to tell apart elements with similar labels (e.g. the chat-list search vs. the in-chat message search). \
    Rules: navigate to the right place first (click the named chat/contact/tab; use search only if it isn't visible). \
    Only type a message when the correct conversation/destination is open (e.g. "Messages in chat with X"). \
    If the request asks you to write something (a reply, a note), write it yourself, short and natural. \
    After typing a message, press return to send it. Don't repeat an action that already worked.
    """

    static func nextStep(task: String, app: String, focused: String, history: [String],
                         elements: [UIElementInfo], screenshot: String? = nil) async throws -> Step {
        guard let key = Config.value("OPENAI_API_KEY") else { throw PlannerError.missingKey }
        let screen = elements.enumerated()
            .map { "e\($0.offset) \($0.element.role.dropFirst(2)): \($0.element.label) @(\(Int($0.element.frame.midX)),\(Int($0.element.frame.midY)))" }
            .joined(separator: "\n")
        let user = """
        Request: \(task)
        App: \(app)
        Focused: \(focused)
        Actions so far: \(history.isEmpty ? "none" : history.joined(separator: "; "))
        Visible elements:
        \(screen)
        """

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0,
            "max_tokens": 200,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": screenshot.map { image -> Any in [
                    ["type": "text", "text": user],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image)", "detail": "high"]],
                ] } ?? user],
            ],
        ])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw PlannerError.http(status, String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
              let obj = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let kind = Step.Kind(rawValue: (obj["action"] as? String ?? "").lowercased()) else {
            throw PlannerError.bad("unparseable reply")
        }
        var element: Int?
        if let ref = obj["element"] as? String, let n = Int(ref.trimmingCharacters(in: CharacterSet(charactersIn: "e"))),
           n < elements.count {
            element = n
        }
        if (kind == .click || kind == .type), element == nil {
            throw PlannerError.bad("\(kind.rawValue) without a valid element")
        }
        return Step(kind: kind, element: element, text: obj["text"] as? String,
                    key: (obj["key"] as? String)?.lowercased(), reason: obj["reason"] as? String ?? "")
    }

    // MARK: - Plan once

    struct PlannedStep {
        let action: Step.Kind
        /// Visible label of the element to act on, as it will appear on screen at that point.
        let target: String?
        let text: String?
        let key: String?

        var summary: String {
            switch action {
            case .click: return "click \"\(target ?? "?")\""
            case .type: return "type \"\(text ?? "")\" into \"\(target ?? "?")\""
            case .key: return "press \(key ?? "?")"
            case .scroll: return "scroll \(key ?? "down")"
            case .open_url: return "open \(text ?? "")"
            case .open_app: return "switch to \(text ?? "?")"
            case .applescript: return "AppleScript: \(text?.replacingOccurrences(of: "\n", with: " ").prefix(60) ?? "")"
            case .done: return "done"
            case .fail: return "fail"
            }
        }
    }

    private static let planSystem = """
    You operate a Mac app for the user through its accessibility tree. You get the request, the app, what's been done,     the visible elements ("e<N> <Role>: <label> @(x,y)") and a screenshot with red boxes tagged e<N>.     Plan ALL the remaining steps at once. Later steps may target elements that will only appear after earlier steps     (e.g. a chat's message box after opening the chat) — describe them by the label they will most likely have.
    Reply as JSON: {"steps":[...], "reason":"..."} where each step is one of:
    {"action":"click","target":"<exact visible label, copied from the list>"}
    {"action":"type","target":"<exact text box label>","text":"exact text"}   (clicks the box, replaces its contents)
    {"action":"key","key":"return|escape|tab|up|down|cmd+f|cmd+n|cmd+t|cmd+w|cmd+l|cmd+enter"}
    {"action":"scroll","key":"up|down"}
    {"action":"applescript","text":"<full AppleScript>"}   (PREFERRED for scriptable Apple apps — Notes, Mail, Messages, Calendar, Reminders, Contacts, Finder, Safari, Music: one script does the whole job, no clicking; e.g. make a note, create a reminder, send an iMessage. Don't use it to click UI via System Events, and never for WhatsApp/Slack/Discord/Electron apps)
    {"action":"open_app","text":"<app name from Running apps or Installed apps>"}   (switch to another app; later steps then act in it)
    {"action":"open_url","text":"https://..."}   (ONLY when App is a browser, or the request is explicitly about a website; never guess domains for people or groups. Browsers: works from any state with no clicks needed first; the fastest route to any site or web search, e.g. https://www.youtube.com/results?search_query=technoblade)
    If the request is already complete reply {"steps":[],"reason":"..."}; if impossible, {"steps":[{"action":"fail"}],"reason":"why"}.
    First decide which app the request belongs in. If it isn't the current App (e.g. messaging a person or group → WhatsApp/Messages/Slack/Discord, whichever is running or installed), start with open_app. \
    Rules: open the right place first (click the named chat/contact/tab directly if visible; search only if not). \
    Type messages only into the message box of the correct conversation. Write any text the request asks for yourself, \
    short and natural. Send messages with return. Use the screenshot to tell apart similar labels (chat-list search vs in-chat search). \
    Keep plans minimal.
    """

    static func plan(task: String, app: String, focused: String, history: [String], elements: [UIElementInfo],
                     screenshot: String?, problem: String? = nil, isBrowser: Bool = false,
                     runningApps: [String] = [], installedApps: [String] = []) async throws -> (steps: [PlannedStep], reason: String) {
        let screen = elements.enumerated()
            .map { "e\($0.offset) \($0.element.role.dropFirst(2)): \($0.element.label) @(\(Int($0.element.frame.midX)),\(Int($0.element.frame.midY)))" }
            .joined(separator: "\n")
        var user = """
        Request: \(task)
        App: \(app)\(isBrowser ? " (a web browser)" : " (not a browser)")
        Running apps: \(runningApps.joined(separator: ", "))
        Installed apps: \(installedApps.joined(separator: ", "))
        Focused: \(focused)
        Done so far: \(history.isEmpty ? "nothing" : history.joined(separator: "; "))
        """
        if let problem { user += "\nThe previous plan failed: \(problem). Re-plan from the current screen." }
        user += "\nVisible elements:\n\(screen)"

        let obj = try await complete(system: planSystem, user: user, screenshot: screenshot, maxTokens: 500)
        let raw = obj["steps"] as? [[String: Any]] ?? []
        let steps: [PlannedStep] = raw.compactMap { step in
            guard let kind = Step.Kind(rawValue: (step["action"] as? String ?? "").lowercased()) else { return nil }
            return PlannedStep(action: kind, target: step["target"] as? String, text: step["text"] as? String,
                               key: (step["key"] as? String)?.lowercased())
        }
        return (steps, obj["reason"] as? String ?? "")
    }

    /// Models tried in order; on a rate limit (free tier: 50 requests/day per model) the next one is used.
    private static var models: [String] {
        if let pinned = Config.value("OPENAI_MODEL") { return [pinned] }
        return ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini", "gpt-4o", "gpt-4.1-nano"]
    }
    private static var exhausted: [String: Date] = [:]

    private static func complete(system: String, user: String, screenshot: String?, maxTokens: Int) async throws -> [String: Any] {
        if useClaude, let path = claudePath {
            return try await completeWithClaude(path: path, system: system, user: user, screenshot: screenshot)
        }
        guard let key = Config.value("OPENAI_API_KEY") else { throw PlannerError.missingKey }
        let content: Any = screenshot.map { image -> Any in [
            ["type": "text", "text": user],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image)", "detail": "high"]],
        ] } ?? user
        var lastError: Error = PlannerError.bad("no model available")
        for model in models where (exhausted[model] ?? .distantPast) < Date() {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "temperature": 0, "max_tokens": maxTokens,
                "response_format": ["type": "json_object"],
                "messages": [["role": "system", "content": system], ["role": "user", "content": content]],
            ])
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 {
                // Skip this model for a while; daily limits don't recover within a session.
                exhausted[model] = Date().addingTimeInterval(30 * 60)
                lastError = PlannerError.http(429, "\(model) rate-limited")
                continue
            }
            guard status == 200 else { throw PlannerError.http(status, String(data: data, encoding: .utf8) ?? "") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
                  let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw PlannerError.bad("unparseable reply")
            }
            return obj
        }
        throw lastError is PlannerError ? PlannerError.bad("all GPT models hit the free-tier daily limit; add billing at platform.openai.com or wait") : lastError
    }

    /// Runs `claude -p` headless with everything optional switched off (~2–3 s), screenshot included.
    private static func completeWithClaude(path: String, system: String, user: String, screenshot: String?) async throws -> [String: Any] {
        var content: [[String: Any]] = []
        if let screenshot {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": screenshot]])
        }
        content.append(["type": "text", "text": user])
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var input = try JSONSerialization.data(withJSONObject: message)
        input.append(0x0A)

        let model = Config.value("CLAUDE_MODEL") ?? "sonnet"
        let output: Data = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = [
                "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--model", model, "--tools", "", "--system-prompt", system + "\nReply with the JSON object only, no code fences.",
                "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence",
            ]
            let tmp = FileManager.default.temporaryDirectory
            process.currentDirectoryURL = tmp
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = Pipe()
            try process.run()
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value

        // The last "result" event carries the reply text.
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n").reversed() {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  event["type"] as? String == "result" else { continue }
            if event["is_error"] as? Bool == true {
                throw PlannerError.bad("Claude CLI: \(event["result"] as? String ?? "error")")
            }
            var text = (event["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") { text = String(text[start...end]) }
            guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw PlannerError.bad("Claude reply wasn't JSON")
            }
            return obj
        }
        throw PlannerError.bad("Claude CLI returned no result")
    }

    /// Writes just the text a request asks for ("write something motivating to X" → the message itself).
    static func writeText(for task: String) async throws -> String {
        let obj = try await complete(
            system: "You write the exact text a user asked to have sent or typed on their behalf. Match the tone asked for; keep it short (1-2 sentences) unless asked otherwise. Write it as the user, in first person, with no greeting labels or quotes. Reply as JSON {\"text\":\"...\"}.",
            user: "Request: \(task)", screenshot: nil, maxTokens: 200)
        guard let text = obj["text"] as? String, !text.isEmpty else { throw PlannerError.bad("no text written") }
        return text
    }

    /// Maps the planner's key names to our keyboard actions.
    static func keyAction(_ name: String) -> String? {
        switch name {
        case "return", "enter": return "enter"
        case "escape", "esc": return "key_esc"
        case "tab": return "key_tab"
        case "up": return "key_up"
        case "down": return "key_down"
        case "cmd+f": return "key_cmd_f"
        case "cmd+n": return "key_cmd_n"
        case "cmd+t": return "key_cmd_t"
        case "cmd+w": return "key_cmd_w"
        case "cmd+l": return "key_cmd_l"
        case "cmd+enter", "cmd+return": return "key_cmd_enter"
        default: return nil
        }
    }
}

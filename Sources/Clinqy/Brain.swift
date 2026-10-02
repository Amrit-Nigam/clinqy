import Foundation

/// A long-lived `claude -p` process speaking stream-json. Keeping it alive means each turn costs only
/// model time (~1 s), and the conversation (what was tried, what the screen looked like) stays in context.
final class ClaudeSession: @unchecked Sendable {
    enum BrainError: LocalizedError {
        case notInstalled, failed(String), died, busy

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Claude CLI not found. Install Claude Code (or set CLAUDE_PATH), or add an API key to ~/.config/clinqy/env"
            case .failed(let message):
                return message.contains("Not logged in") ? "Claude CLI isn't logged in. Run `claude` in a terminal once and log in." : message
            case .died: return "The Claude process stopped unexpectedly"
            case .busy: return "Still waiting on the previous reply"
            }
        }
    }

    static var claudePath: String? {
        if let explicit = Config.value("CLAUDE_PATH") { return explicit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: CheckedContinuation<String, Error>?
    /// The current turn's reply so far, and who wants to see it grow (see `send`).
    private var partialText = ""
    private var partialHandler: (@Sendable (String) -> Void)?
    private var dead = false
    /// Set when PROVIDER is an HTTP API (see Providers.swift): turns go there instead of to a `claude` process.
    private var api: APIChat?

    init(system: String, model: String) throws {
        let provider = Provider.current
        if provider != .claudeCLI {
            api = try APIChat(provider: provider, system: system, model: model)
            return
        }
        guard let path = Self.claudePath else { throw BrainError.notInstalled }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--model", model, "--effort", Config.value("CLAUDE_EFFORT") ?? "low", "--tools", "", "--system-prompt", system,
            "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence",
            // The reply as it's written, so the first action can start before the model has finished the rest.
            "--include-partial-messages",
        ]
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty { self.fail(BrainError.died); return }
            self.consume(chunk)
        }
        process.terminationHandler = { [weak self] _ in self?.fail(BrainError.died) }
        try process.run()
    }

    var isAlive: Bool {
        if let api { return api.isAlive }
        return lock.withLock { !dead } && process.isRunning
    }

    /// Sends one user turn (text plus an optional JPEG) and returns the reply text. `partial` sees the reply text so
    /// far each time it grows (on a background thread). The HTTP and one-shot CLI providers don't stream, so it isn't
    /// called for them.
    func send(_ text: String, image: String? = nil, partial: (@Sendable (String) -> Void)? = nil) async throws -> String {
        if let api { return try await api.send(text, image: image) }
        var content: [[String: Any]] = []
        if let image {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image]])
        }
        content.append(["type": "text", "text": text])
        var line = try JSONSerialization.data(withJSONObject: [
            "type": "user", "message": ["role": "user", "content": content],
        ])
        line.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if dead { lock.unlock(); continuation.resume(throwing: BrainError.died); return }
            if pending != nil { lock.unlock(); continuation.resume(throwing: BrainError.busy); return }
            pending = continuation
            partialText = ""
            partialHandler = partial
            lock.unlock()
            input.fileHandleForWriting.write(line)
        }
    }

    func close() {
        if let api { api.close(); return }
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        fail(BrainError.died)
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var results: [Result<String, Error>] = []
        var grown: String?
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if event["type"] as? String == "stream_event" {
                if let e = event["event"] as? [String: Any], let delta = e["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta", let piece = delta["text"] as? String, pending != nil {
                    partialText += piece
                    grown = partialText
                }
                continue
            }
            guard event["type"] as? String == "result" else { continue }
            let text = event["result"] as? String ?? ""
            results.append(event["is_error"] as? Bool == true ? .failure(BrainError.failed(text)) : .success(text))
        }
        var toResume: [(CheckedContinuation<String, Error>, Result<String, Error>)] = []
        for result in results {
            if let p = pending { toResume.append((p, result)); pending = nil; partialHandler = nil }
        }
        let handler = results.isEmpty ? partialHandler : nil
        lock.unlock()
        if let grown, let handler { handler(grown) }
        for (continuation, result) in toResume { continuation.resume(with: result) }
    }

    private func fail(_ error: Error) {
        lock.lock()
        dead = true
        let p = pending
        pending = nil
        partialHandler = nil
        lock.unlock()
        p?.resume(throwing: error)
    }
}

/// Keeps one session started ahead of time so a request never waits for process startup.
@MainActor
enum Brain {
    static var model: String { Config.value("CLAUDE_MODEL") ?? "sonnet" }
    private static var warm: ClaudeSession?

    static func prewarm() {
        if warm?.isAlive == true { return }
        warm = try? ClaudeSession(system: AgentPrompt.system, model: model)
    }

    /// Hands out the warm session (or a fresh one) and starts warming the next.
    static func session(model override: String? = nil) throws -> ClaudeSession {
        if let override, override != model { return try ClaudeSession(system: AgentPrompt.system, model: override) }
        let s: ClaudeSession
        if let w = warm, w.isAlive { s = w } else { s = try ClaudeSession(system: AgentPrompt.system, model: model) }
        warm = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { prewarm() }
        return s
    }

    /// Pulls the JSON object out of a reply, tolerating code fences or stray prose around it.
    static func json(from reply: String) -> [String: Any]? {
        if let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
           let obj = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] {
            // A bare action ({"do":"ask",…}) instead of the reply envelope: run it as the turn's only action.
            if obj["do"] != nil, obj["actions"] == nil { return ["say": "", "actions": [obj], "done": false] }
            return obj
        }
        // Sometimes the model writes tool-call tags instead (`<invoke name="scroll"><parameter name="dir">up</parameter>…`):
        // read every one, with its parameters, as an action.
        return invokes(in: reply)
    }

    /// The first action of a reply that's still being written, once that action is complete ("actions":[{…} closed).
    /// nil until then, or when the reply isn't the usual {"say","actions"} object.
    static func firstAction(inPartial text: String) -> [String: Any]? {
        guard let open = text.range(of: #""actions"\s*:\s*\["#, options: .regularExpression) else { return nil }
        var i = open.upperBound
        while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
        guard i < text.endIndex, text[i] == "{" else { return nil }
        let start = i
        var depth = 0, inString = false, escaped = false
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let object = String(text[start...i])
                    guard let action = try? JSONSerialization.jsonObject(with: Data(object.utf8)) as? [String: Any], action["do"] is String else { return nil }
                    return action
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    static func invokes(in reply: String) -> [String: Any]? {
        guard let block = try? NSRegularExpression(pattern: #"<invoke name="([A-Za-z_]+)"\s*/?>(.*?)(?:</invoke>|(?=<invoke )|$)"#,
                                                   options: [.dotMatchesLineSeparators]),
              let param = try? NSRegularExpression(pattern: #"<parameter name="([A-Za-z_]+)">(.*?)</parameter>"#,
                                                   options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = reply as NSString
        var actions: [[String: Any]] = []
        var done = false, say = ""
        for m in block.matches(in: reply, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            let body = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
            var action: [String: Any] = ["do": name]
            let bns = body as NSString
            for p in param.matches(in: body, range: NSRange(location: 0, length: bns.length)) {
                let key = bns.substring(with: p.range(at: 1))
                let raw = bns.substring(with: p.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                // Numbers, booleans, arrays arrive as JSON; anything else is text.
                action[key] = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) ?? raw
            }
            if name == "done" || name == "finish" { done = true; say = action["say"] as? String ?? action["text"] as? String ?? say; continue }
            actions.append(action)
        }
        guard !actions.isEmpty || done else { return nil }
        return ["say": say, "actions": actions, "done": done]
    }
}

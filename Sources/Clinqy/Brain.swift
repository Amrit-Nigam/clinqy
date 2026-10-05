import Foundation

/// A long-lived `agy` (or `claude -p`) process speaking stream-json. Keeping it alive means each turn costs only
/// model time (~1 s), and the conversation (what was tried, what the screen looked like) stays in context.
final class AgySession: @unchecked Sendable {
    enum BrainError: LocalizedError {
        case notInstalled, failed(String), died, busy

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Agy CLI not found. Install Antigravity (or set AGY_PATH), or add an API key to ~/.config/clinqy/env"
            case .failed(let message):
                return message.contains("Not logged in") ? "Agy CLI isn't logged in. Run `agy` in a terminal once and log in." : message
            case .died: return "The Agy process stopped unexpectedly"
            case .busy: return "Still waiting on the previous reply"
            }
        }
    }

    static var agyPath: String? {
        if let explicit = Config.value("AGY_PATH") ?? Config.value("CLAUDE_PATH") { return explicit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy",
                "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var claudePath: String? { agyPath }

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
    /// Set when PROVIDER is an HTTP API (see Providers.swift): turns go there instead of to a CLI process.
    private var api: APIChat?
    private var isAgy = true
    private var sessionDir: URL?
    private var systemPrompt = ""
    private var isFirstTurn = true

    init(system: String, model: String) throws {
        self.systemPrompt = system
        let provider = Provider.current
        if provider != .agyCLI && provider != .claudeCLI {
            api = try APIChat(provider: provider, system: system, model: model)
            return
        }
        guard let path = Self.agyPath else { throw BrainError.notInstalled }
        let execName = URL(fileURLWithPath: path).lastPathComponent
        isAgy = (provider == .agyCLI) || (execName == "agy")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-session-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.sessionDir = tempDir

        // Write AGENTS.md so agy automatically picks up system rules
        let agentsFile = tempDir.appendingPathComponent("AGENTS.md")
        try? system.write(to: agentsFile, atomically: true, encoding: .utf8)

        process.executableURL = URL(fileURLWithPath: path)
        if isAgy {
            var args = [
                "--input-format", "stream-json", "--output-format", "stream-json",
                "--disable-slash-commands", "--dangerously-skip-permissions",
            ]
            let effort = Config.value("AGY_EFFORT") ?? Config.value("CLAUDE_EFFORT") ?? "low"
            args += ["--effort", effort.lowercased()]
            let m = provider.model(model)
            if !m.isEmpty && m != "default" {
                args += ["--model", m]
            }
            process.arguments = args
        } else {
            process.arguments = [
                "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--model", model, "--effort", Config.value("CLAUDE_EFFORT") ?? "low", "--tools", "", "--system-prompt", system,
                "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence",
                "--include-partial-messages",
            ]
        }

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.currentDirectoryURL = tempDir
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

        var line: Data
        if isAgy {
            var promptText = text
            if isFirstTurn {
                promptText = "<instructions>\n\(systemPrompt)\n</instructions>\n\n" + promptText
                isFirstTurn = false
            }
            if let image, let imgData = Data(base64Encoded: image), let dir = sessionDir {
                let screenURL = dir.appendingPathComponent("screen.jpg")
                try? imgData.write(to: screenURL)
                promptText += "\n(Screenshot saved at \(screenURL.path). You can view it with view_file if needed.)"
            }
            let payload: [String: Any] = [
                "event": "user",
                "message": ["role": "user", "content": [["type": "text", "text": promptText]]]
            ]
            line = try JSONSerialization.data(withJSONObject: payload)
        } else {
            var content: [[String: Any]] = []
            if let image {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image]])
            }
            content.append(["type": "text", "text": text])
            line = try JSONSerialization.data(withJSONObject: [
                "type": "user", "message": ["role": "user", "content": content],
            ])
        }
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
        if let sessionDir { try? FileManager.default.removeItem(at: sessionDir) }
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
            // Agy streaming partial text
            if event["event"] as? String == "step_update",
               let step = event["step_update"] as? [String: Any],
               step["step_type"] as? String == "agent_response",
               let piece = step["text_delta"] as? String, pending != nil {
                partialText += piece
                grown = partialText
                continue
            }
            // Claude streaming partial text
            if event["type"] as? String == "stream_event" {
                if let e = event["event"] as? [String: Any], let delta = e["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta", let piece = delta["text"] as? String, pending != nil {
                    partialText += piece
                    grown = partialText
                }
                continue
            }
            // Agy final result
            if event["event"] as? String == "result", let res = event["result"] as? [String: Any] {
                let status = res["status"] as? String
                let text = res["response"] as? String ?? ""
                let err = res["error"] as? String
                if status == "ERROR" || (err != nil && !err!.isEmpty) {
                    results.append(.failure(BrainError.failed(err ?? (text.isEmpty ? "Agy process error" : text))))
                } else {
                    results.append(.success(text))
                }
                continue
            }
            // Claude final result
            if event["type"] as? String == "result" {
                let text = event["result"] as? String ?? ""
                results.append(event["is_error"] as? Bool == true ? .failure(BrainError.failed(text)) : .success(text))
                continue
            }
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

typealias ClaudeSession = AgySession

/// Keeps one session started ahead of time so a request never waits for process startup.
@MainActor
enum Brain {
    static var model: String { Config.value("AGY_MODEL") ?? Config.value("CLAUDE_MODEL") ?? "gemini-3.8-flash-high" }
    private static var warm: AgySession?

    static func prewarm() {
        if warm?.isAlive == true { return }
        warm = try? AgySession(system: AgentPrompt.system, model: model)
    }

    /// Hands out the warm session (or a fresh one) and starts warming the next.
    static func session(model override: String? = nil) throws -> AgySession {
        if let override, override != model { return try AgySession(system: AgentPrompt.system, model: override) }
        let s: AgySession
        if let w = warm, w.isAlive { s = w } else { s = try AgySession(system: AgentPrompt.system, model: model) }
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

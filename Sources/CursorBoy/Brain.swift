import Foundation

/// A long-lived `claude -p` process speaking stream-json. Keeping it alive means each turn costs only
/// model time (~1 s), and the conversation (what was tried, what the screen looked like) stays in context.
final class ClaudeSession: @unchecked Sendable {
    enum BrainError: LocalizedError {
        case notInstalled, failed(String), died, busy

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Claude CLI not found. Install Claude Code, or set CLAUDE_PATH in ~/.config/cursorboy/env"
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
    private var dead = false

    init(system: String, model: String) throws {
        guard let path = Self.claudePath else { throw BrainError.notInstalled }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--model", model, "--effort", Config.value("CLAUDE_EFFORT") ?? "low", "--tools", "", "--system-prompt", system,
            "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence",
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

    var isAlive: Bool { lock.withLock { !dead } && process.isRunning }

    /// Sends one user turn (text plus an optional JPEG) and returns the reply text.
    func send(_ text: String, image: String? = nil) async throws -> String {
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
            lock.unlock()
            input.fileHandleForWriting.write(line)
        }
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        fail(BrainError.died)
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var results: [Result<String, Error>] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  event["type"] as? String == "result" else { continue }
            let text = event["result"] as? String ?? ""
            results.append(event["is_error"] as? Bool == true ? .failure(BrainError.failed(text)) : .success(text))
        }
        var toResume: [(CheckedContinuation<String, Error>, Result<String, Error>)] = []
        for result in results {
            if let p = pending { toResume.append((p, result)); pending = nil }
        }
        lock.unlock()
        for (continuation, result) in toResume { continuation.resume(with: result) }
    }

    private func fail(_ error: Error) {
        lock.lock()
        dead = true
        let p = pending
        pending = nil
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
    static func session() throws -> ClaudeSession {
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
            return obj
        }
        // Sometimes the model writes a tool-call tag instead (`<invoke name="look">`): treat it as that action.
        if let range = reply.range(of: #"<invoke name="([a-z_]+)""#, options: .regularExpression) {
            let name = reply[range].replacingOccurrences(of: "<invoke name=\"", with: "").replacingOccurrences(of: "\"", with: "")
            return ["say": "", "actions": [["do": name]], "done": false]
        }
        return nil
    }
}

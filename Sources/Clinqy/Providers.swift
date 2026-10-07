import Foundation

/// Which model service answers: a coding CLI you're already logged into (Claude Code, the default; Codex; Gemini
/// CLI) or a provider's HTTP API with your own key. Set PROVIDER in ~/.config/clinqy/env, or just add a key: with no
/// `claude` CLI installed, the first key found is used, then the first other CLI found.
enum Provider: String, CaseIterable {
    case claudeCLI = "claude-cli", codexCLI = "codex-cli", geminiCLI = "gemini-cli"
    case anthropic, openai, gemini, openrouter, ollama, compatible = "openai-compatible"

    static var current: Provider {
        if let raw = Config.value("PROVIDER")?.lowercased() {
            switch raw {
            case "claude", "claude-code", "cli": return .claudeCLI
            case "codex": return .codexCLI
            case "gpt", "chatgpt": return .openai
            case "google": return .gemini
            case "compatible", "custom": return .compatible
            default: if let p = Provider(rawValue: raw) { return p }
            }
        }
        if ClaudeSession.claudePath != nil { return .claudeCLI }
        return [.anthropic, .openai, .gemini, .openrouter].first { $0.key != nil }
            ?? [.codexCLI, .geminiCLI].first { $0.cliPath != nil } ?? .claudeCLI
    }

    /// The CLI's executable, for the CLI providers (CODEX_PATH / GEMINI_PATH, else the usual install spots).
    var cliPath: String? {
        let name: String
        switch self {
        case .claudeCLI: return ClaudeSession.claudePath
        case .codexCLI: name = "codex"
        case .geminiCLI: name = "gemini"
        default: return nil
        }
        if let explicit = Config.value(name.uppercased() + "_PATH") { return explicit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.npm-global/bin/\(name)", "\(home)/.bun/bin/\(name)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isCLI: Bool { self == .claudeCLI || self == .codexCLI || self == .geminiCLI }

    var key: String? {
        let names: [String]
        switch self {
        case .claudeCLI, .codexCLI, .geminiCLI, .ollama: return nil
        case .anthropic: names = ["ANTHROPIC_API_KEY"]
        case .openai: names = ["OPENAI_API_KEY"]
        case .gemini: names = ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .openrouter: names = ["OPENROUTER_API_KEY"]
        case .compatible: names = ["OPENAI_COMPATIBLE_API_KEY", "OPENAI_API_KEY"]
        }
        return names.lazy.compactMap { Config.value($0) }.first { !$0.isEmpty }
    }

    /// The model id for one of the app's names for a model ("sonnet" for the agent, "haiku" for the fast helper,
    /// "opus" for `--model opus`). Anything else is taken as the provider's own model id.
    func model(_ name: String) -> String {
        let alias = name.lowercased()
        let tier = ["haiku": 0, "sonnet": 1, "opus": 2][alias]
        guard let tier else { return name }
        switch self {
        case .claudeCLI: return alias == "haiku" ? "claude-haiku-5-5" : name
        // The CLIs pick their own default model for your account; only an explicit model id is passed on.
        case .codexCLI, .geminiCLI: return ""
        case .anthropic: return ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"][tier]
        case .openrouter: return ["anthropic/claude-haiku-5.5", "anthropic/claude-sonnet-5.5", "anthropic/claude-opus-5.5"][tier]
        case .openai: return ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"][tier]
        case .gemini: return ["gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.6-flash"][tier]
        case .ollama, .compatible: return Config.value("LOCAL_MODEL") ?? "qwen3-vl"
        }
    }

    var label: String {
        switch self {
        case .claudeCLI: return "Claude Code CLI: \(ClaudeSession.claudePath ?? "❌ not found")"
        case .codexCLI: return "Codex CLI: \(cliPath ?? "❌ not found")"
        case .geminiCLI: return "Gemini CLI: \(cliPath ?? "❌ not found")"
        case .ollama: return "Ollama (\(baseURL))"
        case .compatible: return "OpenAI-compatible API (\(baseURL)\(key == nil ? ", no key" : ""))"
        default: return "\(rawValue) API (\(key == nil ? "❌ no key" : "key set"))"
        }
    }

    var baseURL: String {
        let explicit = Config.value("OPENAI_BASE_URL").map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        switch self {
        case .openai: return explicit ?? "https://api.openai.com/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .ollama: return explicit ?? "http://localhost:11434/v1"
        case .compatible: return explicit ?? "http://localhost:1234/v1"
        case .anthropic: return Config.value("ANTHROPIC_BASE_URL") ?? "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .claudeCLI, .codexCLI, .geminiCLI: return ""
        }
    }
}

/// One conversation over a provider's HTTP API (or a one-shot `codex exec` / `gemini -p` per turn), standing in for
/// the `claude` process: it keeps the whole exchange so each turn has the same context the CLI session would.
final class APIChat: @unchecked Sendable {
    private struct Turn { var user: Bool; var text: String; var image: String? }

    private let provider: Provider
    private let key: String?
    private let system: String
    private let model: String
    private let effort: String
    private let lock = NSLock()
    private var turns: [Turn] = []
    private var inFlight: Task<String, Error>?
    private var closed = false
    /// Set after the provider rejected the reasoning setting for this model, so later turns leave it out.
    private var plain = false

    init(provider: Provider, system: String, model: String) throws {
        let key = provider.key
        if provider.isCLI, provider.cliPath == nil {
            throw ClaudeSession.BrainError.failed("\(provider.rawValue): not found. Install it, or set \(provider == .codexCLI ? "CODEX_PATH" : "GEMINI_PATH") in ~/.config/clinqy/env")
        }
        if key == nil, !provider.isCLI, provider != .ollama, provider != .compatible {
            throw ClaudeSession.BrainError.failed("No API key for \(provider.rawValue). Add it to ~/.config/clinqy/env (see the README).")
        }
        self.provider = provider
        self.key = key
        self.system = system
        self.model = provider.model(model)
        effort = (Config.value("CLAUDE_EFFORT") ?? "low").lowercased()
    }

    var isAlive: Bool { lock.withLock { !closed } }

    func close() {
        lock.lock()
        closed = true
        let task = inFlight
        lock.unlock()
        task?.cancel()
    }

    func send(_ text: String, image: String?) async throws -> String {
        let task = try lock.withLock { () throws -> Task<String, Error> in
            if closed { throw ClaudeSession.BrainError.died }
            if inFlight != nil { throw ClaudeSession.BrainError.busy }
            turns.append(Turn(user: true, text: text, image: image))
            let task = Task { try await self.complete() }
            inFlight = task
            return task
        }
        do {
            let reply = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            lock.withLock { turns.append(Turn(user: false, text: reply, image: nil)); inFlight = nil }
            return reply
        } catch {
            // Drop the unanswered turn so the conversation still alternates.
            lock.withLock { if turns.last?.user == true { turns.removeLast() }; inFlight = nil }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw ClaudeSession.BrainError.died }
            throw error
        }
    }

    private func complete() async throws -> String {
        // Only the newest screenshot is sent again: older ones cost tokens on every turn and are out of date anyway.
        let history = lock.withLock { () -> [Turn] in
            let lastImage = turns.lastIndex { $0.image != nil }
            return turns.enumerated().map { i, t in
                var t = t
                if t.image != nil, i != lastImage { t.image = nil; t.text = "[earlier screenshot omitted]\n" + t.text }
                return t
            }
        }
        do {
            return try await request(history, plain: lock.withLock { plain })
        } catch ClaudeSession.BrainError.failed(let message) where message.hasPrefix("HTTP 400") && [.openai, .gemini].contains(provider) && !lock.withLock({ plain }) {
            lock.withLock { plain = true }
            return try await request(history, plain: true)
        }
    }

    private func request(_ history: [Turn], plain: Bool) async throws -> String {
        if provider == .codexCLI || provider == .geminiCLI { return try await runCLI(history) }
        var req: URLRequest
        var body: [String: Any]
        switch provider {
        case .anthropic:
            req = URLRequest(url: URL(string: provider.baseURL + "/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var messages: [[String: Any]] = history.map { t in
                var content: [[String: Any]] = []
                if let image = t.image {
                    content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image]])
                }
                content.append(["type": "text", "text": t.text])
                return ["role": t.user ? "user" : "assistant", "content": content]
            }
            // Cache the conversation so far: each turn then only pays for what's new.
            if var last = messages.popLast(), var content = last["content"] as? [[String: Any]], !content.isEmpty {
                content[content.count - 1]["cache_control"] = ["type": "ephemeral"]
                last["content"] = content
                messages.append(last)
            }
            body = [
                "model": model, "max_tokens": 8192, "messages": messages,
                "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            ]
        case .gemini:
            req = URLRequest(url: URL(string: "\(provider.baseURL)/models/\(model):generateContent")!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let contents: [[String: Any]] = history.map { t in
                var parts: [[String: Any]] = []
                if let image = t.image { parts.append(["inlineData": ["mimeType": "image/jpeg", "data": image]]) }
                parts.append(["text": t.text])
                return ["role": t.user ? "user" : "model", "parts": parts]
            }
            var generation: [String: Any] = ["maxOutputTokens": 8192]
            if !plain { generation["thinkingConfig"] = ["thinkingLevel": effort == "high" || effort == "max" ? "high" : "low"] }
            body = ["systemInstruction": ["parts": [["text": system]]], "contents": contents, "generationConfig": generation]
        case .openai, .openrouter, .ollama, .compatible:
            req = URLRequest(url: URL(string: provider.baseURL + "/chat/completions")!)
            if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            if provider == .openrouter { req.setValue("Clinqy", forHTTPHeaderField: "X-Title") }
            var messages: [[String: Any]] = [["role": "system", "content": system]]
            for t in history {
                if let image = t.image {
                    messages.append(["role": "user", "content": [
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image)"]],
                        ["type": "text", "text": t.text],
                    ]])
                } else {
                    messages.append(["role": t.user ? "user" : "assistant", "content": t.text])
                }
            }
            body = ["model": model, "messages": messages]
            if !plain, provider == .openai, model.hasPrefix("gpt-5") || model.range(of: #"^o\d"#, options: .regularExpression) != nil {
                body["reasoning_effort"] = ["min", "minimal", "none"].contains(effort) ? "minimal" : effort == "max" ? "high" : effort
            }
        case .claudeCLI, .codexCLI, .geminiCLI:
            throw ClaudeSession.BrainError.failed("\(provider.rawValue) isn't an HTTP provider")
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = json?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? (json?["error"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw ClaudeSession.BrainError.failed("HTTP \(status) from \(provider.rawValue): \(message)")
        }
        let text: String?
        switch provider {
        case .anthropic:
            text = (json?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        case .gemini:
            let parts = ((json?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            text = parts?.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        default:
            let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            text = message?["content"] as? String
        }
        guard let text, !text.isEmpty else {
            throw ClaudeSession.BrainError.failed("Empty reply from \(provider.rawValue) (\(model))")
        }
        return text
    }

    /// Codex and Gemini CLI have no long-lived chat mode to talk to, so each turn runs the CLI once with the
    /// instructions and the conversation so far on stdin, and the screenshot as a file.
    private func runCLI(_ history: [Turn]) async throws -> String {
        guard let path = provider.cliPath else { throw ClaudeSession.BrainError.notInstalled }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-\(provider.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let imageURL = dir.appendingPathComponent("screen.jpg")
        let hasImage = history.last?.image.flatMap { Data(base64Encoded: $0) }.map { (try? $0.write(to: imageURL)) != nil } ?? false
        let lastURL = dir.appendingPathComponent("last.txt")

        var transcript = "<instructions>\n\(system)\n</instructions>\n\n"
        for t in history { transcript += t.user ? "<user>\n\(t.text)\n</user>\n\n" : "<assistant>\n\(t.text)\n</assistant>\n\n" }
        transcript += "Write only the assistant's next reply to the last <user> turn, following <instructions>. Don't run commands or edit files."

        var args: [String]
        switch provider {
        case .codexCLI:
            args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never", "--output-last-message", lastURL.path]
            if hasImage { args += ["--image", imageURL.path] }
        default:
            // Gemini CLI appends stdin to -p; `@file` attaches the screenshot.
            args = ["-p", hasImage ? "The current screen is attached: @\(imageURL.path)" : "Reply as asked below."]
        }
        if !model.isEmpty { args += ["--model", model] }
        if provider == .codexCLI { args.append("-") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.currentDirectoryURL = dir
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let stdout = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let name = provider.rawValue
                DispatchQueue.global().async {
                    do { try process.run() } catch { continuation.resume(throwing: error); return }
                    // Drain stderr and feed stdin alongside reading stdout, so no pipe fills up and stalls the CLI.
                    let errBox = ErrorBox(), group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async { errBox.data = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                    DispatchQueue.global().async {
                        input.fileHandleForWriting.write(Data(transcript.utf8))
                        try? input.fileHandleForWriting.close()
                    }
                    let out = output.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 { continuation.resume(returning: out); return }
                    let err = String(decoding: errBox.data.suffix(400), as: UTF8.self)
                    continuation.resume(throwing: ClaudeSession.BrainError.failed("\(name) exited \(process.terminationStatus): \(err)"))
                }
            }
        } onCancel: { process.terminate() }

        let reply = (try? String(contentsOf: lastURL, encoding: .utf8)) ?? String(decoding: stdout, as: UTF8.self)
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeSession.BrainError.failed("Empty reply from \(provider.rawValue)") }
        return text
    }
}

private final class ErrorBox: @unchecked Sendable { var data = Data() }

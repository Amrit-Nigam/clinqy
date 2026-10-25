import Foundation

/// A long-lived `agy` (or `claude -p`) process speaking stream-json. Keeping it alive means each turn costs only
/// model time (~1 s), and the conversation (what was tried, what the screen looked like) stays in context.
final class AgySession: @unchecked Sendable {
    enum BrainError: LocalizedError {
        case notInstalled, failed(String), died, busy

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return Provider.current == .agyCLI
                    ? "Agy CLI not found. Install Antigravity (or set AGY_PATH), or add an API key to ~/.config/clinqy/env"
                    : "Claude CLI not found. Install Claude Code (or set CLAUDE_PATH), or add an API key to ~/.config/clinqy/env"
            case .failed(let message):
                if message.contains("Not logged in") {
                    return Provider.current == .agyCLI
                        ? "Agy CLI isn't logged in. Run `agy` in a terminal once and log in."
                        : "Claude CLI isn't logged in. Run `claude` in a terminal once and log in."
                }
                return message
            case .died: return Provider.current == .agyCLI ? "The Agy process stopped unexpectedly" : "The Claude process stopped unexpectedly"
            case .busy: return "Still waiting on the previous reply"
            }
        }
    }

    static var agyPath: String? {
        if let explicit = Config.value("AGY_PATH") { return explicit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var claudePath: String? {
        if let explicit = Config.value("CLAUDE_PATH") { return explicit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    let sessionProvider: Provider
    let sessionModel: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: CheckedContinuation<String, Error>?
    /// The current turn's reply so far, and who wants to see it grow (see `send`).
    private var partialText = ""
    private var partialHandler: (@Sendable (String) -> Void)?
    private var dead = false
    /// The current turn's error (an error_message step or an ERROR result), cleared when a turn starts or succeeds,
    /// so a session that dies later isn't blamed on a harmless one from long ago.
    private var lastErrorMessage: String?
    /// The last thing the CLI wrote to stderr. Kept apart: agy writes chatter there too ("stream input cancelled"
    /// on shutdown), so it only explains a death that no turn error does.
    private var lastStderr: String?
    /// Set when PROVIDER is an HTTP API (see Providers.swift): turns go there instead of to a CLI process.
    private var api: APIChat?
    private var isAgy = true
    private var sessionDir: URL?
    private var systemPrompt = ""
    private var isFirstTurn = true
    /// agy: how many turns have carried a screenshot (each gets its own file, see `send`), and the last such file.
    private var screenshotCount = 0
    private var lastScreenshot: URL?
    /// agy: the CLI's own tools the model called during the current turn that aren't viewing the screenshot
    /// (run_command, browser_*, write_to_file…). They can't reach the user's screen; the next turn says so.
    private var strayTools: [String] = []
    /// agy: whether this turn carries a screenshot file (`lastScreenshot` stays set across turns, so it can't tell),
    /// whether the model viewed it, and whether the turn's reply came without that.
    private var turnHasScreenshot = false
    private var viewedScreenshot = false
    private var replySkippedScreenshot = false
    /// agy: the step_index of the agent_response the current reply text comes from (see `consume`).
    private var responseStep: Int?
    /// Token counts of the last turn, from the CLI's result event (agy reports them; claude -p doesn't here).
    private var lastUsage: (input: Int?, output: Int?) = (nil, nil)
    /// agy: its result's usage is the session's running total; the totals at the last result, to take each turn's share.
    private var usageTotals: (input: Int, output: Int, turns: Int) = (0, 0, 0)
    /// The --effort the session was started with, nil when none was passed (claude-* and other non-Gemini agy ids
    /// take none: their effort is fixed by the model).
    private(set) var effortArg: String?
    /// Where `note` lines go and what they're labeled ("lead", "helper", "think"…), so the agent log tells sessions
    /// apart and masks the run's secrets. Set right after creating the session, before the first `send`; without a
    /// logger, notes go straight to the log file.
    var log: (@MainActor @Sendable (String) -> Void)?
    var label = "agy"

    /// Whether the last reply came without the model viewing that turn's screenshot (agy only), so x/y in it
    /// are guesses or from an older screenshot.
    var skippedScreenshot: Bool { lock.withLock { replySkippedScreenshot } }

    /// What's different about running inside the Antigravity CLI, added to the rules for agy sessions. The CLI
    /// gives the model ~60 coding and browser tools of its own and auto-approves them (`--dangerously-skip-permissions`;
    /// without it a denied tool leaves the stream-json session out of step with its turns, checked on 1.4.7).
    /// Stream-json input takes text only (an image block is refused), so the screenshot reaches the model as a file
    /// it must open itself — told to "view it if needed", Gemini Flash never did; told to view it first, it does.
    static let agyAddendum = """


    You are running inside the Antigravity CLI, which offers you its own coding and browser tools. Don't use them: \
    nothing they do reaches the user's screen, and everything on the Mac is done only through the JSON actions. \
    The one exception: when a turn names a screenshot file, view that file with view_file first (it's the only way \
    to see the screen), then reply with the JSON. Never run commands, write or edit files, open a browser or search \
    the web yourself.
    """

    /// The same for agy sessions that aren't the agent (think, memory tidy, skills, connection checks): their rules
    /// ask for a format of their own, and the agent addendum would have them answer with the action JSON.
    static let agyPlainAddendum = "\n\nYou are running inside the Antigravity CLI, which offers you its own tools. "
        + "Don't call any of them (no commands, files, browser or web search): answer only from the text of the message, "
        + "in the format asked for above."

    /// Tools the model may use in an agy session: only viewing the screenshot file of the turn.
    private static let screenshotTools: Set<String> = ["view_file", "read_file", "view_content_chunk"]

    /// The id and --effort an agy session starts with, from a tier alias or id and the effort asked for (or
    /// AGY_EFFORT / CLAUDE_EFFORT). Only gemini-* ids are measured to take --effort (agy 1.4.7); claude-* ids refuse
    /// it as a hard error and the rest (gpt-oss-*, "default") are untested, so they get none and keep their id as
    /// given. A future non-Gemini id that does take --effort has to be added to `takesEffort`.
    static func launchModel(provider: Provider, model: String, effort: String?) -> (id: String, effort: String?) {
        let m = provider.model(model)
        let explicit = (effort ?? Config.value("AGY_EFFORT") ?? Config.value("CLAUDE_EFFORT"))?
            .trimmingCharacters(in: .whitespaces).lowercased()
        let explicitEffort = explicit.flatMap { $0.isEmpty ? nil : $0 }
        let takesEffort = m.lowercased().hasPrefix("gemini-")
        guard takesEffort else { return (m, nil) }
        if let suffix = ["-low", "-medium", "-high", "-xhigh", "-max"].first(where: { m.hasSuffix($0) }) {
            // The id carries its effort (gemini-3.8-flash-low): keep it, unless one is asked for: then the bare id
            // plus --effort, since agy refuses the two together.
            guard let explicitEffort else { return (m, nil) }
            return (String(m.dropLast(suffix.count)), explicitEffort)
        }
        return (m, explicitEffort ?? "low")
    }

    /// `effort` overrides the configured reasoning effort (AGY_EFFORT / CLAUDE_EFFORT) for this session.
    init(system: String, model: String, provider: Provider = Provider.current, effort: String? = nil) throws {
        self.systemPrompt = system
        self.sessionProvider = provider
        self.sessionModel = provider.model(model)
        if provider != .agyCLI && provider != .claudeCLI {
            api = try APIChat(provider: provider, system: system, model: model, effort: effort)
            effortArg = effort
            return
        }
        let path = provider == .agyCLI ? Self.agyPath : Self.claudePath
        guard let path else { throw BrainError.notInstalled }
        let execName = URL(fileURLWithPath: path).lastPathComponent
        isAgy = (provider == .agyCLI) || (execName == "agy")
        // The agent's sessions (Brain's and FastLane's rules start with the agent prompt) get the agent addendum;
        // the rest (think, memory tidy, skills, connection checks) are only told not to use the CLI's tools.
        if isAgy { systemPrompt = system + (system.hasPrefix(AgentPrompt.system) ? Self.agyAddendum : Self.agyPlainAddendum) }

        // The session's own folder: the CLI's working directory, and where its screenshots go. Nothing else goes in
        // it. The rules used to be written there as AGENTS.md too (agy loads that as workspace rules), but a rules
        // file in the folder sent Gemini Flash off reading it again and hunting for a task.json and session.json next
        // to it: a 190 s first turn instead of 10 s. The rules go in the first turn, as on Windows.
        // Named after this process, so the cleanup can tell whether its owner is still running.
        Self.removeStaleSessionDirs()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clinqy-session-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.sessionDir = tempDir

        process.executableURL = URL(fileURLWithPath: path)
        if isAgy {
            var args = [
                "--sandbox",
                "--input-format", "stream-json", "--output-format", "stream-json",
                "--disable-slash-commands", "--dangerously-skip-permissions",
            ]
            let launch = Self.launchModel(provider: provider, model: model, effort: effort)
            if let e = launch.effort { args += ["--effort", e] }
            if !launch.id.isEmpty && launch.id != "default" {
                args += ["--model", launch.id]
            }
            effortArg = launch.effort
            process.arguments = args
        } else {
            let claudeEffort = effort ?? Config.value("CLAUDE_EFFORT") ?? "low"
            effortArg = claudeEffort
            process.arguments = [
                "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--model", model, "--effort", claudeEffort, "--tools", "", "--system-prompt", system,
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
        process.standardError = errorPipe

        // At EOF a readability handler is called again and again with no data until it's removed (~250k times a
        // second, even after the session is gone), so each one removes itself on its first empty read.
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }
            if let str = String(data: chunk, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                self.lock.withLock { self.lastStderr = str }
            }
        }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; self?.fail(BrainError.died); return }
            self?.consume(chunk)
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
        var shotThisTurn = false
        if isAgy {
            var promptText = text
            if isFirstTurn {
                promptText = "<instructions>\n\(systemPrompt)\n</instructions>\n\n" + promptText
                isFirstTurn = false
            }
            // The model reached for the CLI's own tools last turn: say why that got it nowhere before anything else.
            // Not as a reprimand (that drew an apology in prose plus two JSON objects), and with what they returned
            // set aside: a command's output or a browser screenshot isn't the user's screen.
            let stray = lock.withLock { () -> [String] in let s = strayTools; strayTools = []; return s }
            if !stray.isEmpty {
                let names = Array(Set(stray)).sorted().joined(separator: ", ")
                promptText = "(Last turn you called \(names). Those tools can't see or touch the user's screen: ignore anything "
                    + "they returned, don't call them again, and don't mention this. Only the JSON actions act on the screen.)\n\n"
                    + promptText
            }
            // Stream-json input is text only, so the screenshot goes in a file. A new name each time: the model
            // remembers what the last file showed, and a same-named file would read as already seen.
            if let image, let imgData = Data(base64Encoded: image), let dir = sessionDir {
                let n = lock.withLock { () -> Int in screenshotCount += 1; return screenshotCount }
                let screenURL = dir.appendingPathComponent("screen-\(n).jpg")
                // The folder is agy's cwd too; if anything took it away (macOS clears old temp files), make it again.
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                do {
                    try imgData.write(to: screenURL)
                    shotThisTurn = true
                    let previous = lock.withLock { () -> URL? in let p = lastScreenshot; lastScreenshot = screenURL; return p }
                    if let previous { try? FileManager.default.removeItem(at: previous) }
                    promptText = promptText.replacingOccurrences(of: "(Screenshot attached:", with: "(Screenshot in the file below:")
                    // From the second one on, say it's new: shown the same path twice, or a new name alone, the
                    // model answered from its memory of the last one. Not that the screen changed, though: the
                    // retry look after failed steps usually shows the same screen.
                    let fresh = n > 1 ? " (new, taken just now; look at it again rather than going by earlier screenshots)" : ""
                    let line = "Screenshot for this turn: \(screenURL.path)\(fresh) — view it with view_file now, before replying "
                        + "(its red boxes carry the e<N> ids; x/y in click/point are pixels in it)."
                    // Right after the "(Screenshot in the file below: …)" marker, before the turn's closing lines
                    // (Agent's "…starting with {", then FastLane's "— no tool-call or XML tags"), as bench.py measured:
                    // the "reply with JSON only" lines stay the last thing read, and "view it now" doesn't sit right
                    // before "no tool-call".
                    if let closing = promptText.range(of: "\n\nReply with the JSON object only") {
                        promptText.insert(contentsOf: "\n" + line, at: closing.lowerBound)
                    } else {
                        promptText += "\n" + line
                    }
                    // FastLane's closing line bans tool-call tags in the reply text (fake <invoke> tags); say so,
                    // so it doesn't read as a ban on the view_file call just asked for.
                    promptText = promptText.replacingOccurrences(of: "— no tool-call or XML tags.",
                        with: "— no tool-call or XML tags in the reply text (view the screenshot file with view_file first).")
                } catch {
                    note("couldn't save the screenshot: \(error.localizedDescription)")
                    // The turn text says one is attached: don't send the model looking for a file that isn't there.
                    promptText = promptText.replacingOccurrences(of: "(Screenshot attached:",
                                                                 with: "(No screenshot this turn: it couldn't be saved. Ignore this note:")
                }
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

        let reply: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            lock.lock()
            if dead {
                let err = failureMessage().map { BrainError.failed(withLoginHint($0)) } ?? BrainError.died
                lock.unlock()
                continuation.resume(throwing: err)
                return
            }
            if pending != nil { lock.unlock(); continuation.resume(throwing: BrainError.busy); return }
            pending = continuation
            partialText = ""
            partialHandler = partial
            // Per-turn state starts over: a turn without usage records none (not the last turn's), and an earlier
            // turn's error isn't this one's.
            responseStep = nil
            lastUsage = (nil, nil)
            lastErrorMessage = nil
            turnHasScreenshot = shotThisTurn
            viewedScreenshot = false
            replySkippedScreenshot = false
            lock.unlock()
            // `dead` is set only once the exit is noticed: until then a write can hit a closed pipe (EPIPE). The
            // throwing write reports that instead of raising an Objective-C exception.
            do { try input.fileHandleForWriting.write(contentsOf: line) } catch { fail(BrainError.died) }
        }
        let usage = lock.withLock { lastUsage }
        UsageStore.record(provider: sessionProvider, model: sessionModel, inputTokens: usage.input, outputTokens: usage.output)
        return reply
    }

    /// A line in the agent log about this session (from the reader thread, so it's queued to the main actor). It goes
    /// through the run's logger when there is one, without counting as progress for the watchdog.
    private func note(_ text: String) {
        let logger = self.log, line = "  \(label): \(text)"
        Task { @MainActor in
            if let logger { logger(line) } else { Agent.writeLog(line) }
        }
    }

    /// What a failed turn or a dead session is blamed on: this turn's error, else the last stderr. Lock held.
    private func failureMessage() -> String? { lastErrorMessage ?? lastStderr }

    /// An auth failure, with how to log in added (unless it already says).
    private func withLoginHint(_ msg: String) -> String {
        guard msg.contains("OAuth") || msg.contains("Not logged in") || msg.contains("Failed to authenticate"),
              !msg.contains("auth login"), !msg.contains("log in") else { return msg }
        return isAgy ? "\(msg) — run 'agy' in your terminal once and log in." : "\(msg) — run 'claude auth login' in your terminal."
    }

    /// Session folders left behind when the app quit or crashed with sessions open (`close` removes a session's own).
    /// A folder is named after the process that made it and stays while that process runs: a session can sit idle
    /// for days (the warm one made at launch), and its folder's date doesn't move meanwhile, so age says nothing.
    /// Folders from before the names carried a pid go once they're a day old.
    private static func removeStaleSessionDirs() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let me = ProcessInfo.processInfo.processIdentifier
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix("clinqy-session-") {
            let url = tmp.appendingPathComponent(name)
            let rest = name.dropFirst("clinqy-session-".count)
            if let dash = rest.firstIndex(of: "-"), let pid = pid_t(rest[..<dash]), pid > 0,
               UUID(uuidString: String(rest[rest.index(after: dash)...])) != nil {
                // kill(pid, 0) sends nothing, it only asks: anything but "no such process" means the owner lives.
                if pid == me || kill(pid, 0) == 0 || errno != ESRCH { continue }
            } else {
                guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      Date().timeIntervalSince(modified) > 24 * 3600 else { continue }
            }
            try? fm.removeItem(at: url)
        }
    }

    func close() {
        if let api { api.close(); return }
        output.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        if let sessionDir { try? FileManager.default.removeItem(at: sessionDir) }
        fail(BrainError.died)
        process.terminationHandler = nil
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
            // Agy: streaming text, the tools it calls on its own, and errors between turns.
            if event["event"] as? String == "step_update", let step = event["step_update"] as? [String: Any] {
                switch step["step_type"] as? String {
                case "agent_response":
                    if let piece = step["text_delta"] as? String, pending != nil {
                        // A new reply step starts the reply over: text from an earlier step (a draft written before
                        // viewing the screenshot) must neither run early nor join the reply.
                        if let idx = (step["step_index"] as? NSNumber)?.intValue, idx != responseStep {
                            partialText = ""
                            responseStep = idx
                        }
                        partialText += piece
                        // Nothing reaches early start before the model has seen this turn's screenshot: x/y written
                        // without it are guesses. The text keeps growing, so the first piece after the view sends it all.
                        if !turnHasScreenshot || viewedScreenshot { grown = partialText }
                    }
                case "tool":
                    guard let name = step["tool_name"] as? String else { continue }
                    let state = step["state"] as? String
                    // Text written before a tool call didn't have its result: it never feeds early start or the reply.
                    if pending != nil { partialText = ""; grown = nil }
                    // Each tool step comes twice (ACTIVE, then DONE or ERROR); only the end is booked.
                    guard state != "ACTIVE" else { continue }
                    let info = step["tool_info"] as? [String: Any]
                    let params = info?["parameters"] as? [String: Any] ?? [:]
                    let target = (params["Path"] ?? params["AbsolutePath"] ?? params["path"]).map { "\($0)" }
                    let secs = (step["duration_seconds"] as? NSNumber).map { String(format: " (%.1f s)", $0.doubleValue) } ?? ""
                    // Paths come back with symlinks resolved (/private/var/… for /var/…): compare them resolved.
                    let resolved = target.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                    let folder = sessionDir?.resolvingSymlinksInPath().path
                    if Self.screenshotTools.contains(name), let resolved, let folder, resolved.hasPrefix(folder) {
                        let file = URL(fileURLWithPath: resolved).lastPathComponent
                        // A view that ended in ERROR showed the model nothing.
                        if state == "DONE" {
                            viewedScreenshot = true
                            note("viewed \(file)\(secs)")
                        } else {
                            note("couldn't view \(file)\(secs) (\(state ?? "no state"))")
                        }
                    } else {
                        strayTools.append(name)
                        note("called its own tool \(name)\(target.map { " …\($0.suffix(60))" } ?? "")\(secs) — not allowed here, it'll be told")
                    }
                case "error_message":
                    let message = (step["text"] ?? step["message"] ?? step["error"]).map { "\($0)" } ?? "error step"
                    lastErrorMessage = message
                    note("error: \(message.prefix(300))")
                default:
                    break
                }
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
                var text = res["response"] as? String ?? ""
                // The result can come back empty while the text arrived as deltas: use what streamed.
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = partialText
                }
                // agy's usage is the session's running total (num_turns 1/2/3, input 39949 → 41725 → 44193): this
                // turn's share is what it grew by. A total that went down, or a turn count that didn't go up, means
                // the counters started over (or this agy reports per turn): take the numbers as they are.
                if let usage = res["usage"] as? [String: Any] {
                    let cumIn = (usage["input_tokens"] as? NSNumber)?.intValue
                    let cumOut = (usage["output_tokens"] as? NSNumber)?.intValue
                    let turns = (res["num_turns"] as? NSNumber)?.intValue
                    let restarted = turns.map { $0 <= usageTotals.turns } ?? false
                    if restarted { note("usage counters started over (num_turns \(turns ?? 0) after \(usageTotals.turns))") }
                    func delta(_ cum: Int?, _ prev: Int) -> Int? { cum.map { !restarted && $0 >= prev ? $0 - prev : $0 } }
                    lastUsage = (delta(cumIn, usageTotals.input), delta(cumOut, usageTotals.output))
                    usageTotals = (cumIn ?? usageTotals.input, cumOut ?? usageTotals.output, turns ?? usageTotals.turns)
                }
                if pending != nil {
                    replySkippedScreenshot = turnHasScreenshot && !viewedScreenshot
                    if replySkippedScreenshot { note("replied without viewing the screenshot") }
                }
                // An empty `error` is no error message: fall back as if it were missing.
                let err = (res["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if status == "ERROR" || err != nil {
                    let msg = err ?? (text.isEmpty ? "Agy process error" : text)
                    lastErrorMessage = msg
                    results.append(.failure(BrainError.failed(msg)))
                } else {
                    // An error step earlier in the turn didn't stop it: it isn't what a later failure should show.
                    if let old = lastErrorMessage, pending != nil { note("turn succeeded after error: \(old.prefix(200))") }
                    lastErrorMessage = nil
                    results.append(.success(text))
                }
                continue
            }
            // Claude final result
            if event["type"] as? String == "result" {
                let text = event["result"] as? String ?? ""
                if event["is_error"] as? Bool == true {
                    results.append(.failure(BrainError.failed(text)))
                } else {
                    lastErrorMessage = nil
                    results.append(.success(text))
                }
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
        let errMsg = failureMessage()
        lock.unlock()
        let errToThrow = errMsg.map { BrainError.failed(withLoginHint($0)) } ?? error
        p?.resume(throwing: errToThrow)
    }
}

typealias ClaudeSession = AgySession

/// Keeps one session started ahead of time so a request never waits for process startup.
@MainActor
enum Brain {
    static func defaultModel(for provider: Provider = Provider.current) -> String {
        switch provider {
        case .agyCLI:
            return Config.value("AGY_MODEL") ?? tierAlias("CLAUDE_MODEL") ?? "sonnet"
        case .codexCLI:
            return Config.value("CODEX_MODEL") ?? ""
        case .claudeCLI:
            return Config.value("CLAUDE_MODEL") ?? tierAlias("AGY_MODEL") ?? "sonnet"
        default:
            return Config.value("CLAUDE_MODEL") ?? tierAlias("AGY_MODEL") ?? "sonnet"
        }
    }

    /// The other provider's model key, only when it names a tier (haiku/sonnet/opus): a concrete id belongs to one
    /// side (gemini-3.8-flash means nothing to claude, and an unknown id makes agy refuse to start).
    static func tierAlias(_ key: String) -> String? {
        Config.value(key).flatMap { ["haiku", "sonnet", "opus"].contains($0.lowercased()) ? $0 : nil }
    }
    static var model: String { defaultModel(for: Provider.current) }
    private static var warm: AgySession?

    static func reloadModel() {
        warm?.close()
        warm = nil
        prewarm()
    }

    static func prewarm() {
        if warm?.isAlive == true { return }
        warm = try? AgySession(system: AgentPrompt.system, model: model)
    }

    /// Hands out the warm session (or a fresh one) and starts warming the next.
    static func session(model override: String? = nil, provider overrideProvider: Provider? = nil) throws -> AgySession {
        let currentProvider = overrideProvider ?? Provider.current
        let defaultM = defaultModel(for: currentProvider)
        let effectiveModel = override ?? defaultM
        // Another provider or model than the default: a session of its own, and the warm one stays for the next run.
        if currentProvider != Provider.current || (override != nil && override != defaultM) {
            return try AgySession(system: AgentPrompt.system, model: effectiveModel, provider: currentProvider)
        }
        let s: AgySession
        // The model check is only a guard: Config is read once per process, so for agy it can't change under a session.
        if let w = warm, w.isAlive, w.sessionProvider == currentProvider, w.sessionModel == currentProvider.model(effectiveModel) {
            s = w
        } else {
            warm?.close()
            s = try AgySession(system: AgentPrompt.system, model: effectiveModel, provider: currentProvider)
        }
        warm = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { prewarm() }
        return s
    }

    /// Pulls the JSON object out of a reply, tolerating code fences or stray prose around it.
    static func json(from reply: String) -> [String: Any]? {
        // A bare action ({"do":"ask",…}) instead of the reply envelope: run it as the turn's only action.
        func envelope(_ obj: [String: Any]) -> [String: Any] {
            obj["do"] != nil && obj["actions"] == nil ? ["say": "", "actions": [obj], "done": false] : obj
        }
        if let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
           let obj = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] {
            return envelope(obj)
        }
        // Two objects (a reply, then another go at it), or braces in the prose around one: the first whole object
        // that reads as a reply, the one early start already took its first step from.
        var i = reply.startIndex
        while let open = reply[i...].firstIndex(of: "{") {
            guard let end = objectEnd(in: reply, from: open) else { i = reply.index(after: open); continue }
            if let obj = try? JSONSerialization.jsonObject(with: Data(reply[open...end].utf8)) as? [String: Any],
               obj["say"] != nil || obj["actions"] != nil || obj["do"] != nil {
                return envelope(obj)
            }
            i = reply.index(after: end)
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
        guard i < text.endIndex, text[i] == "{", let end = objectEnd(in: text, from: i),
              let action = try? JSONSerialization.jsonObject(with: Data(text[i...end].utf8)) as? [String: Any],
              action["do"] is String else { return nil }
        return action
    }

    /// Where the {…} object opening at `start` closes, skipping braces inside strings; nil if it doesn't (yet).
    private static func objectEnd(in text: String, from start: String.Index) -> String.Index? {
        var i = start
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
                if depth == 0 { return i }
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

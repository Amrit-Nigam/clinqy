import Foundation

/// Where a run came from. TaskStore only knows Mac vs Telegram; schedules and MCP/CLI runs are told apart here so
/// the phone can say what started each run.
enum RunSource: String, Codable, Equatable {
    case mac, scheduled, mcp, telegram
    var label: String {
        switch self {
        case .mac: return "Mac"
        case .scheduled: return "Scheduled"
        case .mcp: return "MCP/CLI"
        case .telegram: return "Telegram"
        }
    }
}

/// Remote control of a run. Pausing keeps all state: the run waits before its next action. Taking over pauses it and
/// gives the target to the user; handing back resumes it with a note to look again before acting.
enum RunControl: String, Codable, Equatable {
    case running, paused, takenOver
    var isPaused: Bool { self != .running }
    var label: String {
        switch self {
        case .running: return "Running"
        case .paused: return "Paused"
        case .takenOver: return "Taken over by you"
        }
    }

    enum Command: String, CaseIterable { case pause, resume, takeOver = "takeover", handBack = "handback" }

    struct Transition: Equatable {
        var state: RunControl
        /// The target should be released to the user (shown on the Mac).
        var reveal = false
        /// The run must observe again before acting: the user may have changed the screen.
        var reobserve = false
    }

    /// nil = the command doesn't apply in this state (e.g. resuming a running task).
    func apply(_ command: Command) -> Transition? {
        switch (self, command) {
        case (.running, .pause): return .init(state: .paused)
        case (.running, .takeOver), (.paused, .takeOver): return .init(state: .takenOver, reveal: true)
        case (.paused, .resume), (.paused, .handBack): return .init(state: .running)
        case (.takenOver, .handBack), (.takenOver, .resume): return .init(state: .running, reobserve: true)
        default: return nil
        }
    }
}

/// What happens when nobody answers a question in time. The default never approves paying, sending, deleting,
/// posting or submitting: it picks a declining option if one exists, otherwise a free-text "skip" instruction.
enum QuestionPolicy {
    static let defaultTimeout: TimeInterval = 600

    enum DefaultAnswer: Equatable {
        case option(String)
        case text(String)
        /// No answer at all (private questions): the caller treats it like a declined question.
        case none
        var reply: String? {
            switch self {
            case .option(let value), .text(let value): return value
            case .none: return nil
            }
        }
    }

    /// Minutes from config; "0", "off" or "never" disable the timeout. Unparseable values keep the default.
    static func timeout(config value: String?) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return defaultTimeout }
        if ["0", "off", "never", "none", "false"].contains(raw) { return nil }
        guard let minutes = Double(raw), minutes > 0 else { return defaultTimeout }
        return min(minutes, 24 * 60) * 60
    }

    /// Options that would carry out something irreversible or assert an outcome are never chosen automatically
    /// ("No, it did not happen" reports a fact the user never confirmed, so it is excluded too).
    static func isRisky(_ option: String) -> Bool {
        option.range(of: #"(?i)\b(yes|y|ok|okay|sure|go|go ahead|do it|confirm|approve|accept|allow|submit|send|pay|buy|purchase|order|book|transfer|delete|remove|erase|post|publish|share|continue|proceed|handled|happen(ed)?|did|done|true|foreground)\b"#, options: .regularExpression) != nil
    }

    /// Declining options, safest first: skip, not now, no, keep as is, cancel/stop.
    private static let declining = [#"(?i)^\s*skip\b"#, #"(?i)^\s*(not now|later|don'?t|do not)\b"#, #"(?i)^\s*no\b"#,
                                    #"(?i)^\s*keep\b"#, #"(?i)^\s*(cancel|stop)\b"#]

    static func defaultAnswer(options: [String], sensitive: Bool, timeout: TimeInterval) -> DefaultAnswer {
        if sensitive { return .none }
        for pattern in declining {
            if let option = options.first(where: { $0.range(of: pattern, options: .regularExpression) != nil && !Self.isRisky($0) }) {
                return .option(option)
            }
        }
        return .text(skipText(timeout: timeout))
    }

    /// Free-text default. Deliberately starts with "[" (never "yes"/"no") and contains a negation, so no yes/no parser
    /// can read it as approval or as "it did not happen".
    static func skipText(timeout: TimeInterval) -> String {
        "[No reply after \(minutes(timeout))] Skip this step: don't do anything irreversible for it. Carry on with work that doesn't need the answer, or stop and report what is still needed."
    }

    /// True for an answer Clinqy supplied (timeout default or a remote Skip tap): it must never be remembered as the
    /// user's own answer.
    static func isTimeoutDefault(_ reply: String) -> Bool { reply.hasPrefix("[No reply after ") || reply.hasPrefix(skippedPrefix) }

    static let skippedPrefix = "[Skipped by the user] "
    /// The answer for a Skip tap: the safest declining option when one exists, otherwise a skip instruction that
    /// approves nothing (same safety line as the timeout default).
    static func skipAnswer(options: [String]) -> String {
        if case .option(let option) = defaultAnswer(options: options, sensitive: false, timeout: defaultTimeout) { return option }
        return skippedPrefix + "Skip this step: don't do anything irreversible for it. Carry on with work that doesn't need the answer, or stop and report what is still needed."
    }

    static func minutes(_ timeout: TimeInterval) -> String {
        let value = max(1, Int((timeout / 60).rounded()))
        return value == 1 ? "1 min" : "\(value) min"
    }

    /// One line for the question card: "No answer in 10 min → I'll skip this step".
    static func note(_ answer: DefaultAnswer, timeout: TimeInterval?) -> String? {
        guard let timeout else { return nil }
        let head = "No answer in \(minutes(timeout)) → "
        switch answer {
        case .option(let option): return head + "I'll choose “\(option)”."
        case .text: return head + "I'll skip this step."
        case .none: return head + "I'll skip this step without the private input."
        }
    }
}

/// The text of a question as it appears on the phone or in a notification.
enum RemoteQuestionCard {
    static func render(shortID: String, text: String, sensitive: Bool, note: String?, paused: Bool = false) -> String {
        var body = "[\(shortID)] Input needed\n\n"
        body += sensitive ? "Answer this private question on your Mac. Don't send passwords or codes here."
            : text + "\n\nReply to this message or tap an option."
        if let note, !paused { body += "\n\n⏱ " + note }
        if paused { body += "\n\n⏸ Paused: no default will be chosen while the task is paused." }
        return body
    }
}

/// One registry for every run: where it came from, whether it is paused, and the question it is waiting on with its
/// timeout. Delivery (macOS notification, Telegram) is wired by the app; this type stays free of UI so it can be tested.
@MainActor
final class RunSupervisor {
    static let shared = RunSupervisor()

    struct Question: Equatable {
        var text: String
        var options: [String]
        var sensitive: Bool
        var fallback: QuestionPolicy.DefaultAnswer
        var timeout: TimeInterval?
        var note: String? { QuestionPolicy.note(fallback, timeout: timeout) }
    }

    struct Entry: Equatable {
        let id: UUID
        var source: RunSource
        var title: String
        var background: Bool
        var parent: UUID?
        var control: RunControl = .running
        var reobserve = false
        var question: Question?
        var startedAt = Date()
    }

    /// Called after any registry change (registration, pause state, question, finish) for that run.
    var onChange: (UUID) -> Void = { _ in }
    /// Releases a taken-over run's target to the user on the Mac (shows its tab or window). Wired by the app.
    var onReveal: (UUID) -> Void = { _ in }
    /// nil = questions never time out (QUESTION_TIMEOUT_MINUTES=0).
    var questionTimeout: TimeInterval? = QuestionPolicy.defaultTimeout

    private(set) var entries: [UUID: Entry] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var timeoutHandlers: [UUID: (String?) -> Void] = [:]
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "runSupervisor.paused") {
        self.defaults = defaults; self.key = key
    }

    var active: [Entry] { entries.values.sorted { $0.startedAt < $1.startedAt } }
    func entry(_ id: UUID?) -> Entry? { id.flatMap { entries[$0] } }
    func state(_ id: UUID?) -> RunControl { entry(id)?.control ?? .running }
    func isPaused(_ id: UUID?) -> Bool { state(id).isPaused }

    // MARK: Registration

    /// Idempotent. A run that was paused when the app quit comes back paused (resuming the same task record).
    func register(run id: UUID?, source: RunSource, title: String, background: Bool, parent: UUID? = nil) {
        guard let id else { return }
        if var existing = entries[id] {
            existing.source = source; existing.title = title; existing.background = background
            existing.parent = parent ?? existing.parent
            entries[id] = existing
        } else {
            var entry = Entry(id: id, source: source, title: title, background: background, parent: parent)
            if let saved = persisted[id.uuidString].flatMap(RunControl.init(rawValue:)), saved.isPaused { entry.control = saved }
            entries[id] = entry
        }
        onChange(id)
    }

    /// The run ended (any outcome): its pause state and any open question go with it.
    func finished(run id: UUID?) {
        guard let id else { return }
        cancelTimer(id)
        timeoutHandlers[id] = nil
        let known = entries.removeValue(forKey: id) != nil
        var saved = persisted
        if saved.removeValue(forKey: id.uuidString) != nil { persisted = saved }
        if known { onChange(id) }
    }

    // MARK: Pause, resume, take over, hand back

    /// Applies a remote/local control command. Returns the transition, or nil when it doesn't apply.
    @discardableResult
    func apply(_ command: RunControl.Command, to id: UUID?) -> RunControl.Transition? {
        guard let id, var entry = entries[id], let transition = entry.control.apply(command) else { return nil }
        entry.control = transition.state
        if transition.reobserve { entry.reobserve = true }
        entries[id] = entry
        var saved = persisted
        if transition.state.isPaused { saved[id.uuidString] = transition.state.rawValue } else { saved.removeValue(forKey: id.uuidString) }
        persisted = saved
        // A paused run's question keeps waiting without a default; resuming restarts its full timeout.
        if transition.state.isPaused { cancelTimer(id) } else if entry.question != nil { armTimer(id) }
        onChange(id)
        return transition
    }

    /// Agent hook: call before each action. Returns once the run is not paused (or is cancelled). A non-nil result is
    /// the note to give the model instead of running the stale action (the user had the target in the meantime).
    func waitIfPaused(_ id: UUID?, poll: Duration = .milliseconds(250)) async -> String? {
        guard let id else { return nil }
        while entries[id]?.control.isPaused == true, !Task.isCancelled {
            try? await Task.sleep(for: poll)
        }
        guard var entry = entries[id], entry.reobserve else { return nil }
        entry.reobserve = false
        entries[id] = entry
        return Self.handBackNote
    }

    static let handBackNote = "NOT RUN: the user took over this task and has handed it back. The screen may have changed: observe again before acting. Nothing planned before the takeover was done."

    // MARK: Questions

    /// Records an open question and arms its timeout. `onTimeout` receives the safe default (nil for private
    /// questions); the caller must check its question is still the open one before answering with it.
    @discardableResult
    func question(run id: UUID?, text: String, options: [String], sensitive: Bool,
                  onTimeout: @escaping (String?) -> Void) -> Question {
        let timeout = questionTimeout
        let fallback = QuestionPolicy.defaultAnswer(options: options, sensitive: sensitive, timeout: timeout ?? QuestionPolicy.defaultTimeout)
        let question = Question(text: text, options: options, sensitive: sensitive, fallback: fallback, timeout: timeout)
        guard let id, var entry = entries[id] else { return question }
        if entry.question == question, timers[id] != nil { return question }
        entry.question = question
        entries[id] = entry
        timeoutHandlers[id] = onTimeout
        if entry.control.isPaused { cancelTimer(id) } else { armTimer(id) }
        onChange(id)
        return question
    }

    func pendingQuestion(_ id: UUID?) -> Question? { entry(id)?.question }

    /// The question was answered (from anywhere) or withdrawn.
    func answered(run id: UUID?) {
        guard let id, var entry = entries[id], entry.question != nil else { return }
        cancelTimer(id)
        timeoutHandlers[id] = nil
        entry.question = nil
        entries[id] = entry
        onChange(id)
    }

    private func armTimer(_ id: UUID) {
        cancelTimer(id)
        guard let timeout = entries[id]?.question?.timeout else { return }
        timers[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(timeout * 1000)))
            guard !Task.isCancelled, let self, var entry = self.entries[id], let question = entry.question, !entry.control.isPaused else { return }
            entry.question = nil
            self.entries[id] = entry
            self.timers[id] = nil
            let handler = self.timeoutHandlers.removeValue(forKey: id)
            handler?(question.fallback.reply)
            self.onChange(id)
        }
    }

    private func cancelTimer(_ id: UUID) { timers.removeValue(forKey: id)?.cancel() }

    private var persisted: [String: String] {
        get { defaults.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { newValue.isEmpty ? defaults.removeObject(forKey: key) : defaults.set(newValue, forKey: key) }
    }
}

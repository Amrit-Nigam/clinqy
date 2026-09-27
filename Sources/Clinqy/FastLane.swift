import Foundation

/// Hands routine turns (the rest of a form the lead model already planned, ticking listed options, scrolling on)
/// to a faster model, so long runs don't pay the main model's latency for every mechanical step.
/// The lead opts in per turn with a "routine" plan; the helper gets that plan, recent steps and the screen,
/// may only use harmless actions, and hands back on anything risky, unclear, failed, repeated or final.
/// Everything the helper did is replayed to the lead at its next turn, so the lead's context stays whole.
/// FAST_MODEL=haiku (default) picks the helper model; FAST_MODEL=off turns it off.
@MainActor
final class FastLane {
    /// The helper model, or nil when turned off.
    static var model: String? {
        let raw = (Config.value("FAST_MODEL") ?? "haiku").trimmingCharacters(in: .whitespaces)
        return ["", "off", "none", "no", "0", "false"].contains(raw.lowercased()) ? nil : raw
    }

    /// Most helper turns in a row before the lead checks in again.
    static let maxStint = 6

    private let model: String?
    private let intro: String
    private var session: ClaudeSession?
    /// The lead's routine plan; set = the next turns go to the helper.
    private var plan: String?
    private var stintTurns = 0
    private var stintFailures = 0
    private var briefed = false
    /// The previous turn ("say: actions"), waiting for its results.
    private var lastTurn: String?
    private var lastSignature = ""
    /// Recent steps from both models, with results (the helper's briefing).
    private var recent: [String] = []
    /// Helper steps the lead hasn't heard about yet.
    private var unreported: [String] = []
    private var handback: String?
    /// Element lines of the last full screen, by id ("w3" → "w3 button: Submit").
    private var labels: [String: String] = [:]
    /// Who answered the last turn, for the log: "fast · ", "lead ← fast (why) · ", or "".
    private(set) var tag = ""

    init(intro: String, leadModel: String) {
        self.intro = intro
        let fast = Self.model
        model = fast == leadModel ? nil : fast
    }

    /// Appended to the lead's first message: how to hand routine steps off (empty when off).
    var leadNote: String {
        guard model != nil else { return "" }
        return """


        Routine steps: when the next steps are purely mechanical and already decided (filling the remaining fields of \
        a form with values you know, ticking options you've chosen, scrolling on through a form), you may add \
        "routine":"<those steps, with the exact values to use>" to your reply. A faster helper then carries them out and \
        you get its steps and results before anything else is decided. Never mark as routine anything that needs a \
        choice or a detail you don't have yet, or that submits, sends, pays, books, deletes, posts, uploads, asks the \
        user or finishes the task.
        """
    }

    /// Gets this turn's reply: from the helper when the lead planned routine steps and nothing speaks against it,
    /// otherwise (or when the helper hands back) from the lead, told first what the helper did.
    func reply(to turnText: String, message: String, image: String?, failures: Int, lead: ClaudeSession) async throws -> String {
        absorb(message: message, turnText: turnText, failures: failures)
        tag = ""
        if let why = blocker(turnText: turnText, failures: failures) {
            if plan != nil { end(why) }
        } else if let reply = await helperReply(turnText, image: image) {
            tag = "fast · "
            return reply
        }
        return try await leadReply(turnText, image: image, lead: lead)
    }

    func close() {
        session?.close()
        session = nil
    }

    // MARK: - Routing

    /// Why this turn must go to the lead (nil = the helper may take it).
    private func blocker(turnText: String, failures: Int) -> String? {
        guard model != nil, plan != nil else { return "no routine plan" }
        if turnText.hasPrefix("The user added") { return "the user added something" }
        if stintTurns == 0, failures > 0 { return "the lead's last step failed" }
        if stintFailures >= 2 { return "steps failed twice" }
        if stintTurns >= Self.maxStint { return "\(Self.maxStint) routine steps done, checking in" }
        return nil
    }

    private func helperReply(_ turnText: String, image: String?) async -> String? {
        guard let model, let plan else { return nil }
        var text = ""
        if !briefed {
            text += "The lead's context for this task:\n\(intro)\n\n"
            briefed = true
        }
        if stintTurns == 0 {
            text += "The lead's routine steps for you: \(plan)\n"
            if !recent.isEmpty { text += "Recent steps:\n" + recent.suffix(4).map { "- \($0)" }.joined(separator: "\n") + "\n" }
            text += "\n"
        }
        text += turnText
        let reply: String
        do {
            if session?.isAlive != true { session = try ClaudeSession(system: Self.system, model: model) }
            guard let s = session else { return nil }
            reply = try await withTaskCancellationHandler { try await s.send(text, image: image) } onCancel: { s.close() }
        } catch {
            end("the helper failed: \(error.localizedDescription)")
            return nil
        }
        guard var json = Brain.json(from: reply) else { end("the helper's reply wasn't JSON"); return nil }
        let say = json["say"] as? String ?? ""
        let actions = json["actions"] as? [[String: Any]] ?? []
        if json["handback"] as? Bool == true { end("the helper handed back: \(say.prefix(80))"); return nil }
        if let bad = actions.first(where: { !Self.isSafe($0, labels: labels) }) {
            end("the helper wanted \(Self.brief(bad))")
            return nil
        }
        let signature = actions.map { "\($0)" }.joined()
        if signature == lastSignature { end("the helper repeated itself"); return nil }
        let finishing = json["done"] as? Bool == true
        if actions.isEmpty { end(finishing ? "the helper thinks it's finished" : "the helper had nothing to do"); return nil }

        lastSignature = signature
        stintTurns += 1
        lastTurn = "[helper] \(say): " + actions.map(Self.brief).joined(separator: ", ")
        // Only the lead finishes: run the helper's last actions, then let the lead check.
        if finishing {
            json["done"] = false
            end("the helper finished its steps")
            guard let data = try? JSONSerialization.data(withJSONObject: json), let fixed = String(data: data, encoding: .utf8) else { return nil }
            return fixed
        }
        return reply
    }

    private func leadReply(_ turnText: String, image: String?, lead: ClaudeSession) async throws -> String {
        var text = turnText
        if !unreported.isEmpty || handback != nil {
            text = "While you waited, a faster helper did routine steps for you:\n"
                + (unreported.isEmpty ? "(none)" : unreported.map { "- \($0)" }.joined(separator: "\n"))
                + (handback.map { "\nIt handed back because \($0)." } ?? "")
                + "\nContinue from here (latest results and screen below).\n\n" + turnText
            if let handback { tag = "lead ← fast (\(handback)) · " }
            unreported = []
            handback = nil
        }
        let reply = try await lead.send(text, image: image)
        let json = Brain.json(from: reply)
        let actions = json?["actions"] as? [[String: Any]] ?? []
        lastSignature = actions.map { "\($0)" }.joined()
        lastTurn = json.map { "\($0["say"] as? String ?? ""): " + actions.map(Self.brief).joined(separator: ", ") }
        // A new routine plan starts a new stint; a turn without one keeps the lead in charge.
        if model != nil, json?["done"] as? Bool != true, let routine = json?["routine"] as? String,
           !routine.trimmingCharacters(in: .whitespaces).isEmpty {
            plan = routine
            stintTurns = 0
            stintFailures = 0
            // Start the helper's process now, while the lead's actions run.
            if session?.isAlive != true, let model { session = try? ClaudeSession(system: Self.system, model: model) }
        } else {
            plan = nil
        }
        return reply
    }

    /// Books the previous turn's results and reads the element labels off a full screen.
    private func absorb(message: String, turnText: String, failures: Int) {
        if let last = lastTurn {
            let results = message.range(of: "Results:\n").map { String(message[$0.upperBound...]) } ?? ""
            let line = last + (results.isEmpty ? "" : " → " + results.replacingOccurrences(of: "\n", with: " ").prefix(300))
            recent = Array((recent + [line]).suffix(6))
            if tag.hasPrefix("fast") {
                unreported.append(line)
                if failures > 0 { stintFailures += 1 }
            }
            lastTurn = nil
        }
        if turnText.contains("\nFrontmost app: ") || turnText.hasPrefix("Frontmost app: ") { labels = Self.labels(in: turnText) }
    }

    private func end(_ why: String) {
        plan = nil
        stintTurns = 0
        handback = why
    }

    // MARK: - Rules

    /// Words on a control that commit, leave or open something the lead should decide on.
    nonisolated private static let riskyLabel = #"(?i)\b(submit|send|pay|payment|buy|purchase|order|checkout|check out|book|reserve|confirm|delete|remove|trash|erase|discard|post|publish|tweet|share|apply|sign ?up|register|sign ?in|log ?in|log ?out|sign ?out|transfer|withdraw|donate|reply|forward|unsubscribe|cancel|deactivate|save|upload|attach|browse|add file|allow|approve|accept|agree|install|download|close|quit|finish|done)\b"#
    nonisolated private static let safeKinds: Set<String> = ["click", "type", "choose", "key", "scroll", "wait", "look", "read", "recall"]
    nonisolated private static let safeKeys: Set<String> = ["tab", "shift+tab", "up", "down", "left", "right", "esc", "escape",
                                                "pageup", "pagedown", "page_up", "page_down", "home", "end"]

    /// Whether the helper may run this action on its own.
    nonisolated static func isSafe(_ action: [String: Any], labels: [String: String]) -> Bool {
        let kind = (action["do"] as? String ?? "").lowercased()
        guard safeKinds.contains(kind) else { return false }
        let id = action["id"] as? String
        // Know what it's touching, and that it isn't a commit button.
        func harmless(_ id: String?) -> Bool {
            guard let id, let line = labels[id] else { return false }
            return line.range(of: riskyLabel, options: .regularExpression) == nil
        }
        switch kind {
        case "click", "choose": return harmless(id)
        case "type":
            if action["submit"] as? Bool == true || (action["submit"] as? String)?.lowercased() == "true" { return false }
            return id.map { labels[$0] != nil } ?? true
        case "key": return safeKeys.contains((action["keys"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: ""))
        default: return true
        }
    }

    /// "w3" → "w3 button: Submit [...]" for every listed element.
    nonisolated static func labels(in screen: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in screen.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard let first = s.first, first == "e" || first == "w", let space = s.firstIndex(of: " "),
                  s[s.index(after: s.startIndex)..<space].allSatisfy(\.isNumber), space > s.index(after: s.startIndex) else { continue }
            map[String(s[..<space])] = s
        }
        return map
    }

    nonisolated static func brief(_ action: [String: Any]) -> String {
        let kind = action["do"] as? String ?? "?"
        let detail = [action["id"], action["text"] ?? action["option"], action["keys"], action["dir"]]
            .compactMap { $0.map { "\($0)".prefix(40) } }.joined(separator: " ")
        return detail.isEmpty ? kind : "\(kind) \(detail)"
    }

    static let system = AgentPrompt.system + """


    You are the fast helper here, not the lead. A lead model planned some routine steps and gave them to you; \
    carry out only those, one screen at a time, using the elements you are shown. Use only click (by id), \
    type (never with submit), choose, key (tab, arrows, esc), scroll, wait, look, read and recall. \
    Put every step you're sure of into one turn. Never set done:true and never ask the user. \
    As soon as the routine steps are done, or something is unclear or unexpected, a step failed, a value you need \
    wasn't given, or the next step would submit, send, pay, book, delete, post, upload, save, sign in or finish, \
    reply {"say":"<why, a few words>","actions":[],"handback":true} and the lead takes over.
    """
}

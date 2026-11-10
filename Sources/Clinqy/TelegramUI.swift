import Foundation

// Pure presentation and policy for the Telegram copilot: HTML escaping, the live run card, button layouts, callback
// data, message splitting, edit/photo pacing, Bot API retry rules and reply routing. No networking and no app types,
// so `tests/telegram-ui.sh` covers all of it with plain swiftc.

// MARK: - HTML

enum TelegramHTML {
    /// Bot API HTML mode: `<`, `>` and `&` must be escaped outside tags; `"` too inside attribute values.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }
    static func bold(_ text: String) -> String { "<b>" + escape(text) + "</b>" }
    static func italic(_ text: String) -> String { "<i>" + escape(text) + "</i>" }
    static func code(_ text: String) -> String { "<code>" + escape(text) + "</code>" }
    /// A link only for http(s) URLs; anything else is shown as plain text so no other scheme becomes tappable.
    static func link(_ url: String, _ text: String? = nil) -> String {
        guard let safe = TelegramLinks.web(url) else { return escape(text ?? url) }
        return "<a href=\"" + escape(safe) + "\">" + escape(text ?? TelegramText.clip(safe, 60)) + "</a>"
    }

    /// Splits plain text into escaped chunks, each at most `limit` UTF-16 units once escaped. Prefers newline
    /// boundaries, never splits a character (emoji, flags) and never cuts an entity in half.
    static func chunks(_ plain: String, limit: Int = 4000) -> [String] {
        var chunks: [String] = []
        var current = "", size = 0
        var lineStart = "" // escaped text of the current chunk up to the last newline
        for character in plain {
            let piece = escape(String(character))
            let length = piece.utf16.count
            if size + length > limit, !current.isEmpty {
                // Break at the last newline when it keeps at least half the chunk; otherwise hard-break here.
                if !lineStart.isEmpty, lineStart.utf16.count >= limit / 2 {
                    let rest = String(current.dropFirst(lineStart.count))
                    chunks.append(lineStart)
                    current = rest; size = rest.utf16.count
                } else {
                    chunks.append(current); current = ""; size = 0
                }
                lineStart = ""
            }
            current += piece; size += length
            if character == "\n" { lineStart = current }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }.ifEmpty([""])
    }
}

private extension Array {
    func ifEmpty(_ fallback: [Element]) -> [Element] { isEmpty ? fallback : self }
}

enum TelegramText {
    /// At most `count` characters, with an ellipsis when shortened. Whitespace runs collapse to one space.
    static func clip(_ text: String, _ count: Int) -> String {
        let flat = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard flat.count > count else { return flat }
        return String(flat.prefix(max(1, count - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }
    /// The task in at most 60 characters: the instruction, not the pasted links or attachment boilerplate.
    static func title(_ request: String, limit: Int = 60) -> String {
        let body = request.components(separatedBy: "\n\nFiles attached by the user in Telegram").first ?? request
        let lines = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let instruction = lines.filter { !$0.hasPrefix("http://") && !$0.hasPrefix("https://") }.joined(separator: " ")
        let value = instruction.isEmpty ? (URL(string: lines.first ?? "")?.host ?? body) : instruction
        return clip(value, limit)
    }
    /// "<1m", "3m", "1h 05m". Minute granularity: elapsed time alone changes a card at most once a minute.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "<1m" }
        if total < 3600 { return "\(total / 60)m" }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }
}

enum TelegramLinks {
    /// http(s) URLs only, at most 2048 characters (Telegram rejects longer button URLs).
    static func web(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>()[]\"'.,;")))
        guard value.count <= 2048, let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        return value
    }
    /// Distinct web links in order of appearance.
    static func extract(_ texts: [String?]) -> [String] {
        var seen: [String] = []
        for text in texts.compactMap({ $0 }) {
            for match in text.matches(of: #/https?://[^\s<>"'\)\]]+/#) {
                if let link = web(String(match.output)), !seen.contains(link) { seen.append(link) }
            }
        }
        return seen
    }
}

// MARK: - Run card

/// What a run is doing, as the phone shows it.
enum CardPhase: String, Equatable, CaseIterable {
    case queued, working, waiting, waitingPrivate, paused, takenOver, done, doneUnconfirmed, failed, stopped

    var emoji: String {
        switch self {
        case .queued: return "🕓"
        case .working: return "⚙️"
        case .waiting, .waitingPrivate: return "🙋"
        case .paused: return "⏸"
        case .takenOver: return "🖐"
        case .done: return "✅"
        case .doneUnconfirmed: return "⚠️"
        case .failed: return "❌"
        case .stopped: return "⏹"
        }
    }
    var label: String {
        switch self {
        case .queued: return "Queued"
        case .working: return "Working"
        case .waiting: return "Waiting for you"
        case .waitingPrivate: return "Waiting for you on your Mac"
        case .paused: return "Paused"
        case .takenOver: return "You have control"
        case .done: return "Done"
        case .doneUnconfirmed: return "Done — one item I couldn't confirm"
        case .failed: return "Couldn't finish"
        case .stopped: return "Stopped"
        }
    }
    var finished: Bool { [.done, .doneUnconfirmed, .failed, .stopped].contains(self) }

    /// The phase from the facts the app has. Finished outcomes win; then a pause (the user's hold); then a question.
    static func from(ended: Bool, ok: Bool, stopped: Bool, unconfirmed: Bool, paused: Bool, takenOver: Bool,
                     question: Bool, sensitive: Bool, running: Bool) -> CardPhase {
        if ended { return stopped ? .stopped : !ok ? .failed : unconfirmed ? .doneUnconfirmed : .done }
        if takenOver { return .takenOver }
        if paused { return .paused }
        if question { return sensitive ? .waitingPrivate : .waiting }
        return running ? .working : .queued
    }
}

struct CardItem: Equatable {
    var title: String
    var complete: Bool
}

struct RunCardModel: Equatable {
    var shortID: String
    var title: String
    var phase: CardPhase
    /// "Mac", "Scheduled", "MCP/CLI"; nil for Telegram-started runs.
    var source: String? = nil
    var background = true
    var elapsed: TimeInterval = 0
    var step = 0
    /// The current action in plain words (the model's narration), or the question while waiting.
    var action: String? = nil
    var checklist: [CardItem] = []
    /// Pre-rendered plain lines for parallel parts ("Read page 2 — Working").
    var parts: [String] = []
    /// A short line under the parts ("2/3 tasks finished · 1 image delivered").
    var partsSummary: String? = nil
    /// The question's timeout/default line ("No answer in 10 min → I'll skip this step.").
    var note: String? = nil
    /// The final answer (finished runs).
    var outcome: String? = nil
    var link: String? = nil
    var options: [String] = []
    var questionKey: String? = nil
    var hasResult = false
    var canRunAgain = true
}

enum RunCard {
    static let captionLimit = 1024
    static let textLimit = 4096

    /// Card HTML within `limit` (caption 1024 once the card carries a photo, otherwise 4096), measured as Telegram does
    /// after parsing entities; escaping is accounted for by measuring the escaped text, which is never shorter.
    static func render(_ m: RunCardModel, limit: Int = textLimit) -> String {
        // Try the full card, then progressively shorter variants, so it always fits without breaking a tag.
        let variants: [(items: Int, action: Int, outcome: Int, parts: Int)] = [(6, 160, 600, 6), (4, 120, 300, 4), (3, 90, 180, 3), (0, 70, 110, 2), (0, 50, 60, 0)]
        for v in variants {
            let html = compose(m, maxItems: v.items, actionLength: v.action, outcomeLength: v.outcome, maxParts: v.parts)
            if html.utf16.count <= limit { return html }
        }
        return TelegramHTML.escape(TelegramText.clip("\(m.phase.emoji) \(m.phase.label) · \(m.title)", max(10, limit / 2)))
    }

    private static func compose(_ m: RunCardModel, maxItems: Int, actionLength: Int, outcomeLength: Int, maxParts: Int) -> String {
        var head = m.phase.emoji + " " + TelegramHTML.bold(m.phase.label)
        if !m.phase.finished || m.elapsed > 0 { head += " · " + TelegramText.elapsed(m.elapsed) }
        if m.step > 0 { head += " · step \(m.step)" }
        var lines = [head, TelegramHTML.bold(m.title)]
        switch m.phase {
        case .waiting:
            if let action = m.action, !action.isEmpty { lines.append("❓ " + TelegramHTML.escape(TelegramText.clip(action, actionLength))) }
            if let note = m.note { lines.append("⏱ " + TelegramHTML.escape(note)) }
        case .waitingPrivate:
            lines.append(TelegramHTML.escape("Private input needed — answer it on your Mac. Don't send passwords or codes here."))
        case .paused:
            lines.append(TelegramHTML.escape("Paused before its next action. Nothing is lost; tap Resume to continue."))
        case .takenOver:
            lines.append(TelegramHTML.escape("It's yours on the Mac. Tap Hand back when you're done; I'll look again before acting."))
        case .queued:
            lines.append(TelegramHTML.escape(m.action.map { TelegramText.clip($0, actionLength) } ?? "Waiting for a free task slot"))
        case .working:
            lines.append(TelegramHTML.escape(TelegramText.clip(m.action?.isEmpty == false ? m.action! : "Getting started", actionLength)))
        case .done, .doneUnconfirmed, .failed, .stopped:
            if let outcome = m.outcome, !outcome.isEmpty { lines.append(TelegramHTML.escape(TelegramText.clip(outcome, outcomeLength))) }
            if let link = m.link.flatMap(TelegramLinks.web) { lines.append("🔗 " + TelegramHTML.link(link)) }
        }
        let items = m.checklist
        if maxItems > 0, !items.isEmpty {
            let done = items.filter(\.complete).count
            // The finished items closest to the current one, then the open ones: what was just done and what's next.
            let firstOpen = items.firstIndex { !$0.complete } ?? items.count
            let start = max(0, min(firstOpen - 2, items.count - maxItems))
            let shown = items[start..<min(items.count, start + maxItems)]
            var block = ["\(done)/\(items.count) done"]
            for (offset, item) in shown.enumerated() {
                let index = start + offset
                let mark = item.complete ? "✓" : index == firstOpen && !m.phase.finished ? "…" : "○"
                block.append(mark + " " + TelegramHTML.escape(TelegramText.clip(item.title, 48)))
            }
            let hidden = items.count - shown.count
            if hidden > 0 { block.append(TelegramHTML.italic("+\(hidden) more")) }
            lines.append(block.joined(separator: "\n"))
        }
        if !m.parts.isEmpty || m.partsSummary != nil {
            var block: [String] = []
            if let summary = m.partsSummary { block.append(TelegramHTML.escape(summary)) }
            for part in m.parts.prefix(maxParts) { block.append("• " + TelegramHTML.escape(TelegramText.clip(part, 80))) }
            if m.parts.count > maxParts, maxParts > 0 { block.append(TelegramHTML.italic("+\(m.parts.count - maxParts) more")) }
            if !block.isEmpty { lines.append(block.joined(separator: "\n")) }
        }
        let origin = (m.background ? "Background" : "Normal") + (m.source.map { " · from " + $0 } ?? "") + " · #" + m.shortID
        lines.append(TelegramHTML.italic(origin))
        return lines.joined(separator: "\n\n").replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    /// Buttons for the card, by phase. Answers come first while waiting; finished cards offer what's useful next.
    static func keyboard(_ m: RunCardModel) -> [[TGButton]] {
        let id = m.shortID
        func c(_ text: String, _ action: CardAction) -> TGButton { .callback(text, CallbackData.control(id, action)) }
        switch m.phase {
        case .queued: return [[c("📸 Screenshot", .screenshot), c("⏹ Stop", .stop)]]
        case .working: return [[c("⏸ Pause", .pause), c("📸 Screenshot", .screenshot), c("⏹ Stop", .stop)]]
        case .waiting:
            var rows = answerRows(m.options, key: m.questionKey, max: 4)
            rows.append([c("⏭ Skip", .skip), c("🖥 Open on Mac", .open)])
            return rows
        case .waitingPrivate: return [[c("🖥 Open on Mac", .open), c("⏹ Stop", .stop)]]
        case .paused: return [[c("▶️ Resume", .resume), c("🖐 Take over", .takeover), c("⏹ Stop", .stop)]]
        case .takenOver: return [[c("↩️ Hand back", .handback), c("🖥 Open on Mac", .open), c("⏹ Stop", .stop)]]
        case .done, .doneUnconfirmed, .failed, .stopped:
            var first = [c("📄 Result", .result), c("📸 Screenshot", .screenshot)]
            if m.canRunAgain { first.append(c("🔁 Run again", .again)) }
            var rows = [first]
            if let link = m.link.flatMap(TelegramLinks.web) { rows.append([.url("🔗 Open link", link)]) }
            return rows
        }
    }

    /// Numbered answer buttons, one per row (labels are often long), up to `max`.
    static func answerRows(_ options: [String], key: String?, max: Int = 8) -> [[TGButton]] {
        guard let key else { return [] }
        return options.prefix(max).enumerated().map { index, option in
            [.callback("\(index + 1). " + TelegramText.clip(option, 56), CallbackData.answer(key, index))]
        }
    }
}

/// The question message: notifies (unlike the silent card), carries the options, Skip and Open on Mac.
enum QuestionMessage {
    static func render(shortID: String, title: String, text: String, sensitive: Bool, note: String?, paused: Bool,
                       options: [String], limit: Int = RunCard.textLimit) -> String {
        var lines = ["🙋 " + TelegramHTML.bold("Input needed") + " · " + TelegramHTML.escape(title)]
        if sensitive {
            lines.append(TelegramHTML.escape("This one is private — answer it on your Mac. Don't send passwords or codes here."))
        } else {
            lines.append(TelegramHTML.escape(text))
            if !options.isEmpty {
                lines.append(options.prefix(8).enumerated().map { "\($0 + 1). " + TelegramHTML.escape(TelegramText.clip($1, 120)) }.joined(separator: "\n"))
            }
            lines.append(TelegramHTML.italic(options.isEmpty ? "Reply to this message with your answer." : "Tap an option, or reply to this message in your own words."))
        }
        if paused { lines.append("⏸ " + TelegramHTML.escape("Paused: no default will be chosen while the task is paused.")) }
        else if let note { lines.append("⏱ " + TelegramHTML.escape(note)) }
        lines.append(TelegramHTML.italic("#" + shortID))
        let html = lines.joined(separator: "\n\n")
        if html.utf16.count <= limit { return html }
        // Too long for one message (a caption): keep the head and point at the full text that follows.
        return "🙋 " + TelegramHTML.bold("Input needed") + " · " + TelegramHTML.escape(TelegramText.clip(title, 60))
            + "\n\n" + TelegramHTML.escape(TelegramText.clip(text, max(40, limit - 300)))
    }

    static func keyboard(shortID: String, key: String, options: [String], sensitive: Bool) -> [[TGButton]] {
        func c(_ text: String, _ action: CardAction) -> TGButton { .callback(text, CallbackData.control(shortID, action)) }
        if sensitive { return [[c("🖥 Open on Mac", .open), c("⏹ Stop", .stop)]] }
        var rows = RunCard.answerRows(options, key: key, max: 8)
        rows.append([c("⏭ Skip", .skip), c("🖥 Open on Mac", .open)])
        return rows
    }
}

// MARK: - Buttons and callback data

struct TGButton: Equatable {
    var text: String
    var data: String? = nil
    var url: String? = nil
    static func callback(_ text: String, _ data: String) -> TGButton { .init(text: text, data: data) }
    static func url(_ text: String, _ url: String) -> TGButton { .init(text: text, url: url) }
    var json: [String: String] {
        if let url { return ["text": text, "url": url] }
        return ["text": text, "callback_data": data ?? ""]
    }
    static func markup(_ rows: [[TGButton]]) -> [String: Any] { ["inline_keyboard": rows.map { $0.map(\.json) }] }
}

enum CardAction: String, CaseIterable {
    case status, card, screenshot, result, open, stop, pause, resume, takeover, handback, skip, again
    /// Actions that change a live run; on a finished run they answer "This run has finished".
    var needsLiveRun: Bool { [.open, .stop, .pause, .resume, .takeover, .handback, .skip].contains(self) }
}

enum CallbackData {
    enum Parsed: Equatable {
        case control(String, CardAction)
        case answer(String, Int)
    }
    static func control(_ shortID: String, _ action: CardAction) -> String { "c:\(shortID):\(action.rawValue)" }
    static func answer(_ key: String, _ index: Int) -> String { "a:\(key):\(index)" }
    static func parse(_ data: String) -> Parsed? {
        guard data.utf8.count <= 64 else { return nil }
        let parts = data.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[1].isEmpty else { return nil }
        if parts[0] == "c", let action = CardAction(rawValue: parts[2]) { return .control(parts[1], action) }
        if parts[0] == "a", let index = Int(parts[2]), index >= 0 { return .answer(parts[1], index) }
        return nil
    }
}

/// Short toasts for button taps (answerCallbackQuery, 0-200 characters).
enum TapToast {
    static let finished = "This run has finished"
    static let expired = "This button has expired. /status shows current runs."
    static func control(_ action: CardAction, changed: Bool, state: String) -> String {
        guard changed else { return "Already \(state.lowercased())" }
        switch action {
        case .pause: return "Paused"
        case .resume: return "Resuming"
        case .takeover: return "It's yours — shown on your Mac"
        case .handback: return "Handed back"
        default: return "OK"
        }
    }
}

// MARK: - Commands and quick replies

enum TelegramCommands {
    /// Registered with setMyCommands at startup so the command menu is populated.
    static let menu: [(String, String)] = [
        ("new", "Start a task (add foreground: to use the screen)"),
        ("status", "Active runs"),
        ("runs", "Recent runs and results"),
        ("screenshot", "Screenshot of the selected run"),
        ("pause", "Pause the selected run"),
        ("resume", "Resume the selected run"),
        ("takeover", "Pause and show it on your Mac"),
        ("handback", "Let it continue after you're done"),
        ("stop", "Stop the selected run (/stop all)"),
        ("result", "Full result of the selected run"),
        ("help", "How this works"),
    ]
    static var json: [[String: String]] { menu.map { ["command": $0.0, "description": $0.1] } }

    static let help = """
    Send a task in plain words — it runs in the background on your Mac. Start with “foreground:” to use the screen.
    Photos and files you send are attached to the task.

    Each run has one live card. Reply to a card to add instructions, or with “pause”, “continue” or “stop”. Reply to a question (or tap an option) to answer it.

    /new — start a task (recent ones as quick replies)
    /status — active runs · /runs — recent results
    /pause · /resume · /takeover · /handback · /stop
    /screenshot · /result — selected run
    """
}

enum QuickReplies {
    /// Up to `limit` distinct short task texts: saved workflows first, then frequent, then recent requests.
    static func build(recent: [String], workflows: [String], limit: Int = 6) -> [String] {
        var counts: [String: Int] = [:], order: [String] = []
        for text in recent.reversed() {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("/"), value.count <= 120, !value.contains("\n") else { continue }
            if counts[value] == nil { order.append(value) }
            counts[value, default: 0] += 1
        }
        let frequent = order.enumerated().sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }.map(\.element)
        var result: [String] = []
        for value in workflows.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty && $0.count <= 120 }) + frequent
        where !result.contains(value) && result.count < limit {
            result.append(value)
        }
        return result
    }
    static func markup(_ items: [String]) -> [String: Any] {
        ["keyboard": items.map { [["text": $0]] }, "resize_keyboard": true, "one_time_keyboard": true,
         "input_field_placeholder": "Type a task or pick one"]
    }
}

// MARK: - Pacing

/// Coalesces card edits: one edit per card at most every `minInterval`; requests in between are merged into one
/// later edit. Telegram allows about one message per second per chat; edits count, so cards stay well under that.
struct EditCoalescer: Equatable {
    enum Decision: Equatable { case now, after(TimeInterval), merged }
    var minInterval: TimeInterval
    private(set) var lastEdit: Date?
    private(set) var scheduled = false

    init(minInterval: TimeInterval) { self.minInterval = minInterval }

    mutating func request(at now: Date) -> Decision {
        if scheduled { return .merged }
        scheduled = true
        guard let lastEdit else { return .now }
        let wait = lastEdit.addingTimeInterval(minInterval).timeIntervalSince(now)
        return wait > 0 ? .after(wait) : .now
    }
    /// The scheduled edit ran (or was skipped as unchanged); later requests schedule a new one.
    mutating func flushed(at now: Date, sent: Bool) {
        scheduled = false
        if sent { lastEdit = now }
    }
}

/// When the card's photo is refreshed: only on a meaningful change (phase, step, checklist progress), never more
/// often than `minInterval`, and an identical image is never re-uploaded.
enum CardPhotoPolicy {
    static func key(phase: CardPhase, step: Int, checked: Int) -> String { "\(phase.rawValue)|\(step)|\(checked)" }
    static func shouldCapture(now: Date, last: Date?, lastKey: String?, key: String, minInterval: TimeInterval = 20) -> Bool {
        guard key != lastKey else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= minInterval
    }
    static func shouldUpload(_ image: Data, lastDigest: Int?) -> Bool { digest(image) != lastDigest }
    static func digest(_ image: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(image.count)
        hasher.combine(image)
        return hasher.finalize()
    }
}

/// Bot API retry rules. A 429 was never delivered, so it is always retried after `retry_after`. Network failures and
/// 5xx have an unknown outcome: only idempotent calls (edits, reads, toasts) are retried, never a new message.
enum TelegramRetry {
    static let maxAttempts = 3
    static let idempotent: Set<String> = ["editMessageText", "editMessageCaption", "editMessageMedia", "editMessageReplyMarkup",
                                          "answerCallbackQuery", "setMyCommands", "sendChatAction", "setMessageReaction",
                                          "getFile", "getMe", "deleteMessage"]
    /// Seconds to wait before the next attempt, or nil to give up. `status` nil = network error.
    static func delay(method: String, status: Int?, retryAfter: Int?, attempt: Int) -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        if status == 429 { return TimeInterval(min(max(retryAfter ?? 1, 1), 60)) }
        let unknown = status == nil || (status ?? 0) >= 500
        guard unknown, idempotent.contains(method) else { return nil }
        return pow(2, Double(attempt - 1)) // 1 s, 2 s
    }
    /// An edit that changes nothing is a success, not an error.
    static func isNotModified(_ description: String?) -> Bool { description?.lowercased().contains("message is not modified") == true }
    /// The card was deleted in the chat: the next update sends a fresh one.
    static func isGone(_ description: String?) -> Bool {
        guard let text = description?.lowercased() else { return false }
        return text.contains("message to edit not found") || text.contains("message can't be edited") || text.contains("message_id_invalid")
    }
}

// MARK: - Results

enum ResultText {
    static let unconfirmedPrefix = "Done — one item I couldn't confirm"
    static func isUnconfirmed(_ answer: String) -> Bool { answer.hasPrefix(unconfirmedPrefix) }
    /// The screenshot path Clinqy appends to an unconfirmed finish (" Screenshot: /path.png").
    static func screenshotPath(_ answer: String) -> String? {
        guard let range = answer.range(of: " Screenshot: ", options: .backwards) else { return nil }
        let path = answer[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && !path.contains("\n") ? path : nil
    }
    /// The answer without the local screenshot path (the image itself is attached).
    static func withoutScreenshotPath(_ answer: String) -> String {
        guard screenshotPath(answer) != nil, let range = answer.range(of: " Screenshot: ", options: .backwards) else { return answer }
        return String(answer[..<range.lowerBound])
    }
    /// The one-line result for /runs.
    static func oneLiner(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        let first = withoutScreenshotPath(text).components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return TelegramText.clip(first, 90)
    }
    /// The notifying completion message: outcome, concise summary and links.
    static func render(phase: CardPhase, title: String, shortID: String, summary: String, links: [String], extra: String? = nil,
                       limit: Int) -> String {
        let budget = max(60, limit - 260 - links.prefix(3).reduce(0) { $0 + min($1.count, 200) })
        var lines = [phase.emoji + " " + TelegramHTML.bold(phase.label) + " · " + TelegramHTML.escape(title)]
        let body = TelegramText.clip(withoutScreenshotPath(summary), budget)
        if !body.isEmpty { lines.append(TelegramHTML.escape(body)) }
        if let extra, !extra.isEmpty { lines.append(TelegramHTML.escape(TelegramText.clip(extra, 160))) }
        let shown = links.prefix(3).filter { $0.count <= 200 }
        if !shown.isEmpty { lines.append(shown.map { "🔗 " + TelegramHTML.link($0) }.joined(separator: "\n")) }
        lines.append(TelegramHTML.italic("#" + shortID))
        let html = lines.joined(separator: "\n\n")
        return html.utf16.count <= limit ? html : TelegramHTML.escape(TelegramText.clip(phase.emoji + " " + phase.label + " · " + title, limit / 2))
    }
}

// MARK: - Reply routing

/// Natural phrases that control the replied-to (or selected) run instead of being sent to it as instructions.
enum Steering {
    enum Command: Equatable { case stop, pause, resume, status, screenshot, takeOver, handBack }
    static func command(_ text: String) -> Command? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:please |ok |okay )+|(?: please| now| it| this| this task| the task)+$"#, with: "", options: .regularExpression)
        switch t {
        case "stop", "cancel", "abort", "stop task", "kill", "quit": return .stop
        case "pause", "hold", "hold on", "wait", "pause task", "pause for now": return .pause
        case "continue", "resume", "go on", "keep going", "carry on", "go", "unpause": return .resume
        case "status", "progress", "how is it going", "update": return .status
        case "screenshot", "show me", "screen": return .screenshot
        case "take over", "let me", "i'll do it", "i will do it": return .takeOver
        case "hand back", "your turn", "done, continue", "all yours": return .handBack
        default: return nil
        }
    }
}

/// Where a plain (non-command, non-button) message goes. Pure: Telegram supplies the facts it knows.
enum MessageRoute {
    struct ReplyFacts: Equatable {
        var run: UUID
        var ended: Bool
        /// The reply was to a question message; `current` = it's still that run's open question.
        var toQuestion: Bool
        var current: Bool
        var waiting: Bool
        var mirrored: Bool
    }
    enum Decision: Equatable {
        case answer(UUID)
        case control(UUID, Steering.Command)
        case context(UUID)
        case questionEnded
        case ambiguous
        /// A new task; `followUp` carries the earlier run whose result/files give it context.
        case newTask(followUp: UUID?)
    }

    /// - forceNew: `/new …` · explicitNew: a stated mode or a new URL (never an answer) · waitingOwned: Telegram runs
    ///   waiting on a question · selected: the last run the chat worked with, if it's a Telegram run (mirrored runs are
    ///   never steered by an unscoped message) · followUpPhrase: "also…", "now…", "continue…".
    static func decide(text: String, forceNew: Bool, explicitNew: Bool, reply: ReplyFacts?, waitingOwned: [UUID],
                       selected: (id: UUID, ended: Bool, mirrored: Bool, recent: Bool)?, followUpPhrase: Bool) -> Decision {
        if forceNew { return .newTask(followUp: nil) }
        if let reply {
            if reply.toQuestion && !reply.current { return .questionEnded }
            if reply.ended { return .newTask(followUp: reply.run) }
            if reply.waiting && (reply.toQuestion || Steering.command(text) == nil) { return .answer(reply.run) }
            if let command = Steering.command(text) { return .control(reply.run, command) }
            return .context(reply.run)
        }
        if explicitNew { return .newTask(followUp: nil) }
        if waitingOwned.count == 1, let only = waitingOwned.first { return .answer(only) }
        if waitingOwned.count > 1 { return .ambiguous }
        if followUpPhrase, let selected, !selected.mirrored {
            if !selected.ended { return .context(selected.id) }
            if selected.recent { return .newTask(followUp: selected.id) }
        }
        return .newTask(followUp: nil)
    }
}

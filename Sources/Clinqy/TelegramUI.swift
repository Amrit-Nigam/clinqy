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
    /// Plain-text fallback for a rendered HTML string: drops tags, decodes the entities `escape` produces.
    static func plain(_ html: String) -> String {
        var out = ""
        var inTag = false
        for character in html {
            if inTag { if character == ">" { inTag = false }; continue }
            if character == "<" { inTag = true; continue }
            out.append(character)
        }
        return out.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
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
    /// A URL Telegram accepts on an inline-keyboard button: http(s) with a public host (see `isPublicHost`).
    static func button(_ text: String) -> String? {
        guard let value = web(text), let host = URL(string: value)?.host, isPublicHost(host) else { return nil }
        return value
    }
    /// Public DNS hosts only: no localhost, *.localhost, *.local, dotless names, or loopback/private/link-local IPs.
    static func isPublicHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        if host.contains(":") { return isPublicIPv6(host) }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            let n = parts.compactMap { Int($0) }
            guard n.count == 4, n.allSatisfy({ $0 <= 255 }) else { return false }
            if n[0] == 0 || n[0] == 10 || n[0] == 127 || n[0] >= 224 { return false }
            if n[0] == 169 && n[1] == 254 { return false }
            if n[0] == 172 && (16...31).contains(n[1]) { return false }
            if n[0] == 192 && n[1] == 168 { return false }
            if n[0] == 100 && (64...127).contains(n[1]) { return false }
            return true
        }
        guard host.contains("."), host != "localhost" else { return false }
        for suffix in [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".localdomain"] where host.hasSuffix(suffix) { return false }
        return true
    }
    private static func isPublicIPv6(_ host: String) -> Bool {
        let h = host.split(separator: "%").first.map(String.init) ?? host
        if h == "::" || h == "::1" { return false }
        if h.hasPrefix("::ffff:") { return isPublicHost(String(h.dropFirst(7))) }   // IPv4-mapped
        guard let first = h.split(separator: ":", omittingEmptySubsequences: false).first, let word = Int(first.isEmpty ? "0" : first, radix: 16) else { return false }
        if word & 0xfe00 == 0xfc00 { return false }   // fc00::/7 unique local
        if word & 0xffc0 == 0xfe80 { return false }   // fe80::/10 link-local
        if word & 0xffc0 == 0xfec0 { return false }   // site-local
        if word & 0xff00 == 0xff00 { return false }   // multicast
        return true
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
        if !m.phase.finished || m.elapsed > 0 { head += " · " + TelegramHTML.escape(TelegramText.elapsed(m.elapsed)) }
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
            if let link = m.link.flatMap(TelegramLinks.button) { rows.append([.url("🔗 Open link", link)]) }
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

/// Keyboard repair: if Telegram rejects a send because of a button URL, resend without the URL buttons.
enum TelegramKeyboardFallback {
    static func shouldRetryWithoutURLButtons(status: Int?, description: String?) -> Bool {
        guard status == nil || status == 400, let d = description?.lowercased() else { return false }
        return d.contains("wrong http url") || d.contains("button url") || d.contains("inline keyboard") || d.contains("reply markup")
            || d.contains("url host is empty") || d.contains("wrong url") || d.contains("button_url_invalid")
    }
    /// The markup without URL buttons (callback buttons kept; empty rows dropped), or nil when it has none.
    static func strippingURLButtons(_ markup: [String: Any]) -> [String: Any]? {
        guard let rows = markup["inline_keyboard"] as? [[[String: String]]],
              rows.contains(where: { $0.contains { $0["url"] != nil } }) else { return nil }
        return ["inline_keyboard": rows.map { $0.filter { $0["url"] == nil } }.filter { !$0.isEmpty }]
    }
}

/// Card facts that must survive a missing or mismatched worker reference: the durable task record is the fallback.
enum RunCardFacts {
    /// The live narration when there is one, else the record's last stage line (updated every turn).
    static func action(narration: String?, stage: String?) -> String? {
        for text in [narration, stage] { if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t } }
        return nil
    }
    static func waitingOnRecord(state: String?, ended: Bool) -> Bool { !ended && state == "waiting" }
    static func runningOnRecord(state: String?) -> Bool { state == "running" }
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
    /// The edit has started (it already read the card's state) and hasn't finished.
    private(set) var inFlight = false
    /// A change arrived while the edit was in flight: it needs one more edit once that one finishes.
    private(set) var dirty = false

    init(minInterval: TimeInterval) { self.minInterval = minInterval }

    mutating func request(at now: Date) -> Decision {
        if inFlight { dirty = true; return .merged }
        if scheduled { return .merged }
        scheduled = true
        guard let lastEdit else { return .now }
        let wait = lastEdit.addingTimeInterval(minInterval).timeIntervalSince(now)
        return wait > 0 ? .after(wait) : .now
    }
    /// The scheduled edit is about to read the card's state; changes from now on need another edit.
    mutating func began() { inFlight = true }
    /// The scheduled edit ran (or was skipped as unchanged); later requests schedule a new one. Returns the follow-up
    /// edit owed to changes that arrived while it was in flight, or nil.
    @discardableResult
    mutating func flushed(at now: Date, sent: Bool) -> Decision? {
        scheduled = false; inFlight = false
        if sent { lastEdit = now }
        guard dirty else { return nil }
        dirty = false
        return request(at: now)
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
    /// Telegram refused the markup itself (400 "can't parse entities" / "Unsupported start tag").
    static func isParseError(_ description: String?) -> Bool {
        guard let text = description?.lowercased() else { return false }
        return text.contains("can't parse entities") || text.contains("unsupported start tag") || text.contains("can't find end tag")
            || text.contains("unmatched end tag") || text.contains("unclosed")
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

/// The final view on a completion message. Order: the screenshot saved for an unconfirmed item, the capture taken
/// as the run finished (before its task tab/window was released), a fresh capture, then the last card thumbnail.
/// A stopped run gets no final view. Delivery: one photo with the result as its caption when it fits, else the
/// photo followed by the full result text (which carries the buttons); text only when there is no usable image.
enum CompletionPhoto {
    enum Layout: Equatable { case photoWithCaption, photoThenText, textOnly }

    static func usable(_ image: Data?, limit: Int) -> Data? {
        guard let image, !image.isEmpty, image.count < limit else { return nil }
        return image
    }
    /// The image to send, without any capture: nil means "try a live capture, then the card thumbnail".
    static func preferred(saved: Data?, final: Data?, limit: Int) -> Data? {
        usable(saved, limit: limit) ?? usable(final, limit: limit)
    }
    static func pick(saved: Data?, final: Data?, live: Data?, card: Data?, stopped: Bool, limit: Int) -> Data? {
        guard !stopped else { return usable(saved, limit: limit) }
        return preferred(saved: saved, final: final, limit: limit) ?? usable(live, limit: limit) ?? usable(card, limit: limit)
    }
    /// The first usable thumbnail the run ever had: the card's last uploaded image, else one still queued for upload,
    /// else an earlier saved view. Read at send time (after the captures), not before them: a card photo can finish
    /// uploading while the final capture is in flight.
    static func fallback(_ candidates: [Data?], limit: Int) -> Data? {
        for candidate in candidates { if let image = usable(candidate, limit: limit) { return image } }
        return nil
    }
    /// A capture that gives up after `seconds` (nil) so a slow or hung screenshot can't hold the final result back
    /// or starve the thumbnail fallback.
    static func capture(timeout seconds: Double, _ operation: @escaping @Sendable () async -> Data?) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let gate = NSLock()
            nonisolated(unsafe) var finished = false
            let finish: @Sendable (Data?) -> Void = { value in
                gate.lock(); let first = !finished; finished = true; gate.unlock()
                if first { continuation.resume(returning: value) }
            }
            Task { finish(await operation()) }
            Task { try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)); finish(nil) }
        }
    }
    /// `fullText`: the result rendered with the message limit; it fits as a caption when within the caption limit.
    static func layout(photo: Data?, fullText: String, captionLimit: Int = RunCard.captionLimit) -> Layout {
        guard photo != nil else { return .textOnly }
        return fullText.utf16.count <= captionLimit ? .photoWithCaption : .photoThenText
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

// MARK: - Back-references to the previous task

/// A short message that only makes sense as a follow-up of the task the same chat just finished ("Submit it", "yes do
/// it", "Apply it in arc", "foreground"). Such a message carries that task's request, URL and outcome as context, so a
/// fresh run knows what "it" is; a bare mode/browser reply re-runs the previous request in that mode or browser.
enum FollowUpRouting {
    enum Mode: Equatable { case foreground, background, browser(String) }
    struct Reference: Equatable {
        /// The message is only a mode/browser switch ("foreground", "in arc", "do it in chrome"): run the earlier request again.
        var rerun: Bool
        var mode: Mode?
    }
    struct Prior: Equatable {
        var request: String
        var outcome: String
        var finishedAt: Date
        var stopped: Bool
    }
    static let window: TimeInterval = 30 * 60

    private static let browsers: [(pattern: String, name: String)] = [
        ("arc", "Arc"), ("google chrome", "Google Chrome"), ("chrome", "Google Chrome"), ("brave", "Brave Browser"),
        ("safari", "Safari"), ("edge", "Microsoft Edge"), ("firefox", "Firefox"),
    ]

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[’`]"#, with: "'", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s']"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// nil = not a back-reference (a self-contained task, a URL, a long message).
    static func reference(_ text: String) -> Reference? {
        guard text.range(of: #"https?://|www\."#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        let t = normalized(text)
        let words = t.split(separator: " ")
        guard !t.isEmpty, words.count <= 8, t.count <= 70 else { return nil }
        var mode: Mode?
        let browserAlternation = browsers.map(\.pattern).joined(separator: "|")
        if let r = t.range(of: #"\b(?:in|on|with|using|use|via|open|through)\s+(?:the\s+)?(?:my\s+)?("# + browserAlternation + #")\b"#, options: .regularExpression),
           let name = browsers.first(where: { t[r].hasSuffix(" " + $0.pattern) || t[r].hasSuffix($0.pattern) }) {
            mode = .browser(name.name)
        } else if t.range(of: #"\b(foreground|normal mode|in front|visibly)\b"#, options: .regularExpression) != nil {
            mode = .foreground
        } else if t.range(of: #"\b(?:in|as)\s+(?:the\s+)?background\b|^background(?: mode)?$"#, options: .regularExpression) != nil {
            mode = .background
        }
        // Only a mode/browser, with at most a generic verb and a pronoun around it: "foreground", "in arc",
        // "do it in chrome", "try again in the foreground", "use arc instead".
        let filler = #"^(?:(?:please|ok|okay|yes|yeah|yep|sure|then|now|just|do|did|redo|run|rerun|try|retry|again|it|this|that|same|one|thing|instead|mode|browser|in|on|the|with|using|use|via|open|through|my|a|front|of|me|visibly|foreground|normal|background|as|"#
            + browserAlternation.replacingOccurrences(of: "google chrome", with: "google") + #")\b\s*)+$"#
        if mode != nil, t.range(of: filler, options: .regularExpression) != nil {
            return Reference(rerun: true, mode: mode)
        }
        // A pronoun or a bare go-ahead with nothing else to say what it is.
        let pronoun = t.range(of: #"\b(it|this|that|these|those|them|same|again|the form|the application|the job)\b"#, options: .regularExpression) != nil
        let goAhead = t.range(of: #"^(?:(?:ok|okay|yes|yeah|yep|sure|please|now|then)\s+)*(?:go ahead|do it|proceed|continue|finish|submit|apply|send|retry|try again|carry on|complete|confirm)\b"#,
                              options: .regularExpression) != nil
        guard pronoun || goAhead || mode != nil, words.count <= 6 || pronoun else { return nil }
        // Long noun phrases ("submit the expense report for March") name their own target.
        if !pronoun, words.count > 3 { return nil }
        return Reference(rerun: false, mode: mode)
    }

    /// The prior task a reference continues: the newest one finished/stopped within the window, else nil.
    static func pick(_ candidates: [Prior], now: Date = Date()) -> Prior? {
        candidates.filter { now.timeIntervalSince($0.finishedAt) >= 0 && now.timeIntervalSince($0.finishedAt) <= window }
            .max { $0.finishedAt < $1.finishedAt }
    }

    static func firstURL(_ text: String) -> String? {
        guard let r = text.range(of: #"https?://[^\s<>"')]+"#, options: .regularExpression) else { return nil }
        return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
    }

    /// Context for the new run: what "it" refers to.
    static func context(for prior: Prior, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(prior.finishedAt) / 60))
        var lines = ["This message continues the task this chat \(prior.stopped ? "stopped" : "finished") \(minutes) min ago; \"it\"/\"this\" refers to that task.",
                     "Earlier request: " + String(prior.request.prefix(1200))]
        if let url = firstURL(prior.request) ?? firstURL(prior.outcome) { lines.append("Page: " + url) }
        let outcome = prior.outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        if !outcome.isEmpty { lines.append("Where it ended: " + String(outcome.prefix(1200))) }
        lines.append("Pick up from that state (reopen the page if needed and check what is already filled) instead of asking what \"it\" is.")
        return lines.joined(separator: "\n")
    }

    /// The new run's request text: a bare mode/browser switch repeats the earlier request in that browser.
    static func request(_ text: String, reference: Reference, prior: Prior) -> String {
        guard reference.rerun else { return text }
        if case .browser(let name) = reference.mode { return prior.request + "\n\nDo this in " + name + "." }
        return prior.request
    }

    /// Background flag for the new run: explicit foreground/background wins; a non-Chrome browser runs in front
    /// (background tabs live in Clinqy's Chrome); otherwise keep the default.
    static func background(_ reference: Reference, default value: Bool) -> Bool {
        switch reference.mode {
        case .foreground?: return false
        case .background?: return true
        case .browser(let name)?: return name == "Google Chrome" ? value : false
        case nil: return value
        }
    }
}

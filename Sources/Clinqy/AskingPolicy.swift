import Foundation

/// When Clinqy asks before acting. Pure decisions (no UI, no globals) so the test scripts can cover every rule.
///
/// The line that never moves: paying/buying/booking/transferring, sending to other people, permanent deletion and
/// public posting need a yes unless the request pre-authorised that exact action, the user approved the plan that
/// contains it (money excepted), or a site/app rule the user set allows it. A timeout never approves any of them.

/// What a consequential control would do.
enum RiskKind: String, Codable, CaseIterable {
    case payment, booking, transfer, deletion, message, publicPost, formSubmit
    /// A word from the old broad list (submit, apply, remove, share…) with nothing around it implying money,
    /// messages, permanent deletion or posting: asked only when the user said "ask before anything".
    case general

    var involvesMoney: Bool { self == .payment || self == .booking || self == .transfer }

    /// Short words for the question ("About to pay — …").
    var label: String {
        switch self {
        case .payment: return "pay"
        case .booking: return "book"
        case .transfer: return "move money"
        case .deletion: return "delete"
        case .message: return "send"
        case .publicPost: return "post"
        case .formSubmit: return "submit"
        case .general: return "go ahead"
        }
    }

    /// Words in a request that ask for this exact kind of action.
    var authorizingVerbs: [String] {
        switch self {
        case .payment: return ["pay", "buy", "purchase"]
        case .booking: return ["book", "reserve"]
        case .transfer: return ["transfer", "send money", "donate", "withdraw"]
        case .deletion: return ["delete", "remove", "erase", "trash", "empty", "cancel", "deactivate", "close my account", "unsubscribe"]
        case .message: return ["send", "reply", "message", "msg", "email", "invite", "forward", "dm", "ping", "whatsapp"]
        case .publicPost: return ["post", "publish", "tweet", "share", "repost"]
        case .formSubmit: return ["submit", "apply", "send", "register", "sign up", "fill and submit", "complete the application"]
        case .general: return []
        }
    }
}

enum RiskClassifier {
    private static func has(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let payment = #"\b(pay|payment|pay now|buy|buy now|purchase|place (your )?order|checkout|check out|proceed to (pay|checkout)|complete (purchase|order|payment))\b"#
    private static let booking = #"\b(book|book now|confirm booking|reserve)\b"#
    private static let transfer = #"\b(transfer|withdraw|donate|send money)\b"#
    private static let deletion = #"\b(delete|erase|delete forever|permanently delete|empty trash|empty bin|close (my |your )?account|deactivate|cancel (my |your )?(subscription|order|plan|membership|booking))\b"#
    private static let message = #"\b(send|reply all|send message|send email)\b"#
    private static let publicPost = #"\b(post|publish|tweet|repost|retweet|share publicly|make public)\b"#
    /// The old broad list: only consequential when the surrounding context says so.
    private static let general = #"\b(submit|apply|sign up|register|remove|trash|discard|share|unsubscribe|confirm)\b"#

    /// Words of a payment step (not a price filter or a product listing, which show prices too).
    private static let moneyContext = #"\b(order total|total due|amount due|payment|card number|cvv|cvc|billing|amount|checkout|subtotal|pay|upi)\b"#
    private static let messageContext = #"\b(message|messages|recipient|send to|subject|compose|reply|email to|chat|dm|inbox|to:)\b"#
    private static let deletionContext = #"\b(permanent(ly)?|can(no|')?t be undone|cannot be undone|irreversible|forever|delete|erase all|lose all)\b"#
    private static let publicContext = #"\b(public|publicly|everyone|anyone|publish|tweet|feed|timeline|followers|comment|reply to post)\b"#

    /// What clicking `label` would do. `context` is what surrounds it (page title, URL, the form's field labels):
    /// it only ever upgrades a broad word ("Submit" on a payment form is a payment), never downgrades a strict one.
    static func classify(label: String, context: String = "") -> RiskKind? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if has(text, transfer) { return .transfer }
        if has(text, payment) { return .payment }
        if has(text, booking) { return .booking }
        if has(text, deletion) { return .deletion }
        if has(text, publicPost) { return .publicPost }
        if has(text, message) { return .message }
        guard has(text, general) else { return nil }
        // "Remove"/"Trash"/"Discard" are permanent only when the page says so; "Share" is public only when it says so.
        if has(text, #"\b(remove|trash|discard)\b"#) { return has(context, deletionContext) ? .deletion : .general }
        if has(text, #"\bshare\b"#) { return has(context, publicContext) ? .publicPost : .general }
        if has(text, #"\b(unsubscribe|confirm)\b"#) && !has(text, #"\b(submit|apply|sign up|register)\b"#) {
            return has(context, moneyContext) ? .payment : .general
        }
        if has(context, moneyContext) { return .payment }
        if has(context, messageContext) { return .message }
        if has(context, publicContext) { return .publicPost }
        return .general
    }

    /// A native text field whose Return sends to someone: a chat composer or a messaging app ("Type a message" in
    /// WhatsApp, Messages, Slack…). Return in a search box or a document is not a send.
    static func isMessagingSurface(_ context: String) -> Bool {
        has(context, #"\b(message|messages|chat|compose|reply|whatsapp|telegram|signal|slack|discord|imessage|messenger|teams|dm|send)\b"#)
    }

    /// Every verb a request could use to ask for what `label` does (its kind's verbs plus the label's own words).
    static func verbs(label: String, kind: RiskKind) -> [String] {
        var verbs = kind.authorizingVerbs
        // Only words that are the action itself: "order", "checkout", "clear" also mean other things ("in order to",
        // "clear the search"), so they never pre-authorise anything.
        let own = ["submit", "apply", "sign up", "register", "remove", "trash", "discard", "share", "unsubscribe", "cancel",
                   "confirm", "delete", "send", "post", "publish", "book", "reserve", "pay", "buy", "transfer", "donate"]
        for word in own where has(label, #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#) && !verbs.contains(word) {
            verbs.append(word)
        }
        return verbs
    }
}

/// "submit the form", "send it to Riya", "buy it": the request names the action, so that action needs no second yes.
///
/// Deliberately narrow (a miss only costs one question): the verb must be used as an instruction to Clinqy (start of a
/// clause, or after "and", "then", "to", "please"…), never as a noun ("find books", "read the message"); a label that
/// names its object ("Delete account") needs that object right after the verb in the same clause; "email me…" is not
/// sending to someone else; and any negation or first-person ownership ("I'll submit it myself") rules it out.
enum PreAuthorization {
    /// Words before a verb that keep it an instruction to Clinqy.
    private static let instructionLead: Set<String> = [
        ",", "to", "and", "then", "or", "&", "+", "can", "could", "you", "will", "would", "should", "must", "may", "please", "pls",
        "kindly", "just", "also", "now", "finally", "go", "ok", "okay", "yes", "ahead", "simply", "directly", "-",
    ]
    /// Words a few words before a verb that rule it out ("don't, under any circumstances, pay", "you shouldn't send").
    private static let negators: Set<String> = [
        "don't", "dont", "not", "never", "without", "no", "shouldn't", "shouldnt", "won't", "wont", "mustn't", "mustnt",
        "can't", "cant", "cannot", "avoid", "before", "isn't", "aren't", "didn't", "doesn't", "neither", "nor", "stop",
    ]
    /// First person just before the verb: the user will do it themselves ("I'll submit", "let me pay").
    private static let firstPerson: Set<String> = ["i", "i'll", "i'd", "i'm", "ill", "im", "we", "we'll", "me", "myself", "ourselves"]
    /// Label words that don't say *what* is acted on ("Place order", "Book now", "Send message").
    static let genericLabelWords: Set<String> = [
        "now", "place", "order", "orders", "your", "my", "the", "a", "an", "to", "it", "this", "that", "all", "selected", "item", "items",
        "here", "again", "anyway", "forever", "permanently", "complete", "proceed", "continue", "confirm", "checkout", "check", "out",
        "purchase", "payment", "booking", "reservation", "message", "messages", "email", "mail", "reply", "post", "form", "application",
        "request", "public", "publicly", "make", "others", "everyone", "trash", "bin", "and", "for", "with", "on", "in", "of", "up",
        "me", "yes", "ok", "go", "ahead", "securely", "safely", "pay", "send", "submit", "delete", "book", "buy",
    ]
    private static let irregular: [String: [String]] = ["send": ["sent"], "pay": ["paid"], "buy": ["bought"]]

    /// Clauses: sentences, and the parts around "but"/"then"/":" ("fill it but don't submit", "check, then pay").
    static func clauses(_ request: String) -> [[String]] {
        let text = request.lowercased().replacingOccurrences(of: "’", with: "'")
        let marked = text.replacingOccurrences(of: #"[.;!?:\n]+|\bbut\b|\bthen\b"#, with: "\u{1}", options: .regularExpression)
        return marked.split(separator: "\u{1}").map { words(String($0)) }.filter { !$0.isEmpty }
    }

    /// Lower-cased words (letters, digits, apostrophes, hyphens); commas kept as "," tokens.
    static func words(_ text: String) -> [String] {
        var out: [String] = [], current = ""
        for c in text.lowercased().replacingOccurrences(of: "’", with: "'") {
            if c.isLetter || c.isNumber || c == "'" || c == "-" { current.append(c); continue }
            if !current.isEmpty { out.append(current); current = "" }
            if c == "," { out.append(",") }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// `token` is `verb` or an inflection of it (submitting, submitted, deleting, sent) — never a plural noun ("books").
    static func inflects(_ token: String, _ verb: String) -> Bool {
        if token == verb || irregular[verb]?.contains(token) == true { return true }
        var forms = [verb + "ing", verb + "ed", verb + "d"]
        if verb.hasSuffix("e") { forms.append(String(verb.dropLast()) + "ing") }
        if let last = verb.last, !"aeiouwy".contains(last) { forms += [verb + String(last) + "ing", verb + String(last) + "ed"] }
        return forms.contains(token)
    }

    /// Where each verb phrase occurs in a clause: (start, end) token positions.
    private static func occurrences(of verb: String, in clause: [String]) -> [(Int, Int)] {
        let parts = words(verb)
        guard let first = parts.first, clause.count >= parts.count else { return [] }
        var found: [(Int, Int)] = []
        for i in 0...(clause.count - parts.count) where inflects(clause[i], first) {
            if (1..<parts.count).allSatisfy({ clause[i + $0] == parts[$0] }) { found.append((i, i + parts.count)) }
        }
        return found
    }

    /// The `n` words before `index` (commas skipped).
    private static func before(_ clause: [String], _ index: Int, _ n: Int) -> [String] {
        Array(clause[..<index].filter { $0 != "," }.suffix(n))
    }

    private static func isNegated(_ clause: [String], at index: Int) -> Bool {
        if before(clause, index, 5).contains(where: negators.contains) { return true }
        if before(clause, index, 3).contains(where: firstPerson.contains) { return true }
        return clause.contains("myself") || clause.contains("ourselves")
    }

    /// "don't submit", "without sending", "never post", "I'll submit it myself", "Don't, under any circumstances, pay":
    /// the user ruled this out (or kept it for themselves).
    static func negated(_ verbs: [String], in request: String) -> Bool {
        let clauses = clauses(request)
        return verbs.contains { verb in clauses.contains { clause in occurrences(of: verb, in: clause).contains { isNegated(clause, at: $0.0) } } }
    }

    /// What the label acts on beyond its verb ("Delete account" → account); empty for "Pay ₹500", "Book now", "Send".
    static func objects(label: String, verbs: [String]) -> [String] {
        let verbWords = Set(verbs.compactMap { words($0).first })
        return words(label).filter { w in
            w.count >= 2 && w.allSatisfy(\.isLetter) && !genericLabelWords.contains(w) && !verbWords.contains(w)
        }
    }

    private static func names(_ token: String, _ object: String) -> Bool {
        token == object || token == object + "s" || token == object + "es"
            || (object.hasSuffix("y") && token == String(object.dropLast()) + "ies")
    }

    /// "message myself …", "send it to myself", "message me on WhatsApp", "my Message yourself chat": the request sends
    /// to the user's own chat. That is not sending to another person, so it needs no send approval once the open chat
    /// is shown to be the self chat (`isSelfChat`). Negated requests ("don't message myself") never count.
    static func selfMessage(_ request: String) -> Bool {
        let verbs = RiskKind.message.authorizingVerbs
        guard !clauses(request).contains(where: { clause in
            verbs.contains { verb in occurrences(of: verb, in: clause).contains { before(clause, $0.0, 5).contains(where: negators.contains) } }
        }) else { return false }
        for clause in clauses(request) {
            for verb in verbs {
                for (start, end) in occurrences(of: verb, in: clause) {
                    guard start == 0 || instructionLead.contains(clause[start - 1]) else { continue }
                    let after = Array(clause[end...].prefix(8))
                    let pairs = Array(zip(after, after.dropFirst()))
                    if after.prefix(2).contains(where: { $0 == "myself" || $0 == "me" })
                        || pairs.contains(where: { $0 == "to" && ($1 == "myself" || $1 == "me") }) { return true }
                    if pairs.contains(where: { ($0 == "own" && ["chat", "number", "notes"].contains($1)) || ($0 == "self" && $1 == "chat")
                        || ($0 == "message" && $1 == "yourself") }) { return true }
                }
            }
            if clause.contains("yourself"), let i = clause.firstIndex(of: "message"), clause.indices.contains(i + 1), clause[i + 1] == "yourself",
               verbs.contains(where: { v in clause.contains { inflects($0, v) && $0 != "message" } }) { return true }
        }
        return false
    }

    /// The open chat is the user's own: WhatsApp's "Message yourself" / "(You)", Telegram's "Saved Messages",
    /// Slack's "(you)", Messages' "Note to Self".
    /// Every text is normalised first (`AXText.normalized`): WhatsApp writes its badge as "(\u{200E}You)".
    static func isSelfChat(_ texts: [String]) -> Bool {
        texts.map(AXText.normalized).contains {
            $0 == "you" || $0.range(of: #"\bmessage yourself\b|\(you\)|\bsaved messages\b|\bnote to self\b|\bnotes to self\b"#, options: .regularExpression) != nil
        }
    }

    static func covers(label: String, kind: RiskKind, request: String) -> Bool {
        let verbs = RiskClassifier.verbs(label: label, kind: kind)
        guard !negated(verbs, in: request) else { return false }
        let objects = objects(label: label, verbs: verbs)
        let selfDirected = Set(RiskKind.message.authorizingVerbs + RiskKind.transfer.authorizingVerbs)
        for clause in clauses(request) {
            for verb in verbs {
                for (start, end) in occurrences(of: verb, in: clause) {
                    // An instruction, not a noun: start of the clause or after "and", "to", "please"…
                    guard start == 0 || instructionLead.contains(clause[start - 1]) else { continue }
                    let after = Array(clause[end...].prefix { $0 != "," }.prefix(6))
                    // "email me a summary", "send it to me": nothing goes to anyone else.
                    if selfDirected.contains(verb), after.prefix(3).contains(where: { $0 == "me" || $0 == "myself" }) { continue }
                    // "Delete account" needs the account named right after the verb ("delete the spam" is not it).
                    if !objects.isEmpty, !objects.contains(where: { o in (clause[start..<end] + after).contains { names($0, o) } }) { continue }
                    return true
                }
            }
        }
        return false
    }
}

/// Sending to the user's own chat: one decision shared by a native Send click and `type submit:true` (Return).
/// The send approval is skipped only when the control is a plain Send control, the request asks to message the user
/// themself, and the open conversation's header (never the chat list) shows a self-chat marker. Anything else (another recipient, "Send money",
/// a chat that isn't shown to be the self chat) goes through the usual approval, which still honours a request that
/// pre-authorised that recipient.
/// AX strings reduced for matching: bidi / format controls (U+200E, U+200F, U+202A–U+202E, U+2066–U+2069, U+FEFF)
/// removed, whitespace collapsed, lowercased. Apps (WhatsApp Catalyst) wrap names and badges in these invisible marks.
enum AXText {
    static func isFormatControl(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: return true
        default: return false
        }
    }

    /// The text without bidi / format controls (case and spacing kept).
    static func stripped(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: text.unicodeScalars.lazy.filter { !isFormatControl($0) })
        return String(out)
    }

    static func normalized(_ text: String) -> String {
        stripped(text).split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Two chat names are the same name once normalised.
    static func sameName(_ a: String, _ b: String) -> Bool {
        let x = normalized(a)
        return !x.isEmpty && x == normalized(b)
    }
}

enum SelfSend {
    /// Words a Send control's label may consist of ("Send", "send button", "paper-plane", "paperplane.fill").
    private static let sendWords: Set<String> = ["send", "message", "button", "now", "icon", "paper", "plane", "paperplane", "fill", "circle", "arrow", "up"]

    /// "Send", "Send message", "send button", a paper-plane icon — never "Send money", "Send invoice", "Send to Riya".
    static func isSendControl(_ label: String) -> Bool {
        let words = label.lowercased().split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty, words.allSatisfy(sendWords.contains) else { return false }
        return words.contains("send") || words.contains("paperplane") || (words.contains("paper") && words.contains("plane"))
    }

    /// `headerTexts`: the open conversation's header only (`ConversationHeader.resolve`); nil when it couldn't be
    /// resolved unambiguously, and then Clinqy asks as usual. Chat-list / sidebar text never counts.
    static func exempt(request: String, control: String, headerTexts: [String]?) -> Bool {
        guard let headerTexts, !headerTexts.isEmpty else { return false }
        return isSendControl(control) && PreAuthorization.selfMessage(request) && PreAuthorization.isSelfChat(headerTexts)
    }
}

/// The open conversation's header (title / subtitle), found from the composer: of every ancestor's children beside
/// the composer's branch (from the composer up to the window), exactly one may be header-like, and that one is the
/// header. A header-like child sits above the composer, lies mostly over the composer's columns (so a sidebar or chat
/// list to the side never counts), is a compact bar in the top band of the window (so a message list or a message
/// bubble above the composer never counts, however its app exposes it), and holds no list, table, row or text input
/// (a chat list, message list or search field). The composer may be any node of the field the app reports (the
/// observed id or the app's focused element): only its frame and position in the tree matter.
/// Two candidates anywhere on the way up are ambiguous: nil. None at all: the window title, if any; else nil.
enum ConversationHeader {
    struct Node {
        var role: String
        var texts: [String] = []
        var frame: CGRect? = nil
        var isComposer = false
        var children: [Node] = []
        /// AXHelp (tooltips). Never makes a node header-like (icon buttons carry only help), but once the header is
        /// resolved its help, and its bar mates' help, is read with it.
        var help: [String] = []
        /// AXIdentifier, when the app sets one (WhatsApp: `WDSNavigationBar`, `NavigationBar_HeaderViewButton`).
        var identifier: String? = nil
    }

    /// WhatsApp (Catalyst) names its bars: the open conversation's header is the `WDSNavigationBar` holding a
    /// `NavigationBar_HeaderViewButton` (the chat name). The sidebar's bar (New Chat / Search) holds none, and message
    /// bubbles (`WAMessageBubbleTableViewCell`) are never inside a bar, so neither ever counts.
    static let navigationBarID = "WDSNavigationBar"
    static let headerButtonID = "NavigationBar_HeaderViewButton"
    static let selfBadgeID = "WABadgedLabel_You"
    static let bubbleID = "WAMessageBubbleTableViewCell"

    private static func hasID(_ node: Node, _ id: String) -> Bool {
        node.identifier.map { AXText.stripped($0) == id } ?? false
    }

    private static func findAll(_ node: Node, _ match: (Node) -> Bool) -> [Node] {
        (match(node) ? [node] : []) + node.children.flatMap { findAll($0, match) }
    }

    /// The WhatsApp conversation header bar(s): `WDSNavigationBar`s whose subtree holds the header button, outside
    /// the composer's branch.
    private static func identifiedBars(root: Node) -> [Node] {
        findAll(root) { n in
            hasID(n, navigationBarID) && !containsComposer(n) && !findAll(n) { hasID($0, headerButtonID) }.isEmpty
        }
    }

    /// The structural reading of an identified header bar: its texts (bubbles skipped), plus "(You)" when the bar
    /// holds the `WABadgedLabel_You` badge.
    private static func identifiedBarTexts(_ bar: Node) -> [String] {
        func walk(_ n: Node) -> [String] {
            if hasID(n, bubbleID) { return [] }
            var out = (n.texts + n.help).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if hasID(n, selfBadgeID) { out.append("(You)") }
            return out + n.children.flatMap(walk)
        }
        return walk(bar)
    }

    /// The structural rule, when the app names its bars (WhatsApp): `.some(texts)` for exactly one identified header
    /// bar, `.some(nil)` when more than one (ambiguous), nil when the app names none (use the generic heuristic).
    static func identifiedHeader(root: Node) -> [String]?? {
        guard pathToComposer(root) != nil else { return nil }
        let bars = identifiedBars(root: root)
        switch bars.count {
        case 0: return nil
        case 1: return .some(identifiedBarTexts(bars[0]))
        default: return .some(nil)
        }
    }

    private static let collectionRoles: Set<String> = ["AXList", "AXTable", "AXOutline", "AXRow", "AXCell", "AXBrowser", "AXGrid", "AXCollection", "AXScrollArea"]
    private static let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    /// A header bar is at most this tall (WhatsApp / Telegram / Slack / Messages headers are 40–90 pt).
    static let maxHeaderHeight: CGFloat = 140
    /// …and ends within this distance of the window's top edge (or this share of the window's height, if larger).
    static let topBand: CGFloat = 160
    static let topBandShare: CGFloat = 0.2

    static func resolve(root: Node, windowTitle: String?) -> [String]? {
        if let identified = identifiedHeader(root: root) { return identified }
        switch candidates(root: root) {
        case .none: return nil
        case .some(let found) where found.count == 1: return barTexts(found[0], window: root.frame)
        case .some(let found) where found.count > 1: return nil
        default:
            let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? nil : [title]
        }
    }

    /// How many header-like regions the composer's column holds (for a diagnostic that never logs their text);
    /// nil when there is no single composer with a frame.
    static func candidateCount(root: Node) -> Int? {
        if identifiedHeader(root: root) != nil { return identifiedBars(root: root).count }
        return candidates(root: root)?.count
    }

    /// One header candidate and the other children of the level it was found at (never the composer's branch).
    private struct Candidate { var node: Node; var composer: CGRect; var levelMates: [Node] }

    /// The resolved header's text: the candidate's own title / description / value / help and its text children, plus
    /// the text of its bar mates: siblings at the same level that sit in the same row of the same short top bar
    /// (vertically overlapping the candidate), over the composer's columns, holding no list, table, row or input. WhatsApp's header is a name button with the
    /// "Message yourself" / "(You)" subtitle beside it in a group the app reports without a frame of its own, so the
    /// subtitle was never a candidate and the name alone was read (round 10: "1 header candidate", no marker).
    /// A bar mate's frame is its own, else the union of its descendants' frames; one with no frame at all never counts.
    private static func barTexts(_ c: Candidate, window: CGRect?) -> [String] {
        var out = texts(c.node) + helpTexts(c.node)
        guard let bar = c.node.frame else { return out }
        for mate in c.levelMates where !containsComposer(mate) {
            guard !containsRole(mate, collectionRoles), !containsRole(mate, inputRoles), let frame = effectiveFrame(mate) else { continue }
            // Same row of the same bar: vertically overlapping the candidate (a message just below the header never is).
            guard frame.minY < bar.maxY, frame.maxY > bar.minY else { continue }
            let union = bar.union(frame)
            guard union.height <= maxHeaderHeight, frame.maxY <= c.composer.minY + 1 else { continue }
            if let window, window.height > 0, union.maxY > window.minY + max(topBand, window.height * topBandShare) { continue }
            let overlap = max(0, min(frame.maxX, c.composer.maxX) - max(frame.minX, c.composer.minX))
            guard overlap >= frame.width * 0.5 else { continue }   // beside the conversation (a sidebar): never
            out += texts(mate) + helpTexts(mate)
        }
        return out
    }

    private static func effectiveFrame(_ node: Node) -> CGRect? {
        if let frame = node.frame, frame.width > 0, frame.height > 0 { return frame }
        let inner = node.children.compactMap(effectiveFrame)
        guard let first = inner.first else { return nil }
        return inner.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func helpTexts(_ node: Node) -> [String] {
        node.help.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } + node.children.flatMap(helpTexts)
    }

    private static func candidates(root: Node) -> [Candidate]? {
        guard let indices = pathToComposer(root) else { return nil }
        var path = [root]
        for i in indices { path.append(path[path.count - 1].children[i]) }
        guard let composerFrame = path[path.count - 1].frame, composerFrame.width > 0, composerFrame.height > 0 else { return nil }
        // Every ancestor, nearest first; the child on the composer's branch is skipped.
        var found: [Candidate] = []
        for depth in stride(from: path.count - 2, through: 0, by: -1) {
            let others = path[depth].children.enumerated().filter { $0.offset != indices[depth] }.map(\.element)
            let headers = others.indices.filter { isHeader(others[$0], composer: composerFrame, window: root.frame) }
            // A header bar sharing its level with more compact text blocks above the composer looks like the top
            // message of a flat message list, not a header: count those too, so the level reads as ambiguous.
            let stacked = others.indices.filter { panelText(others[$0], composer: composerFrame) && (others[$0].frame?.height ?? .infinity) <= maxHeaderHeight }
            found += (headers.isEmpty || stacked.count <= headers.count ? headers : stacked).map { i in
                Candidate(node: others[i], composer: composerFrame, levelMates: others.indices.filter { $0 != i }.map { others[$0] })
            }
        }
        return found
    }

    private static func containsComposer(_ node: Node) -> Bool { node.isComposer || node.children.contains(where: containsComposer) }

    /// Child indices from `node` down to the one composer; nil when there is none or more than one.
    private static func pathToComposer(_ node: Node) -> [Int]? {
        if node.isComposer { return node.children.contains(where: containsComposer) ? nil : [] }
        let hits = node.children.enumerated().compactMap { i, child in pathToComposer(child).map { [i] + $0 } }
        guard hits.count == 1, node.children.filter(containsComposer).count == 1 else { return nil }
        return hits[0]
    }

    private static func isHeader(_ node: Node, composer: CGRect, window: CGRect?) -> Bool {
        guard panelText(node, composer: composer), let frame = node.frame else { return false }
        guard frame.height <= maxHeaderHeight else { return false }   // a bar, not the message list
        if let window, window.height > 0 {                            // at the top of the window, not a message
            guard frame.maxY <= window.minY + max(topBand, window.height * topBandShare) else { return false }
        }
        return true
    }

    /// Text above the composer, over its columns, holding no list, table, row or text input.
    private static func panelText(_ node: Node, composer: CGRect) -> Bool {
        guard !containsComposer(node), let frame = node.frame, frame.width > 0, frame.height > 0 else { return false }
        guard frame.maxY <= composer.minY + 1 else { return false }   // above the composer (AX: y grows downward)
        let overlap = max(0, min(frame.maxX, composer.maxX) - max(frame.minX, composer.minX))
        guard overlap >= frame.width * 0.5 else { return false }      // over the conversation, not beside it
        guard !containsRole(node, collectionRoles), !containsRole(node, inputRoles) else { return false }
        return !texts(node).isEmpty
    }

    private static func containsRole(_ node: Node, _ roles: Set<String>) -> Bool {
        roles.contains(node.role) || node.children.contains { containsRole($0, roles) }
    }

    private static func texts(_ node: Node) -> [String] {
        node.texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } + node.children.flatMap(texts)
    }
}

/// What a yes to one of the model's own questions approves. Only the ask flagged as the plan (`"plan":true`) approves
/// the plan; any other yes approves only the consequential kind its question names ("Should I send it to Riya?" →
/// sending), never everything after it. A timeout default approves nothing.
enum AskApproval {
    static func grants(question: String, options: [String], reply: String, planFlag: Bool, autonomy: Autonomy,
                       planApproved: Bool, timedOut: Bool) -> (plan: Bool, kinds: Set<RiskKind>) {
        guard !timedOut, !options.isEmpty, Safety.isYes(reply) else { return (false, []) }
        if planFlag, autonomy == .plan, !planApproved { return (true, []) }
        let asked = question.firstIndex(of: "?").map { String(question[...$0]) } ?? question
        guard var kind = RiskClassifier.classify(label: asked) else { return (false, []) }
        if kind == .general {
            guard asked.range(of: #"(?i)\b(submit|apply)\b"#, options: .regularExpression) != nil else { return (false, []) }
            kind = .formSubmit
        }
        return (false, [kind])
    }

    /// The consequential kind a reply to one of the model's own questions declined ("Should I pay now?" → "No", or no
    /// reply in time), or nil: a free-text answer ("use the other card") is not a refusal.
    static func declinedKind(question: String, reply: String?, timedOut: Bool) -> RiskKind? {
        let asked = question.firstIndex(of: "?").map { String(question[...$0]) } ?? question
        guard let kind = RiskClassifier.classify(label: asked), kind != .general else { return nil }
        if timedOut || reply == nil { return kind }
        guard let reply, !Safety.isYes(reply) else { return nil }
        let refusal = #"(?i)^\s*(no|nope|nah|don'?t|do not|never|stop|cancel|skip|not now|leave it|keep it|nahi|nahin|mat)\b"#
        return reply.range(of: refusal, options: .regularExpression) != nil ? kind : nil
    }

    /// A timeout's safe default, delivered as the answer, always marked as Clinqy's own (QuestionPolicy.isTimeoutDefault
    /// recognises the "[No reply after " prefix): never filled into a form, remembered, or read as the user's choice.
    static func timeoutReply(_ fallback: String?) -> String? {
        guard let fallback else { return nil }
        if fallback.hasPrefix(timeoutPrefix) || fallback.hasPrefix("[Skipped by the user] ") { return fallback }
        return timeoutPrefix + "the question timed out; safe default: " + fallback + "] Skip this step: don't do anything irreversible for it. "
            + "Carry on with work that doesn't need the answer, or stop and report what is still needed."
    }
    static let timeoutPrefix = "[No reply after "

    /// The option a wrapped timeout default picked ("Stop this task"), or nil.
    static func defaultOption(_ reply: String?) -> String? {
        guard let reply, reply.hasPrefix(timeoutPrefix), let start = reply.range(of: "safe default: "),
              let end = reply.range(of: "] ", range: start.upperBound..<reply.endIndex) else { return nil }
        return String(reply[start.upperBound..<end.lowerBound])
    }
}

/// How much Clinqy asks. Config key AUTONOMY; the default asks only before irreversible actions.
enum Autonomy: String, CaseIterable {
    /// Ask only before paying/buying/booking/transferring, permanent delete, sending to someone, public posting.
    case irreversible
    /// Show the plan once at the start; after the user approves it, only money still needs a yes.
    case plan
    /// No confirmations on sites and apps the user trusts (ALLOWED_ORIGINS / ALLOWED_APPS or an "always" answer).
    case trusted

    static func parse(_ raw: String?) -> Autonomy {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "plan", "once", "ask once", "ask_once": return .plan
        case "trusted", "trust", "trusted_sites": return .trusted
        default: return .irreversible
        }
    }

    /// Words in one request that ask for the plan level for that task ("show me the plan first").
    static func requestsPlan(_ request: String) -> Bool {
        request.range(of: #"(?i)\b((show|tell|give|send) me (the|your|a) plan (first|before)|plan (it )?first|(run|check) (the|your) plan (by|with) me|approve the plan (first|before)|ask (me )?once (at the start|first|before (you )?start(ing)?))\b"#,
                      options: .regularExpression) != nil
    }

    var title: String {
        switch self {
        case .irreversible: return "Ask before anything irreversible"
        case .plan: return "Ask once at the start"
        case .trusted: return "Don't ask on trusted sites and apps"
        }
    }
}

/// Words in one request that change the level for that task only.
enum TaskAutonomyOverride: Equatable {
    case noAsk, askAll

    static func parse(_ request: String) -> TaskAutonomyOverride? {
        let r = request.lowercased()
        if r.range(of: #"\b(ask (me )?(before|first) (anything|everything|each|every|any)|ask before (doing|you do) anything|check with me (before|first)|confirm (everything|each step|every step|with me before))\b"#,
                   options: .regularExpression) != nil { return .askAll }
        if r.range(of: #"\b(don['’]?t|do not|no need to|never) (ask|confirm|check with) (me|anything)?|without (asking|confirming|checking with me)|no (confirmations?|questions)\b"#,
                   options: .regularExpression) != nil { return .noAsk }
        return nil
    }
}

enum AskingPolicy {
    struct Situation {
        var kind: RiskKind
        var autonomy: Autonomy = .irreversible
        var override: TaskAutonomyOverride?
        /// The request names this exact action (PreAuthorization.covers).
        var preauthorized = false
        /// The request said not to do it ("don't submit").
        var negated = false
        /// A stored "Yes, always on <site/app>" for this kind of action.
        var alwaysAllowedKind = false
        /// A stored rule for this site/app of any kind, or ALLOWED_ORIGINS / ALLOWED_APPS.
        var trustedScope = false
        /// plan level: the user approved the plan shown at the start.
        var planApproved = false
    }

    /// True when the user must say yes first.
    static func shouldAsk(_ s: Situation) -> Bool {
        if s.negated { return true }
        if s.override == .askAll { return true }
        if s.preauthorized || s.alwaysAllowedKind { return false }
        if s.kind == .general { return false }
        switch s.autonomy {
        case .trusted where s.trustedScope: return false
        case .plan where s.planApproved: return s.kind.involvesMoney
        default: break
        }
        if s.override == .noAsk, s.kind == .formSubmit { return false }
        return true
    }

    /// The confirm question's options. An "always" option is offered only with a site or app to remember it for.
    static func confirmOptions(scopeName: String?) -> [String] {
        guard let scopeName, !scopeName.isEmpty else { return ["Yes, go ahead", "No"] }
        return ["Yes, go ahead", alwaysOption(scopeName), "No"]
    }

    static func alwaysOption(_ scopeName: String) -> String { "Yes, always on \(scopeName)" }

    static func isAlways(_ reply: String?) -> Bool {
        guard let reply else { return false }
        return reply.range(of: #"(?i)^\s*yes,?\s+always\b"#, options: .regularExpression) != nil
    }

    /// Who/what a rule applies to: a website's origin (scheme-agnostic host, plus the port when it isn't the default
    /// 80/443: "127.0.0.1:63447" and "127.0.0.1:64524" are different services, "example.com:443" is "example.com"),
    /// or an app.
    static func scope(url: String?) -> String? {
        guard let url, let origin = hostPort(of: url) else { return nil }
        return origin.port.map { origin.host + ":" + String($0) } ?? origin.host
    }

    static func scope(app: String?) -> String? {
        guard let app = app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else { return nil }
        return "app:" + app.lowercased()
    }

    static func host(of raw: String) -> String? { hostPort(of: raw)?.host }

    /// Host (without "www.", IPv6 literals kept in brackets) and port of a URL or of a stored "host[:port]" scope.
    /// The port is nil when absent or the default 80/443, whatever the scheme.
    static func hostPort(of raw: String) -> (host: String, port: Int?)? {
        var h = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) } else if h.hasPrefix("about:") || h.hasPrefix("chrome:") { return nil }
        if let end = h.firstIndex(where: { "/?#".contains($0) }) { h = String(h[..<end]) }
        if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        var port: Int?
        if h.hasPrefix("["), let close = h.firstIndex(of: "]") {
            let rest = h[h.index(after: close)...]
            if rest.hasPrefix(":") { port = Int(rest.dropFirst()) }
            h = String(h[...close])
        } else if let colon = h.firstIndex(of: ":") {
            port = Int(h[h.index(after: colon)...])
            h = String(h[..<colon])
        }
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        guard !h.isEmpty else { return nil }
        if port == 80 || port == 443 { port = nil }
        return (h, port)
    }

    /// This Mac or the local network: localhost, loopback, private and link-local addresses, ".local" names. Every
    /// port there is a separate service, so a rule never carries from one port to another.
    static func isLocalHost(_ raw: String) -> Bool {
        let h = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h == "0.0.0.0" || h == "::1" || h == "::" { return true }
        if h.contains(":") {   // IPv6: unique-local fc00::/7, link-local fe80::/10, IPv4-mapped
            if h.hasPrefix("::ffff:") { return isLocalHost(String(h.dropFirst(7))) }
            return h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb")
        }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let n = parts.compactMap { Int($0) }
        guard n.count == 4, n.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (n[0], n[1]) {
        case (127, _), (10, _), (0, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true   // carrier-grade NAT / Tailscale
        default: return false
        }
    }

    /// The host-only scope an older rule (saved before rules kept the port) was stored under, when it still applies
    /// to `scope`: only a public site's non-default port. Never for local/private hosts, where each port is a
    /// different service, and never for app scopes.
    static func legacyScope(_ scope: String) -> String? {
        guard !scope.hasPrefix("app:"), let origin = hostPort(of: scope), origin.port != nil, !isLocalHost(origin.host) else { return nil }
        return origin.host
    }

    /// ALLOWED_ORIGINS against a rule scope: a pattern with a port matches only that port; a pattern without one
    /// matches the host on any port (the user typed it into Settings themselves).
    static func scopeMatches(_ scope: String, pattern raw: String) -> Bool {
        guard let origin = hostPort(of: scope) else { return false }
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pattern.contains("*"), let wanted = hostPort(of: pattern), wanted.port != nil {
            return wanted.port == origin.port && hostMatches(origin.host, pattern: wanted.host)
        }
        return hostMatches(origin.host, pattern: pattern)
    }

    /// True when `host` is `pattern` or a subdomain of it; "*" wildcards match any run of characters.
    static func hostMatches(_ host: String, pattern raw: String) -> Bool {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !pattern.isEmpty else { return false }
        let h = host.lowercased()
        if pattern.contains("*") {
            let regex = "^" + pattern.split(separator: "*", omittingEmptySubsequences: false)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*") + "$"
            return h.range(of: regex, options: .regularExpression) != nil
        }
        let bare = Self.host(of: pattern) ?? pattern
        return h == bare || h.hasSuffix("." + bare)
    }

    /// A comma/space separated config list.
    static func list(_ raw: String?) -> [String] {
        (raw ?? "").split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// Plan level, enforced by Clinqy rather than left to the prompt: until the user approves the plan, only steps that
/// look (read, look, snapshot, verify, wait, scroll, ask…) and opening the starting page may run. The first step that
/// could change anything makes Clinqy show the plan itself and wait; no reply in time means Stop, never approval.
enum PlanGate {
    enum Decision: Equatable { case pending, approved, stopped }

    static let options = ["Go ahead", "Change it", "Stop"]

    /// Actions that never change anything.
    static let readOnlyKinds: Set<String> = [
        "read", "look", "snap", "snapshot", "verify", "wait", "recall", "think", "plan", "capabilities", "extract", "images",
        "image", "scroll", "hover", "ask", "show", "point", "mark", "dictionary", "assert", "collect",
    ]

    static func applies(autonomy: Autonomy, override: TaskAutonomyOverride?, dryRun: Bool) -> Bool {
        autonomy == .plan && override != .noAsk && !dryRun
    }

    /// True when `action` needs the approved plan first. `navigations` is how many open_url steps already ran before
    /// approval: opening the starting page is free, further navigation waits for the plan.
    static func needsApproval(_ action: [String: Any], navigations: Int) -> Bool {
        let kind = (action["do"] as? String ?? "").lowercased()
        let op = (action["op"] as? String ?? "").lowercased()
        if readOnlyKinds.contains(kind) { return false }
        if kind == "open_url" || kind == "open_app" { return navigations >= 1 }
        if kind == "tab" { return !["list", "look", "read", "switch"].contains(op) }
        if kind == "application" { return !["find", "check", "list", "show"].contains(op) }
        if (kind == "pdf" || kind == "media") && op == "info" { return false }   // ActionContract.readsOnly
        return true
    }

    /// The question Clinqy asks itself: the model's plan (its checklist) or else the request.
    static func question(request: String, steps: [String]) -> String {
        let plan = steps.isEmpty ? "Do what you asked: “" + String(request.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) + "”"
            : steps.prefix(12).enumerated().map { "\($0.offset + 1). " + String($0.element.prefix(120)) }.joined(separator: "\n")
        return "Here's my plan before I change anything:\n" + plan + "\nI'll still ask before paying. Go ahead?"
    }

    enum Reply: Equatable { case approve, change(String?), stop }

    /// What the answer means. No reply, a timeout default or Stop is Stop; "Change it" asks for the change.
    static func interpret(_ reply: String?, timedOut: Bool) -> Reply {
        guard let reply, !timedOut else { return .stop }
        let r = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isEmpty || r.range(of: #"(?i)^(stop|cancel|no|nope|don'?t|do not)\b"#, options: .regularExpression) != nil { return .stop }
        if r.lowercased() == "go ahead" || Safety.isYes(r) { return .approve }
        if r.range(of: #"(?i)^change( it| something)?\.?$"#, options: .regularExpression) != nil { return .change(nil) }
        return .change(r)
    }

    static let stoppedRefusal = "NOT RUN: the user didn't approve the plan (Stop, or no reply in time), so nothing may be changed. "
        + "Don't try again or ask again: finish now with done:true and say the task was stopped before any change."
    static func changeRefusal(_ note: String) -> String {
        "NOT RUN: the user wants the plan changed: “\(note)”. Revise the plan to follow it (send a plan action); Clinqy shows the revised plan before any input."
    }
}

/// Consequential steps the user declined in this run (No, or no reply in time). A later attempt at the same step is
/// refused without asking again, and it no longer counts as unfinished work: the run finishes and reports it.
struct DeclinedActions {
    struct Entry: Equatable {
        var kind: RiskKind
        /// The control's label ("Pay now"), or the kind's own word for a declined question.
        var label: String
        /// Rule scope (origin "host[:port]" or "app:name"); "" when unknown.
        var scope: String
        var timedOut: Bool
    }
    private(set) var entries: [Entry] = []
    var isEmpty: Bool { entries.isEmpty }

    mutating func record(kind: RiskKind, label: String, scope: String?, timedOut: Bool) {
        let entry = Entry(kind: kind, label: String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)),
                          scope: (scope ?? "").lowercased(), timedOut: timedOut)
        if !entries.contains(where: { $0.kind == entry.kind && $0.scope == entry.scope && $0.label.lowercased() == entry.label.lowercased() }) {
            entries.append(entry)
        }
    }

    /// A later yes to that kind (the user changed their mind when asked in words) lifts the refusal.
    mutating func clear(kinds: Set<RiskKind>) { entries.removeAll { kinds.contains($0.kind) } }

    /// The earlier refusal that covers this attempt: same kind on the same site/app, and the same thing — labels
    /// naming different objects ("Delete account" vs "Delete message") are different steps; a generic label
    /// ("Pay now", "Pay ₹500") is the same payment.
    func matching(kind: RiskKind, label: String, scope: String?) -> Entry? {
        let scope = (scope ?? "").lowercased()
        let objects = Set(PreAuthorization.objects(label: label, verbs: RiskClassifier.verbs(label: label, kind: kind)))
        return entries.first { e in
            guard e.kind == kind, e.scope.isEmpty || scope.isEmpty || e.scope == scope else { return false }
            if e.label.lowercased() == label.lowercased() { return true }
            let theirs = Set(PreAuthorization.objects(label: e.label, verbs: RiskClassifier.verbs(label: e.label, kind: e.kind)))
            return objects.isEmpty || theirs.isEmpty || !objects.isDisjoint(with: theirs)
        }
    }

    static func refusal(_ e: Entry) -> String {
        "NOT RUN: the user already " + (e.timedOut ? "didn't approve (no reply in time) " : "declined ") + "“" + e.label
            + "” in this run. Don't try it again or ask again: leave it undone, finish with done:true and report it as skipped by the user."
    }

    /// Whether an open outcome is the declined step itself ("Pay for the order", "Click Pay now", or the generic
    /// "Click primary button after approval" that waited on that very approval): resolved as skipped by the user.
    func resolves(_ title: String) -> Entry? {
        let t = title.lowercased()
        if ChecklistResolution.isApprovalGatedAction(title), let last = entries.last { return last }
        return entries.first { e in
            if RiskClassifier.classify(label: title) == e.kind { return true }
            if !e.label.isEmpty, t.contains(e.label.lowercased()) { return true }
            let verbs = RiskClassifier.verbs(label: e.label, kind: e.kind)
            let words = PreAuthorization.words(title)
            return verbs.contains { v in words.contains { PreAuthorization.inflects($0, v) } }
        }
    }

    /// One line for the result, e.g. "Skipped by you: “Pay now”".
    var summary: String {
        entries.isEmpty ? "" : "Skipped by you: " + entries.map { "“" + $0.label + "”" }.joined(separator: ", ")
    }
}

/// Checklist steps that the user's answers settle: an "ask the user …" step is done once that question was answered,
/// and a step the user declined (or one that only waited on that approval) is skipped by the user. Pure, unit tested.
enum ChecklistResolution {
    enum State: Equatable { case open, answered(String), skipped(String) }
    struct Answer: Equatable { let question: String; let reply: String }

    private static let askLead = #"(?i)^\s*(?:\d+[.)]\s*)?(?:then\s+|and\s+)?(?:ask|check\s+with|confirm\s+with|get|request|wait\s+for|obtain)\b"#
    private static let askWho = #"(?i)\b(?:the\s+)?(?:user|me|you|them|customer|owner)(?:'s)?\b|\b(?:approval|confirmation|answer|permission|go-ahead|ok)\b"#
    private static let filler: Set<String> = ["ask", "asks", "asking", "check", "confirm", "with", "get", "request", "wait", "for", "obtain",
        "the", "a", "an", "user", "user's", "users", "me", "you", "them", "if", "whether", "is", "are", "it", "its", "ok", "okay",
        "fine", "good", "approve", "approval", "approves", "confirmation", "answer", "permission", "about", "to", "and", "then",
        "of", "on", "this", "that", "they", "be", "should", "can", "do", "does", "i", "my", "your", "go-ahead", "or", "not", "like", "likes"]

    /// "Ask user if blue design is OK", "Confirm with the user before submitting", "Get the user's approval".
    static func isAskStep(_ title: String) -> Bool {
        title.range(of: askLead, options: .regularExpression) != nil && title.range(of: askWho, options: .regularExpression) != nil
    }

    /// A click/press/submit step that waits on an approval ("Click primary button after approval", "Press the main
    /// button once confirmed"). When the user declines that approval, the step is skipped with it.
    static func isApprovalGatedAction(_ title: String) -> Bool {
        let t = title.lowercased()
        guard t.range(of: #"\b(click|press|tap|hit|submit|select)\b"#, options: .regularExpression) != nil else { return false }
        return t.range(of: #"\b(after|once|when|if)\s+(the\s+)?(user\s+|you\s+|i\s+)?(approv\w*|confirm\w*|agree\w*|ok\w*|consent\w*|says?\s+yes)"#, options: .regularExpression) != nil
            || t.range(of: #"\b(primary|main|final)\s+(call[- ]to[- ]action\s+)?(button|action|cta)\b"#, options: .regularExpression) != nil
    }

    private static func content(_ text: String) -> Set<String> {
        Set(PreAuthorization.words(text).filter { $0 != "," && !filler.contains($0) }.map { $0.count > 4 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }

    /// Whether this answered question settles that ask step. A plan listing (numbered steps) never does: approving a
    /// plan is not answering the questions it says it will ask.
    static func answers(step: String, question: String) -> Bool {
        guard isAskStep(step) else { return false }
        let numbered = question.components(separatedBy: "\n").filter { $0.range(of: #"^\s*\d+[.)]\s"#, options: .regularExpression) != nil }
        if numbered.count >= 2 { return false }
        let wanted = content(step)
        guard !wanted.isEmpty else { return true }   // "Ask the user for approval": any answered question
        let asked = content(question)
        let overlap = wanted.intersection(asked).count
        return overlap >= max(1, (wanted.count + 1) / 2)
    }

    /// Each open step's state after the run's answered questions and declined steps.
    static func resolve(_ titles: [String], answers: [Answer], declined: DeclinedActions) -> [State] {
        titles.map { title in
            if let answer = answers.last(where: { Self.answers(step: title, question: $0.question) }) {
                return .answered("Answered by you: " + String(answer.reply.prefix(80)))
            }
            if !declined.isEmpty, declined.resolves(title) != nil { return .skipped(declined.summary) }
            return .open
        }
    }
}

/// "Yes, always on github.com", "Always continue in foreground for Numbers": the user's standing answers, stored as
/// `<kind>|<scope>` lines in ~/.config/clinqy/always-allow.json. A write failure is reported, never ignored.
struct AlwaysAllowStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/clinqy/always-allow.json")
    static let foreground = "foreground"

    let url: URL
    init(url: URL = AlwaysAllowStore.defaultURL) { self.url = url }

    static func key(_ kind: String, _ scope: String) -> String { kind + "|" + scope.lowercased() }

    func entries() -> Set<String> {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    /// Scopes a rule for `scope` may be stored under: the scope itself, plus the host-only form older rules used
    /// for a public site (AskingPolicy.legacyScope; never for local services on another port).
    static func lookupScopes(_ scope: String) -> [String] {
        [scope.lowercased()] + (AskingPolicy.legacyScope(scope.lowercased()).map { [$0] } ?? [])
    }

    func allows(_ kind: String, scope: String?) -> Bool {
        guard let scope else { return false }
        let all = entries()
        return Self.lookupScopes(scope).contains { all.contains(Self.key(kind, $0)) }
    }

    /// Any standing confirmation rule for this site or app (trusted level treats the whole scope as trusted). Only
    /// rules for consequential kinds count: "work in my open tab" or "continue in foreground" never imply paying.
    func hasAnyRule(scope: String?) -> Bool {
        guard let scope else { return false }
        let all = entries()
        return Self.lookupScopes(scope).contains { s in
            let suffix = "|" + s
            return all.contains { $0.hasSuffix(suffix) && RiskKind(rawValue: String($0.dropLast(suffix.count))) != nil }
        }
    }

    @discardableResult
    func add(_ kind: String, scope: String) -> Bool {
        var all = entries()
        all.insert(Self.key(kind, scope))
        guard let data = try? JSONEncoder().encode(all.sorted()) else { return false }
        return StoreFile.write(data, to: url) == nil
    }

    @discardableResult
    func remove(_ kind: String, scope: String) -> Bool {
        var all = entries()
        guard all.remove(Self.key(kind, scope)) != nil else { return true }
        guard let data = try? JSONEncoder().encode(all.sorted()) else { return false }
        return StoreFile.write(data, to: url) == nil
    }
}

/// Sites and apps Clinqy never operates: banking, password managers, Keychain and macOS privacy prompts.
/// BLOCKED_ORIGINS / BLOCKED_APPS replace the defaults ("default" keeps them, "none" empties the list);
/// a host in ALLOWED_ORIGINS (or app in ALLOWED_APPS) is never blocked.
enum AccessBlocklist {
    static let defaultOrigins = [
        "*netbanking*", "*onlinebanking*", "*ebanking*", "*.bank", "*bank.com", "*bank.co.in", "*bank.in", "*bank.co.uk",
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "capitalone.com", "usbank.com", "pnc.com",
        "schwab.com", "fidelity.com", "vanguard.com", "hsbc.com", "hsbc.co.uk", "hsbc.co.in", "barclays.co.uk", "santander.co.uk",
        "lloydsbank.com", "natwest.com", "monzo.com", "revolut.com", "onlinesbi.sbi", "sbi.co.in", "kotak.com",
        "paypal.com", "1password.com", "my.1password.com", "vault.bitwarden.com", "lastpass.com",
    ]
    static let defaultApps = ["1Password", "1Password 7", "Bitwarden", "LastPass", "Dashlane", "Keychain Access", "Passwords", "SecurityAgent"]
    static let defaultBundleIDs = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
                                   "com.apple.Passwords", "com.apple.SecurityAgent"]

    private static func resolved(_ raw: String?, defaults: [String]) -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return defaults }
        let items = AskingPolicy.list(raw)
        if items.contains(where: { ["none", "off", "0"].contains($0.lowercased()) }) { return [] }
        return items.flatMap { $0.lowercased() == "default" ? defaults : [$0] }
    }

    /// Why Clinqy won't act on `url`, or nil.
    static func originRefusal(url: String, blocked: String?, allowed: String?) -> String? {
        if url.lowercased().hasPrefix("x-apple.systempreferences:"), url.lowercased().contains("privacy") || url.lowercased().contains("security") {
            return privacyMessage
        }
        guard let host = AskingPolicy.host(of: url) else { return nil }
        if AskingPolicy.list(allowed).contains(where: { AskingPolicy.hostMatches(host, pattern: $0) }) { return nil }
        guard let rule = resolved(blocked, defaults: defaultOrigins).first(where: { AskingPolicy.hostMatches(host, pattern: $0) }) else { return nil }
        return "NOT RUN: \(host) is on Clinqy's blocked list (\(rule)) — banking and password sites are never operated. Do this part yourself, or remove it from BLOCKED_ORIGINS in Settings if you really want Clinqy here."
    }

    /// Why Clinqy won't act in this app (or this System Settings pane), or nil.
    static func appRefusal(name: String?, bundleID: String?, windowTitle: String?, blocked: String?, allowed: String?) -> String? {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = (bundleID ?? "").lowercased()
        if ["system settings", "system preferences"].contains(n) || b == "com.apple.systempreferences" {
            if let title = windowTitle, title.range(of: #"(?i)\b(privacy|security)\b"#, options: .regularExpression) != nil { return privacyMessage }
        }
        if n == "usernotificationcenter" || b == "com.apple.usernotificationcenter" || b == "com.apple.tccd" { return privacyMessage }
        guard !n.isEmpty || !b.isEmpty else { return nil }
        if AskingPolicy.list(allowed).contains(where: { $0.lowercased() == n || $0.lowercased() == b }) { return nil }
        let names = resolved(blocked, defaults: defaultApps + defaultBundleIDs).map { $0.lowercased() }
        guard let rule = names.first(where: { $0 == n || $0 == b }) else { return nil }
        return "NOT RUN: \(name ?? bundleID ?? rule) is on Clinqy's blocked list — password managers and Keychain are never operated. Do this part yourself, or remove it from BLOCKED_APPS in Settings."
    }

    static let privacyMessage = "NOT RUN: macOS Privacy & Security settings and permission prompts are never operated by Clinqy. Approve or change them yourself."
}

/// While the model waits on an ask, work in the same batch that cannot depend on the answer still runs.
enum AskBatching {
    /// An ask whose later batch steps may run before it: a request for details (not a go-ahead, not private input).
    static func isDeferrable(_ action: [String: Any], isConfirmation: (String) -> Bool) -> Bool {
        guard (action["do"] as? String)?.lowercased() == "ask", action["sensitive"] as? Bool != true,
              let question = action["question"] as? String, !question.isEmpty, !isConfirmation(question) else { return false }
        let options = (action["options"] as? [String] ?? []).map { $0.lowercased() }
        return !options.contains(where: { $0.hasPrefix("yes") || $0 == "no" || $0 == "submit" || $0.hasPrefix("go ahead") })
    }

    /// Moves each deferrable ask past the independent steps after it, stopping before the first step that may commit
    /// something (it could be what the question is about) or another ask. The relative order of everything else stays.
    static func reorder(_ actions: [[String: Any]], isConfirmation: (String) -> Bool,
                        commits: ([String: Any]) -> Bool) -> [[String: Any]] {
        var result = actions
        var i = 0
        while i < result.count {
            guard isDeferrable(result[i], isConfirmation: isConfirmation) else { i += 1; continue }
            var j = i + 1
            while j < result.count, (result[j]["do"] as? String)?.lowercased() != "ask", !commits(result[j]) { j += 1 }
            if j > i + 1 {
                let ask = result.remove(at: i)
                result.insert(ask, at: j - 1)
                i = j
            } else { i += 1 }
        }
        return result
    }
}

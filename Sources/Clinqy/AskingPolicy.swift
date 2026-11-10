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
        case .message: return ["send", "reply", "message", "email", "invite", "forward", "dm"]
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

    /// Who/what a rule applies to: a website's bare host or an app.
    static func scope(url: String?) -> String? {
        guard let url, let host = host(of: url), !host.isEmpty else { return nil }
        return host
    }

    static func scope(app: String?) -> String? {
        guard let app = app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else { return nil }
        return "app:" + app.lowercased()
    }

    static func host(of raw: String) -> String? {
        var h = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) } else if h.hasPrefix("about:") || h.hasPrefix("chrome:") { return nil }
        if let end = h.firstIndex(where: { "/?#".contains($0) }) { h = String(h[..<end]) }
        if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h.isEmpty ? nil : h
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

    func allows(_ kind: String, scope: String?) -> Bool {
        guard let scope else { return false }
        return entries().contains(Self.key(kind, scope))
    }

    /// Any standing confirmation rule for this site or app (trusted level treats the whole scope as trusted). Only
    /// rules for consequential kinds count: "work in my open tab" or "continue in foreground" never imply paying.
    func hasAnyRule(scope: String?) -> Bool {
        guard let scope else { return false }
        let suffix = "|" + scope.lowercased()
        return entries().contains { $0.hasSuffix(suffix) && RiskKind(rawValue: String($0.dropLast(suffix.count))) != nil }
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

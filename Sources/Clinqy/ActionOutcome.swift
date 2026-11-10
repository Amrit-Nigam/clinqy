import Foundation

/// Input delivery and application state are independent facts. A dispatched click alone is never a checkpoint.
struct ActionOutcome: Codable, Equatable {
    enum Delivery: String, Codable { case notAttempted, delivered, unknown }
    enum Status: String, Codable { case confirmed, unverified, failed, refused }
    let delivery: Delivery
    let status: Status

    static let confirmed = ActionOutcome(delivery: .delivered, status: .confirmed)
    static let unverified = ActionOutcome(delivery: .delivered, status: .unverified)
    static let uncertain = ActionOutcome(delivery: .unknown, status: .unverified)
    static let failed = ActionOutcome(delivery: .notAttempted, status: .failed)
    static let refused = ActionOutcome(delivery: .notAttempted, status: .refused)
    var isConfirmed: Bool { status == .confirmed }
    var needsVerification: Bool { status == .unverified }
    /// Sent without error: confirmed, or delivered with its effect not (yet) observed. Unknown delivery, failures and
    /// refusals are not delivered.
    var delivered: Bool { isConfirmed || (status == .unverified && delivery == .delivered) }

    /// The browser state signature includes target state, URL, global text hash and focus. Only target state or
    /// navigation is evidence of this interaction; unrelated page text/focus changes cannot confirm a click.
    static func browserClick(before: String?, after: String?, consequential: Bool) -> ActionOutcome {
        guard !consequential, let before, let after,
              let old = try? JSONSerialization.jsonObject(with: Data(before.utf8)) as? [Any],
              let new = try? JSONSerialization.jsonObject(with: Data(after.utf8)) as? [Any],
              old.count >= 7, new.count >= 7 else { return .unverified }
        let oldTarget = Array(old.prefix(7)) as NSArray
        let newTarget = Array(new.prefix(7)) as NSArray
        return oldTarget.isEqual(newTarget) ? .unverified : .confirmed
    }
}

/// Fresh listings may identify a target uniquely, but proximity must never break an identity tie.
enum TargetResolution {
    struct Candidate { let index: Int; let identity: String }
    static func unique(index: Int, identity: String, candidates: [Candidate], stableIndex: Bool) -> Int? {
        if stableIndex, candidates.contains(where: { $0.index == index && $0.identity == identity }) { return index }
        let matches = candidates.filter { $0.identity == identity }
        return matches.count == 1 ? matches[0].index : nil
    }
}

/// A postcondition must demonstrate the pending operation, rather than merely describe existing UI.
enum VerificationEvidence {
    /// Only title and visible DOM readback belong to this channel, never AX/OCR from another surface.
    static func browserText(_ read: [String: Any]) -> String {
        (read["title"] as? String ?? "") + "\n" + (read["text"] as? String ?? "")
    }

    static func changedValue(before: String?, after: String?, expected: String, sameTarget: Bool, fieldInput: Bool) -> Bool {
        guard fieldInput, sameTarget, let before, let after else { return false }
        return before != expected && after == expected
    }

    static func newText(_ expected: String, before: String?, after: String?) -> Bool {
        guard !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let before, let after else { return false }
        return !appears(expected, in: before) && appears(expected, in: after)
    }

    /// Text evidence for a pending input: the text is present now and either new, appearing more often than before
    /// ("Item added" shown a second time), or reported by the input's own effect receipt as text the page added.
    static func textEvidence(_ expected: String, before: String?, after: String?, added: String? = nil) -> Bool {
        guard !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let added, appears(expected, in: added) { return true }
        guard let before, let after else { return false }
        return occurrences(expected, in: after) > occurrences(expected, in: before)
    }

    /// Case-insensitive match that does not count a word fragment: "Paid" is not on a page that only says "unpaid",
    /// and "Order" is not "Orders". Punctuation and symbols at the edges of `expected` still match as written.
    static func appears(_ expected: String, in haystack: String) -> Bool { occurrences(expected, in: haystack, limit: 1) > 0 }

    /// How many separate, whole-word occurrences of `expected` are in `haystack` (same matching rules as `appears`).
    static func occurrences(_ expected: String, in haystack: String, limit: Int = .max) -> Int {
        // Code editors and rich pages use non-breaking spaces and uneven runs of whitespace for ordinary spaces.
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{00A0}", with: " ").split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        let needle = normalized(expected.trimmingCharacters(in: .whitespacesAndNewlines))
        let haystack = normalized(haystack)
        guard !needle.isEmpty else { return 0 }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        let wantsLeading = needle.first.map(isWord) ?? false, wantsTrailing = needle.last.map(isWord) ?? false
        var from = haystack.startIndex, count = 0
        while count < limit, let range = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: from..<haystack.endIndex) {
            let leftOK = !wantsLeading || range.lowerBound == haystack.startIndex || !isWord(haystack[haystack.index(before: range.lowerBound)])
            let rightOK = !wantsTrailing || range.upperBound == haystack.endIndex || !isWord(haystack[range.upperBound])
            if leftOK && rightOK {
                count += 1
                from = range.upperBound
            } else {
                from = haystack.index(after: range.lowerBound)
            }
        }
        return count
    }
}

/// Field readback after typing. Sites reformat what was typed (trim, collapse spaces, "+91 98450 12345" for
/// "9845012345", upper-case codes); only a real difference is a mismatch.
enum FieldReadback {
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
    static func digits(_ text: String) -> String { String(text.filter(\.isNumber)) }
    /// Phone/number-like input: digits with only separators (spaces, + - ( ) . , /).
    static func isNumberish(_ text: String) -> Bool {
        let digitCount = text.filter(\.isNumber).count
        return digitCount >= 3 && text.allSatisfy { $0.isNumber || " +-().,/".contains($0) || $0.isWhitespace }
    }
    static func matches(expected: String, actual: String?) -> Bool {
        guard let actual else { return false }
        if actual == expected { return true }
        let e = normalized(expected), a = normalized(actual)
        if e == a { return true }
        guard isNumberish(expected), isNumberish(actual) else { return false }
        let de = digits(expected), da = digits(actual)
        // A country code (at most 3 digits) the field prefixed is formatting, not a different number.
        return de == da || (da.hasSuffix(de) && da.count - de.count <= 3 && actual.contains("+"))
    }
}

/// What the page did in response to an input, from the extension's mutation receipt armed before the input.
struct EffectReceipt: Equatable {
    var urlChanged = false
    var targetStateChanged = false
    var targetRemoved = false
    var dialogOpened = false
    var focusChanged = false
    /// Focus moved into content that appeared after the input (a newly rendered panel or field).
    var focusIntoNew = false
    var addedText = ""
    var removedText = ""
    var mutationCount = 0
    /// Elements were added or removed (page ids may now point elsewhere: list the page again before the next id).
    var structural = false
    /// A watched frame stopped answering (navigated or replaced): what it did is unknown, not "nothing".
    var unreadable = false

    init(urlChanged: Bool = false, targetStateChanged: Bool = false, targetRemoved: Bool = false, dialogOpened: Bool = false,
         focusChanged: Bool = false, focusIntoNew: Bool = false, addedText: String = "", removedText: String = "", mutationCount: Int = 0) {
        self.focusIntoNew = focusIntoNew
        self.urlChanged = urlChanged; self.targetStateChanged = targetStateChanged; self.targetRemoved = targetRemoved
        self.dialogOpened = dialogOpened; self.focusChanged = focusChanged; self.addedText = addedText
        self.removedText = removedText; self.mutationCount = mutationCount
    }

    init?(_ reply: [String: Any]?) {
        guard let reply, reply["mutationCount"] != nil || reply["urlChanged"] != nil else { return nil }
        urlChanged = reply["urlChanged"] as? Bool ?? false
        targetStateChanged = reply["targetStateChanged"] as? Bool ?? false
        targetRemoved = reply["targetRemoved"] as? Bool ?? false
        dialogOpened = reply["dialogOpened"] as? Bool ?? false
        focusChanged = reply["focusChanged"] as? Bool ?? false
        focusIntoNew = reply["focusIntoNew"] as? Bool ?? false
        addedText = reply["addedText"] as? String ?? ""
        removedText = reply["removedText"] as? String ?? ""
        mutationCount = (reply["mutationCount"] as? NSNumber)?.intValue ?? 0
        structural = reply["structural"] as? Bool ?? true
        unreadable = reply["unreadable"] as? Bool ?? false
    }

    /// Nothing that could move or replace listed elements happened, so the current page list is still valid.
    var keepsListing: Bool { !urlChanged && !structural && !unreadable && !targetRemoved && !dialogOpened }

    /// Text that carries meaning: at least one letter once relative times are taken out. Pure digit/time churn (a
    /// clock, a counter, "3 seconds ago" → "4 seconds ago") is not attributable.
    static func meaningful(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(
            of: #"(?i)\b(about |over |almost )?(\d+\s*|(a|an|one)\s+)(s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?|d|days?|w|wks?|weeks?|mo|months?|y|yrs?|years?)\b(\s+ago\b)?|\b(just now|moments? ago|updated|edited)\b"#,
            with: " ", options: .regularExpression)
        return stripped.contains(where: \.isLetter)
    }

    private static func segments(_ text: String) -> [String] {
        text.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    /// Text the page added that it did not also remove: a re-render that puts the same text back is not new text.
    var netAddedText: String {
        let gone = Set(Self.segments(removedText))
        return Self.segments(addedText).filter { !gone.contains($0) }.joined(separator: " | ")
    }
    var netRemovedText: String {
        let back = Set(Self.segments(addedText))
        return Self.segments(removedText).filter { !back.contains($0) }.joined(separator: " | ")
    }

    /// An attributable change. The extension only reports text from the target's own container, newly opened
    /// dialogs/alerts/menus; focus merely moving (any click focuses its button) and bare attribute churn (ripples,
    /// hover styles) are not evidence of an effect, but focus landing in content that just appeared is.
    var observedEffect: Bool {
        urlChanged || targetStateChanged || targetRemoved || dialogOpened || focusIntoNew
            || Self.meaningful(netAddedText) || Self.meaningful(netRemovedText)
    }

    /// One line for the action result: what was seen to change.
    var summary: String {
        var parts: [String] = []
        if urlChanged { parts.append("the page URL changed") }
        if dialogOpened { parts.append("a dialog opened") }
        if targetStateChanged { parts.append("the control's state changed") }
        if targetRemoved { parts.append("the control was replaced or removed") }
        if focusIntoNew { parts.append("focus moved into new content") }
        let added = netAddedText, removed = netRemovedText
        if Self.meaningful(added) { parts.append("new text " + String(added.prefix(120)).debugDescription) }
        if Self.meaningful(removed) { parts.append("text gone " + String(removed.prefix(80)).debugDescription) }
        return parts.joined(separator: "; ")
    }
}

/// Inline `expect` evaluation (the argument is validated by ActionContract): true only on observed evidence produced
/// after the action — a URL that changed to (or now contains) the expected one, text that is new / more frequent / in
/// the receipt's net added text, or a normalised field value readback.
extension VerificationEvidence {
    static func expectationMet(kind: String, value: String, beforeURL: String?, afterURL: String?, beforeText: String?,
                               afterText: String?, addedText: String?, fieldValue: String?) -> Bool {
        switch kind {
        case "url":
            guard let afterURL, afterURL != beforeURL else { return false }
            return afterURL == value || afterURL.contains(value)
        case "text":
            return textEvidence(value, before: beforeText, after: afterText, added: addedText)
        case "value":
            return FieldReadback.matches(expected: value, actual: fieldValue)
        default:
            return false
        }
    }
}

/// Which inputs are consequential: their effect may be irreversible or reach other people, so an unobserved effect
/// keeps the verification barrier. Everything else that was delivered continues without one.
enum ConsequentialInput {
    static let scripts: Set<String> = ["shell", "applescript", "email"]
    static func classify(kind: String, keys: String = "", submit: Bool = false, riskyLabel: Bool = false) -> Bool {
        if scripts.contains(kind) { return true }
        if kind == "type", submit { return true }
        if kind == "key" { return riskyKey(keys) }
        if ["click", "double_click", "right_click"].contains(kind) { return riskyLabel }
        return false
    }
    static func riskyKey(_ keys: String) -> Bool {
        let k = keys.lowercased()
        return k.contains("return") || k.contains("enter") || k.contains("delete") || k.contains("backspace") || k == "cmd+s" || k == "command+s"
    }
}

/// How a click's delivery maps to an outcome once its receipt (and any inline expectation) is known.
enum EffectClassification {
    static func click(receipt: EffectReceipt?, consequential: Bool, expectation: Bool?) -> ActionOutcome {
        if expectation == true { return .confirmed }
        if expectation == false || consequential { return .unverified }
        return receipt?.observedEffect == true ? .confirmed : .unverified
    }
}

/// A sheet may report a different AXWindow while still descending from the exact observed parent.
/// Following only parent/window links never admits an unrelated sibling window from the same app.
enum NativeWindowHierarchy {
    static func contains<Node>(_ target: Node, root: Node, parents: (Node) -> [Node], equal: (Node, Node) -> Bool) -> Bool {
        var queue = [target], seen: [Node] = [], index = 0
        while index < queue.count && seen.count < 64 {
            let node = queue[index]; index += 1
            if equal(node, root) { return true }
            if seen.contains(where: { equal($0, node) }) { continue }
            seen.append(node); queue.append(contentsOf: parents(node))
        }
        return false
    }
}
enum TaskCompletionPolicy {
    static func reportsFailure(_ summary: String) -> Bool {
        summary.range(of: #"(?i)^\s*(?:i |we )?(couldn['’]?t|cannot|can['’]?t|was unable to|were unable to|unable to|failed to)\s+(send|attach|finish|complete|deliver|capture|open|submit|save|upload)\b"#, options: .regularExpression) != nil
    }
    static func requestsWriteUp(_ request: String) -> Bool {
        let text = request.components(separatedBy: "\n\nPrevious Telegram task").first ?? request
        if text.range(of: #"(?is)\b(no|not|don't|do not|without)\b.{0,40}\b(doc|document|write[ -]?up|report)\b"#, options: .regularExpression) != nil { return false }
        return text.range(of: #"(?is)\b(create|make|write|prepare|document|paste|put|add|insert)\b.{0,100}\b(doc|document|report|guide|write[ -]?up)\b"#, options: .regularExpression) != nil
    }
}

/// How a returned or thrown low-level input maps to an outcome. A failure to report is never success, and a Return
/// whose delivery is unknown is never replayed blindly (it is `.uncertain`, which holds the repeat barrier).
enum InputDelivery {
    static func pageScroll(error: Error?) -> ActionOutcome { error == nil ? .confirmed : .failed }
    static func returnPress(delivered: Bool) -> ActionOutcome { delivered ? .unverified : .uncertain }
}

/// Fail closed when visual evidence cannot be attributed to a live action target.
enum VisualEvidencePolicy {
    static func accepts(run: String, observedRun: String?, sameTarget: Bool,
                        observedAt: Date, actionAt: Date) -> Bool {
        observedRun == run && sameTarget && observedAt > actionAt
    }
    static func sameDocument(_ expected: String?, _ observed: String?) -> Bool {
        expected != nil && expected == observed
    }
    static func exhaustedCompletionAttempts(_ attempts: Int) -> Bool { attempts >= 3 }
}

/// An owned popup may publish its ordinary click result in its opener before closing. Verify a
/// new explicit predicate against that opener's own pre-input baseline, never against child text.
enum OwnedOpenerEvidencePolicy {
    static func permitsObservation(kind: String, delivery: ActionOutcome.Delivery, consequential: Bool,
                        sameRun: Bool, sameConnection: Bool, expectedTab: Int?, currentTab: Int?,
                        expectedDocument: String?, currentDocument: String?) -> Bool {
        guard kind == "click", delivery == .delivered, !consequential, sameRun, sameConnection,
              expectedTab != nil, expectedTab == currentTab,
              VisualEvidencePolicy.sameDocument(expectedDocument, currentDocument) else { return false }
        return true
    }
    static func accepts(kind: String, delivery: ActionOutcome.Delivery, consequential: Bool,
                        sameRun: Bool, sameConnection: Bool, expectedTab: Int?, currentTab: Int?,
                        expectedDocument: String?, currentDocument: String?, expected: String,
                        before: String?, after: String?) -> Bool {
        permitsObservation(kind: kind, delivery: delivery, consequential: consequential,
            sameRun: sameRun, sameConnection: sameConnection, expectedTab: expectedTab, currentTab: currentTab,
            expectedDocument: expectedDocument, currentDocument: currentDocument)
            && VerificationEvidence.newText(expected, before: before, after: after)
    }
}

/// Recovery retries observe again; they never replay an action from a rejected response.
enum ObservationRecoveryPolicy {
    static func canRetry(attempts: Int) -> Bool { attempts < 2 }
}

/// User review is a fallback after the same deterministic verifier used by explicit verify actions.
enum AutonomousInspectionPolicy {
    static func verificationAction(_ action: [String: Any], claim: String) -> [String: Any] {
        var inspection = action
        inspection.removeValue(forKey: "user_confirms")
        inspection.removeValue(forKey: "visual")
        if !["text", "url", "value", "path"].contains(where: { inspection[$0] != nil }) {
            inspection["text"] = claim
        }
        inspection["seconds"] = 0
        return inspection
    }
}

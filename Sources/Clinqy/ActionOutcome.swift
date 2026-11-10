import Foundation
import CoreGraphics

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
    /// A tick control (checkbox/radio/switch, including a styled label standing in for a hidden input) is confirmed
    /// only by its own checked state flipping — page text elsewhere is not evidence that the box changed.
    static func tickClick(receipt: EffectReceipt?, expectation: Bool?) -> ActionOutcome {
        if expectation == true { return .confirmed }
        if expectation == false { return .unverified }
        return receipt?.targetStateChanged == true ? .confirmed : .unverified
    }
}

/// Tick controls: checkboxes, radios and switches (web roles and native AX roles). Ticking one is reversible and its
/// checked state is directly readable, so its caption ("I consent to share my details", "Apply discount") never makes
/// the click itself consequential: the click is confirmed by the state flip and the real submit keeps its own barrier.
enum TickControl {
    static func isTick(role: String) -> Bool {
        let r = role.lowercased().replacingOccurrences(of: "ax", with: "", options: .anchored)
        return ["checkbox", "radio", "switch", "menuitemcheckbox", "menuitemradio", "radiobutton", "toggle"].contains(r)
    }
    /// A click on this target keeps the consequential barrier only when it is not a tick control.
    static func consequential(label: String, role: String?, labelIsConsequential: (String) -> Bool) -> Bool {
        if let role, isTick(role: role) { return false }
        return labelIsConsequential(label)
    }
    /// The readback for a tick control is "checked"/"unchecked"; the model may ask for checked/on/true/yes/ticked.
    static func matches(expected: String, actual: String?) -> Bool {
        guard let actual = actual?.lowercased(), actual == "checked" || actual == "unchecked" else { return false }
        let want = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["checked", "on", "true", "yes", "ticked", "selected", "1"].contains(want) { return actual == "checked" }
        if ["unchecked", "off", "false", "no", "unticked", "not checked", "unselected", "0"].contains(want) { return actual == "unchecked" }
        return false
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

/// The final answer must not claim an action succeeded when that action's latest result in this run FAILED
/// ("…and Amrit_Resume_C.pdf uploaded" after "Upload Amrit_Resume_C.pdf ✗ the page didn't take the file").
/// Deterministic: a correction line is appended to the answer; nothing is inferred from the model.
enum FailedClaimGuard {
    struct Attempt: Equatable { var step: String; var failed: Bool }

    /// "Upload X" → (upload, X) · "Click X" → (click, X). Other steps (typing, waits) name values, not outcomes.
    static func subject(of step: String) -> (kind: String, subject: String)? {
        for (prefix, kind) in [("Upload ", "upload"), ("Click ", "click")] where step.hasPrefix(prefix) {
            let subject = step.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "“”\"")))
            if subject.count >= 3, !subject.hasPrefix("at (") { return (kind, subject) }
        }
        return nil
    }

    private static let negation = #"(?i)\b(fail|failed|failing|failure|couldn['’]?t|could not|can['’]?t|cannot|didn['’]?t|did not|not|never|wasn['’]?t|was not|isn['’]?t|unable|no longer|error|unticked|unchecked|blocked|missing|pending|still need|skipped)\b"#
    private static let success = #"(?i)\b(uploaded|attached|added|clicked|ticked|checked|selected|submitted|sent|saved|done|completed|applied)\b"#

    /// Clauses of the answer: sentence ends, commas, semicolons, colons, parentheses and "but"/"and" joints.
    static func clauses(_ text: String) -> [String] {
        text.replacingOccurrences(of: #"(?<=[.!?])\s+|\n|[,;:()]|\s+but\s+|\s+and\s+"#, with: "\u{1F}", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func claims(_ answer: String, kind: String, subject: String, nameless: Bool = true) -> Bool {
        let needle = subject.lowercased()
        for clause in clauses(answer) {
            let lower = clause.lowercased()
            guard lower.range(of: success, options: .regularExpression) != nil, lower.range(of: negation, options: .regularExpression) == nil else { continue }
            if lower.contains(needle) { return true }
            // "resume uploaded", "file attached": an upload claim without the file name.
            if kind == "upload", nameless, lower.range(of: #"\b(uploaded|attached)\b"#, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// The correction to append, or nil when the answer claims nothing that failed.
    static func correction(answer: String, attempts: [Attempt]) -> String? {
        var latest: [String: (kind: String, subject: String, failed: Bool)] = [:]
        var order: [String] = []
        for attempt in attempts {
            guard let (kind, subject) = subject(of: attempt.step) else { continue }
            let key = kind + "\u{1F}" + subject.lowercased()
            if latest[key] == nil { order.append(key) }
            latest[key] = (kind, subject, attempt.failed)
        }
        // A nameless "file attached" may be about another upload that did succeed: then only the file name counts.
        let anyUploadOK = latest.values.contains { $0.kind == "upload" && !$0.failed }
        let wrong = order.compactMap { latest[$0] }.filter { $0.failed && claims(answer, kind: $0.kind, subject: $0.subject, nameless: !anyUploadOK) }
        guard !wrong.isEmpty else { return nil }
        let parts = wrong.map { $0.kind == "upload" ? "the upload of \($0.subject) failed (it is not attached)" : "clicking “\($0.subject)” failed" }
        return "Note: " + parts.joined(separator: "; ") + " in this run."
    }

    /// For a run that ends not-ok: a short "Note: … failed" naming each action whose latest attempt FAILED (a later
    /// successful retry of the same step clears it), even when the answer already says so. nil when nothing failed.
    static func failureNote(attempts: [Attempt]) -> String? {
        var latest: [String: Bool] = [:]
        var order: [String] = []
        // Checks (verify, look, wait, read) aren't actions on the app: their failures are not reported as failed actions.
        let checks = ["Verify", "Look", "Wait", "Read", "Check", "Ask", "Waiting"]
        let attempts = attempts.filter { attempt in !checks.contains { attempt.step.hasPrefix($0 + " ") || attempt.step == $0 } }
        for attempt in attempts {
            let key = subject(of: attempt.step).map { $0.kind + "\u{1F}" + $0.subject.lowercased() } ?? attempt.step
            if latest[key] == nil { order.append(key) }
            latest[key] = attempt.failed
        }
        var parts: [String] = []
        for key in order where latest[key] == true {
            guard let step = attempts.last(where: { (subject(of: $0.step).map { $0.kind + "\u{1F}" + $0.subject.lowercased() } ?? $0.step) == key })?.step else { continue }
            if let (kind, subject) = subject(of: step) {
                parts.append(kind == "upload" ? "the upload of \(subject) failed" : "clicking “\(subject)” failed")
            } else {
                parts.append("“\(step.prefix(60))” failed")
            }
        }
        guard !parts.isEmpty else { return nil }
        return "Note: " + parts.prefix(3).joined(separator: "; ") + (parts.count > 3 ? "; and \(parts.count - 3) more" : "") + "."
    }
}

/// Character formatting toggles (Bold/Italic/Underline/Strikethrough). A toolbar toggle's own state says nothing
/// about the document: formatting is confirmed only by the attributed text of an explicit, verified selection.
enum TextFormatting {
    enum Style: String, Equatable { case bold, italic, underline, strikethrough }
    /// One run of attributes over the selected range, as Accessibility reports it (AXAttributedStringForRange).
    struct Span: Equatable {
        var fontName: String?
        /// Font traits from the font itself (NSFontManager), when the font could be resolved.
        var boldTrait: Bool? = nil
        var italicTrait: Bool? = nil
        var underline = false
        var strikethrough = false
    }

    /// The formatting a toggle control applies, from its label ("Bold", "B — Bold text", "Italic", "Underline").
    static func style(forLabel label: String) -> Style? {
        let l = label.lowercased()
        func has(_ word: String) -> Bool { l.range(of: #"\b"# + word + #"\b"#, options: .regularExpression) != nil }
        if has("bold") { return .bold }
        if has("italic") || has("italics") { return .italic }
        if has("underline") || has("underlined") { return .underline }
        if has("strikethrough") || has("strike through") || has("strike-through") { return .strikethrough }
        return nil
    }

    static func nameImplies(_ style: Style, fontName: String) -> Bool {
        let n = fontName.lowercased()
        switch style {
        case .bold: return ["bold", "black", "heavy", "semibold", "demibold", "extrabold", "ultrabold"].contains { n.contains($0) }
        case .italic: return n.contains("italic") || n.contains("oblique")
        case .underline, .strikethrough: return false
        }
    }

    static func has(_ style: Style, _ span: Span) -> Bool {
        switch style {
        case .bold: return span.boldTrait ?? span.fontName.map { nameImplies(.bold, fontName: $0) } ?? false
        case .italic: return span.italicTrait ?? span.fontName.map { nameImplies(.italic, fontName: $0) } ?? false
        case .underline: return span.underline
        case .strikethrough: return span.strikethrough
        }
    }

    /// Every run of the selected text has (on) or lacks (off) the style. No spans = nothing observed = not confirmed.
    static func confirmed(_ style: Style, on: Bool, spans: [Span]) -> Bool {
        guard !spans.isEmpty else { return false }
        return spans.allSatisfy { has(style, $0) == on }
    }

    /// The range of `target` in the field's text, as UTF-16 offsets (what AXSelectedTextRange uses). Only a unique
    /// occurrence counts; an empty/absent target means "whatever is selected now".
    static func range(of target: String, in text: String) -> NSRange? {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let ns = text as NSString
        let first = ns.range(of: t)
        guard first.location != NSNotFound else { return nil }
        let after = first.location + first.length
        let again = ns.range(of: t, options: [], range: NSRange(location: after, length: ns.length - after))
        return again.location == NSNotFound || first.length == ns.length ? first : nil
    }

    /// The selection that formatting will apply to is verified: non-empty and, when a target was named, exactly it.
    static func selectionVerified(selected: String?, target: String?) -> Bool {
        guard let selected, !selected.isEmpty else { return false }
        guard let target = target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else { return true }
        return selected == target
    }

    /// The menu item title that applies `style` (Format ▸ Font ▸ Bold in TextEdit and most Cocoa text apps).
    static func menuTitle(for style: Style) -> String {
        switch style {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .underline: return "Underline"
        case .strikethrough: return "Strikethrough"
        }
    }

    /// One menu item seen while searching the menu bar: its title, the titles of the menus above it, and whether it is enabled.
    struct MenuCandidate: Equatable {
        var title: String
        var ancestors: [String]
        var enabled: Bool = true
    }

    /// Which menu item applies `style`: an enabled item titled exactly the style, preferring one under a Font,
    /// Format or Style menu. Only a unique choice counts; ambiguity or absence is nil (nothing is pressed).
    static func menuChoice(_ candidates: [MenuCandidate], for style: Style) -> Int? {
        let wanted = menuTitle(for: style).lowercased()
        let titled = candidates.indices.filter {
            candidates[$0].enabled && candidates[$0].title.trimmingCharacters(in: .whitespaces).lowercased() == wanted
        }
        let formatMenus: Set<String> = ["font", "format", "style"]
        let underFormat = titled.filter { candidates[$0].ancestors.contains { formatMenus.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) } }
        if underFormat.count == 1 { return underFormat[0] }
        if underFormat.isEmpty, titled.count == 1 { return titled[0] }
        return nil
    }

    /// The pinned window's document text area, found by walking the window's Accessibility subtree. Visibility,
    /// occlusion and frames play no part (a covered window or a long, scrolled document still has it): the
    /// AXTextArea inside an AXScrollArea wins; a single AXTextArea anywhere is the fallback. Several = nil.
    static func documentTextArea<Node>(in window: Node, role: (Node) -> String, children: (Node) -> [Node],
                                       maxDepth: Int = 30, maxNodes: Int = 4000) -> Node? {
        var queue: [(node: Node, depth: Int, inScroll: Bool)] = [(window, 0, false)]
        var head = 0
        var scrolled: [Node] = [], loose: [Node] = []
        while head < queue.count, head < maxNodes {
            let (node, depth, inScroll) = queue[head]; head += 1
            let r = role(node)
            if r == "AXTextArea" {
                if inScroll { scrolled.append(node) } else { loose.append(node) }
                continue   // a text area's children are its text runs, never another document
            }
            guard depth < maxDepth else { continue }
            let scroll = inScroll || r == "AXScrollArea"
            queue.append(contentsOf: children(node).map { ($0, depth + 1, scroll) })
        }
        if scrolled.count == 1 { return scrolled[0] }
        if scrolled.isEmpty, loose.count == 1 { return loose[0] }
        return nil
    }
}

/// A run's terminal verdict from its structural outcomes, never from the wording of its answer: a run that would
/// otherwise end ok but still holds an item it could not confirm (formatting that never read back from the text,
/// an input whose outcome was never observed) ends not-ok with the distinct "unconfirmed" status ("Needs a look").
enum UnconfirmedFinishPolicy {
    enum Verdict: Equatable { case ok, unconfirmed, failed }

    static func verdict(ok: Bool, unconfirmed: [String]) -> Verdict {
        guard ok else { return .failed }
        return unconfirmed.isEmpty ? .ok : .unconfirmed
    }

    static let needsLookNote = "Needs a look: check it yourself before relying on it."
}

/// Evidence about a file upload. An upload is attached only when the field holds files or the page shows the file's
/// name; a page that shows an upload error with zero files held rejected it. Error text never confirms an action.
enum UploadEvidence {
    enum Verdict: Equatable { case attached, rejected, uncertain }

    private static let failurePattern = #"(?i)\b(fail|failed|fails|failure|error|errors|couldn['’]?t|could not|can['’]?t|cannot|unable|invalid|rejected|reject|refused|denied|not (allowed|accepted|supported|uploaded|attached)|too (large|big)|unsupported|exceeds?|try again)\b"#

    /// Text that reports a failure or error ("Upload failed", "Invalid file type", "Couldn't attach").
    static func isFailureText(_ text: String) -> Bool {
        text.range(of: failurePattern, options: .regularExpression) != nil
    }

    /// What the page says after it took a file and then cleared its field: an upload error with zero files held is a
    /// rejection (FAILED); anything else stays uncertain (the site may keep the file elsewhere).
    static func afterCleared(heldFiles: Int, pageText: String?, fileName: String) -> Verdict {
        guard heldFiles == 0 else { return .attached }
        let text = pageText ?? ""
        if !fileName.isEmpty, text.localizedCaseInsensitiveContains(fileName) {
            // The name is shown next to an error ("resume.pdf: upload failed") — still a rejection.
            return isFailureText(text) && uploadErrorShown(text) ? .rejected : .uncertain
        }
        return uploadErrorShown(text) ? .rejected : .uncertain
    }

    /// The page shows an upload-specific error ("Upload failed", "File rejected", "Invalid file type", "File too large").
    static func uploadErrorShown(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(upload(ing)?|file|attachment|resume|cv|document)\b[^.\n]{0,40}\b(fail(ed|ure)?|error|rejected|invalid|too (large|big)|not (allowed|accepted|supported))\b|\b(fail(ed)? to|couldn['’]?t|could not|unable to|cannot) (upload|attach)\b|\b(invalid|unsupported|rejected) (file|attachment|upload)\b"#,
                   options: .regularExpression) != nil
    }

    /// A `verify text` can confirm a pending action only with non-failure text; for an upload, only text naming the
    /// uploaded file counts (the field's file count is the other accepted evidence).
    static func textMayConfirm(_ text: String, pendingKind: String, fileName: String?) -> Bool {
        guard !isFailureText(text) else { return false }
        guard pendingKind == "upload" else { return true }
        guard let fileName, !fileName.isEmpty else { return false }
        return text.localizedCaseInsensitiveContains(fileName)
    }
}

/// Return after a typed message: what to do when the send approval may have shown Clinqy's own panel in between.
enum ReturnDelivery {
    enum Decision: Equatable { case press, refocusThenPress, uncertain(String) }

    static func decide(approvalShown: Bool, background: Bool = false, sameProcess: Bool, windowResolved: Bool, focusedInField: Bool, fieldHoldsText: Bool) -> Decision {
        guard sameProcess else { return .uncertain("the app quit or restarted") }
        guard windowResolved else { return .uncertain("the pinned window was closed or replaced") }
        guard fieldHoldsText else { return .uncertain("the composer no longer holds the typed text") }
        // Background native typing: the temporary keyboard session ends after typing, so whatever moved the app's
        // focus, put it back on the same composer through AX right before Return (no activation).
        if background { return .refocusThenPress }
        if focusedInField { return .press }
        // Clinqy's own question panel took focus while asking: put the app's focus back on the composer (AX, no
        // activation), never treat that as the target changing.
        return approvalShown ? .refocusThenPress : .uncertain("focus left the composer")
    }

    /// After the AX re-focus: press only when the same composer is focused, in the same app and window, still holding
    /// exactly the typed text.
    /// `valueSetFallback`: the text went in through the composer's own AX value because the background app never
    /// reports focus for it; then the read-back of exactly the typed text is the gate, and Return is pressed unless
    /// another text input visibly holds the focus (Return would go there).
    static func afterRefocus(focused: Bool, sameProcess: Bool, windowResolved: Bool, fieldHoldsText: Bool,
                             valueSetFallback: Bool = false, focusInOtherField: Bool = false) -> Decision {
        guard sameProcess else { return .uncertain("the app quit or restarted") }
        guard windowResolved else { return .uncertain("the pinned window was closed or replaced") }
        guard fieldHoldsText else { return .uncertain("the composer text changed unexpectedly") }
        if focused { return .press }
        if valueSetFallback, !focusInOtherField { return .press }
        return .uncertain(focusInOtherField ? "another text field holds the focus" : "the composer could not be focused again")
    }

    /// Return sent the message: the composer is now empty and a new row containing the typed text appeared.
    static func sent(composerAfter: String?, rowsWithTextBefore: Int, rowsWithTextAfter: Int) -> Bool {
        guard let composerAfter, composerAfter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return rowsWithTextAfter > rowsWithTextBefore
    }
}

/// Where native input aims at an element: the centre of the part of it inside the pinned window. A long text area or
/// scroll area whose own centre lies outside the window is still a valid target; one that doesn't intersect isn't.
enum NativeAim {
    static func point(element: CGRect, window: CGRect) -> CGPoint? {
        let visible = element.intersection(window)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return nil }
        return CGPoint(x: visible.midX, y: visible.midY)
    }
}

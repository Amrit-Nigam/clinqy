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
    static func changedValue(before: String?, after: String?, expected: String, sameTarget: Bool, fieldInput: Bool) -> Bool {
        guard fieldInput, sameTarget, let before, let after else { return false }
        return before != expected && after == expected
    }

    static func newText(_ expected: String, before: String?, after: String?) -> Bool {
        guard !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let before, let after else { return false }
        return !before.localizedCaseInsensitiveContains(expected) && after.localizedCaseInsensitiveContains(expected)
    }
}

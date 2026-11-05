import Foundation
import CryptoKit

/// Stable dispatch identity within a run. Persist hashes, never raw arguments or page content.
enum ActionIdentity {
    // Ephemeral authentication key prevents offline guessing of low-entropy field contents from a
    // stored fingerprint. It is intentionally not persisted; action UUIDs provide durable identity.
    private static let fingerprintKey = SymmetricKey(size: .bits256)
    static func fingerprint(_ action: [String: Any], run: String, target: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: action, options: [.sortedKeys])) ?? Data()
        return HMAC<SHA256>.authenticationCode(for: Data((run + target).utf8) + data, using: fingerprintKey).map { String(format: "%02x", $0) }.joined()
    }
}

/// Recovery suggests a new observation, never a repeated mutation. Budgets count by cause and target,
/// not the model's wording, so paraphrasing the same failure cannot reset the limit.
struct RuntimeRecoveryBudget {
    enum Cause: String { case staleTarget, disconnected, loading, permission, unsupported, ambiguous, unverified, other }
    private var attempts: [String: Int] = [:]

    static func cause(_ summary: String, outcome: ActionOutcome) -> Cause {
        if outcome.needsVerification { return .unverified }
        let text = summary.lowercased()
        if text.contains("permission") || text.contains("accessibility access") { return .permission }
        if text.contains("unsupported") || text.contains("not supported") { return .unsupported }
        if text.contains("ambiguous") || text.contains("multiple") && text.contains("match") { return .ambiguous }
        if text.contains("disconnect") || text.contains("connection") || text.contains("extension isn't") { return .disconnected }
        if text.contains("loading") || text.contains("navigation") && text.contains("timeout") { return .loading }
        if text.contains("stale") || text.contains("changed") || text.contains("isn't on screen") || text.contains("no longer") { return .staleTarget }
        return .other
    }
    mutating func guidance(summary: String, outcome: ActionOutcome, target: String) -> String? {
        guard !outcome.isConfirmed else { return nil }
        let cause = Self.cause(summary, outcome: outcome)
        let key = cause.rawValue + ":" + target
        let count = (attempts[key] ?? 0) + 1
        attempts[key] = count
        switch cause {
        case .unverified: return "Recovery: inspect and verify the existing outcome; never replay this input to obtain evidence."
        case .permission: return "Recovery: identify the missing permission and report the required user action. Do not retry input."
        case .unsupported: return "Recovery: choose a supported capability. Repeating unsupported input cannot fix it."
        case .ambiguous: return "Recovery: observe again and select one uniquely identified target; do not guess by proximity."
        case .staleTarget, .disconnected, .loading:
            if count > 2 { return "Recovery limit reached for \(cause.rawValue) on this target. Use a different supported route or report the blocker; do not repeat the same failing action." }
            return cause == .loading
                ? "Recovery \(count)/2: wait for the expected page condition, then observe; do not navigate again."
                : "Recovery \(count)/2: take a fresh observation of the same owned target before planning another action."
        case .other: return nil
        }
    }
}

import Foundation

/// Adjust only output reservation; never discard task instructions or current observation evidence.
enum HTTPRequestBudget {
    static let controlOutputTokens = 2_048
    static func isOversizedTPM(status: Int, message: String) -> Bool {
        status == 429 && message.localizedCaseInsensitiveContains("request too large")
            && message.localizedCaseInsensitiveContains("tokens per min")
    }

    /// Only a rejected, explicitly throttled request is retryable. Never shorten a server delay
    /// to fit our bound: a larger delay requires ending the turn instead of retrying too early.
    static func rateLimitDelay(status: Int, message: String, retryAfter: String?, attempt: Int, now: Date = Date()) -> Double? {
        guard status == 429, attempt < 2, message.localizedCaseInsensitiveContains("rate limit reached"),
              !message.localizedCaseInsensitiveContains("request too large") else { return nil }
        var requested: Double?
        if let retryAfter {
            if let seconds = Double(retryAfter), seconds.isFinite, seconds >= 0 { requested = seconds }
            else {
                let format = DateFormatter()
                format.locale = Locale(identifier: "en_US_POSIX")
                format.timeZone = TimeZone(secondsFromGMT: 0)
                format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = format.date(from: retryAfter) { requested = max(0, date.timeIntervalSince(now)) }
            }
        }
        if requested == nil,
           let regex = try? NSRegularExpression(pattern: #"Please try again in\s*([0-9]+(?:\.[0-9]+)?)\s*s\b"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
           let range = Range(match.range(at: 1), in: message) { requested = Double(message[range]) }
        let seconds = requested ?? pow(2, Double(attempt))
        guard seconds.isFinite, seconds >= 0, seconds <= 60 else { return nil }
        return min(60, max(0.1, seconds + 0.1))
    }

    static func reducedOutput(status: Int, message: String, current: Int, alreadyReduced: Bool) -> Int? {
        guard !alreadyReduced, isOversizedTPM(status: status, message: message),
              let regex = try? NSRegularExpression(pattern: #"Limit\s+([0-9,]+),\s*Requested\s+([0-9,]+)"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let limitRange = Range(match.range(at: 1), in: message), let requestRange = Range(match.range(at: 2), in: message),
              let limit = Int(message[limitRange].replacingOccurrences(of: ",", with: "")),
              let requested = Int(message[requestRange].replacingOccurrences(of: ",", with: "")),
              limit > 0, requested > limit, current >= 512 else { return nil }
        // At least requested-current tokens cannot be removed by lowering output. Retain useful
        // JSON/reasoning room and a margin; if input dominates, fail rather than spam unchanged input.
        let excess = requested - limit
        guard excess < current - 512 else { return nil }
        let reduced = current - excess - 128
        return reduced >= 512 && reduced < current ? reduced : nil
    }
}

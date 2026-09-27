import Foundation

/// Now and then, has Claude tidy memory: merge duplicates, keep the newest of facts that disagree, drop stale ones.
/// Guarded so it can't lose real information: every email, link and long number must survive (unless it was
/// replaced by a newer one), it can't shrink memory by more than 40%, and the old file is backed up first.
@MainActor
enum MemoryTidy {
    private static let lastCountKey = "memoryTidyLastCount"
    /// Tidy after this many facts were added since the last time.
    private static let every = 15

    static func runIfDue() async {
        let count = Memory.facts.count
        let last = UserDefaults.standard.integer(forKey: lastCountKey)
        guard count >= 30, count >= last + every else { return }
        _ = await run()
    }

    /// Returns a short report (nil when there was nothing to do or it was unsafe).
    @discardableResult
    static func run() async -> String? {
        let facts = Memory.facts
        guard facts.count >= 10 else { return nil }
        let system = """
        You tidy a list of facts an assistant remembers about its user. Reply with JSON only (no prose, no tool calls):
        {"facts":["..."],"removed":[{"fact":"<original>","why":"duplicate|superseded|stale|merged"}]}
        Rules: the list is in the order the facts were learned — later facts are newer and win when two disagree \
        (drop the older one as superseded). Merge facts that say the same thing into one line that keeps every detail \
        (names, numbers, emails, links, dates, app/chat names). Drop facts that are clearly one-off or no longer true \
        (an expired listing, a finished one-time task) as stale. Keep everything else exactly as written. \
        Never invent or change details. Keep each fact one short line.
        """
        do {
            let session = try ClaudeSession(system: system, model: Brain.model)
            defer { session.close() }
            let reply = try await session.send(facts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
            guard let json = Brain.json(from: reply), let kept = json["facts"] as? [String] else { return nil }
            let removed = (json["removed"] as? [[String: Any]] ?? []).map { ($0["fact"] as? String ?? "", ($0["why"] as? String ?? "").lowercased()) }
            let cleaned = kept.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard safe(before: facts, after: cleaned, removed: removed) else {
                Agent.writeLog("🧠 memory tidy skipped: the result would have lost details")
                return nil
            }
            Memory.replaceAll(with: cleaned, backup: true)
            UserDefaults.standard.set(cleaned.count, forKey: lastCountKey)
            let report = "memory tidied: \(facts.count) → \(cleaned.count) facts"
            Agent.writeLog("🧠 \(report)")
            return report
        } catch {
            return nil
        }
    }

    /// Emails, links and numbers (4+ digits) in a fact: the details that must never silently disappear.
    private static func details(_ text: String) -> Set<String> {
        let pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}/[^\s,;)]+|\+?\d[\d ]{3,}\d"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return Set(re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased().replacingOccurrences(of: " ", with: "")
        })
    }

    static func safe(before: [String], after: [String], removed: [(String, String)]) -> Bool {
        guard after.count >= Int(Double(before.count) * 0.6) else { return false }
        let kept = after.joined(separator: "\n").lowercased().replacingOccurrences(of: " ", with: "")
        let replaced = Set(removed.filter { $0.1.contains("supersed") || $0.1.contains("stale") }.map(\.0))
        for fact in before where !replaced.contains(fact) {
            for d in details(fact) where !kept.contains(d) { return false }
        }
        return true
    }
}

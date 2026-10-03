import Foundation

/// How clicks go, per site or app: one agent.log line per click (what `Clinqy stats` adds up), and which way of
/// clicking to try first on a site where the usual one keeps doing nothing.
enum Clicks {
    /// "click: web github.com mouse ok 1": kind (web · ax · text), where, the method that ended it, ok or nochange,
    /// and how many methods were tried.
    static func line(kind: String, place: String, method: String, worked: Bool, tries: Int) -> String {
        let where_ = place.isEmpty ? "-" : place.replacingOccurrences(of: " ", with: "_")
        return "    click: \(kind) \(where_) \(method) \(worked ? "ok" : "nochange") \(tries)"
    }

    static func host(_ url: String) -> String {
        (URL(string: url)?.host ?? "").replacingOccurrences(of: "www.", with: "")
    }

    // MARK: - What works where

    private struct Tally: Codable { var mouseMiss = 0, mouseWin = 0, scriptWin = 0 }
    private static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clinqy/click-hints.json")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tallies: [String: Tally] = {
        (try? JSONDecoder().decode([String: Tally].self, from: Data(contentsOf: url))) ?? [:]
    }()

    /// The site ignores real mouse clicks but takes clicks through the page: start with those there.
    static func prefersScript(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        let t = lock.withLock { tallies[host] } ?? Tally()
        return t.scriptWin >= 2 && t.mouseMiss >= 2 && t.mouseMiss > t.mouseWin
    }

    /// What one web click showed: whether the mouse was tried and did something, and whether a page click rescued it.
    static func note(_ host: String, mouseTried: Bool, mouseWorked: Bool, scriptWorked: Bool) {
        guard !host.isEmpty, mouseTried || scriptWorked else { return }
        let snapshot: [String: Tally] = lock.withLock {
            var t = tallies[host] ?? Tally()
            if mouseTried { if mouseWorked { t.mouseWin += 1 } else { t.mouseMiss += 1 } }
            if scriptWorked { t.scriptWin += 1 }
            // Recent behaviour matters most: halve old counts once they grow.
            if t.mouseMiss + t.mouseWin + t.scriptWin > 40 { t = Tally(mouseMiss: t.mouseMiss / 2, mouseWin: t.mouseWin / 2, scriptWin: t.scriptWin / 2) }
            tallies[host] = t
            return tallies
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

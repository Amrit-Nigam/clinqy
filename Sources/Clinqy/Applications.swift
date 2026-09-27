import Foundation

/// Job/internship applications Clinqy filled or sent, kept apart from memory so they don't crowd out facts
/// about the user. Stored in Application Support as applications.json.
enum Applications {
    struct Entry: Codable, Equatable {
        var company: String
        var role: String
        var url: String?
        var date: Date
        var status: String        // filled (not submitted) / submitted / emailed / interview / rejected / offer / skipped
        var resume: String?
        var notes: String?
    }

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clinqy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("applications.json")
    }()

    static var all: [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private static func save(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(entries).write(to: url, options: .atomic)
    }

    private static func key(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Same posting: same link, or same company and role.
    private static func matches(_ e: Entry, company: String, role: String, url: String?) -> Bool {
        if let url, let other = e.url, !url.isEmpty, key(url) == key(other) { return true }
        return key(e.company) == key(company) && (key(e.role) == key(role) || role.isEmpty)
    }

    /// Adds an application, or updates the one already there for the same posting. Returns a line for the agent.
    @discardableResult
    static func record(company: String, role: String, url: String?, status: String, resume: String?, notes: String?) -> String {
        var entries = all
        if let i = entries.firstIndex(where: { matches($0, company: company, role: role, url: url) }) {
            if !status.isEmpty { entries[i].status = status }
            if let url, !url.isEmpty { entries[i].url = url }
            if let resume { entries[i].resume = resume }
            if let notes { entries[i].notes = notes }
            if !role.isEmpty { entries[i].role = role }
            save(entries)
            return "updated: \(describe(entries[i]))"
        }
        let entry = Entry(company: company, role: role, url: url, date: Date(), status: status.isEmpty ? "filled" : status,
                          resume: resume, notes: notes)
        entries.append(entry)
        save(entries)
        return "recorded: \(describe(entry))"
    }

    /// Earlier applications matching a company, role or link (words in any order).
    static func find(_ query: String) -> [Entry] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        let q = key(query)
        return all.filter { e in
            if let u = e.url, !q.isEmpty, key(u).contains(q) || q.contains(key(u)) { return true }
            let hay = "\(e.company) \(e.role) \(e.url ?? "")".lowercased()
            return !words.isEmpty && words.allSatisfy { hay.contains($0) } || !words.isEmpty && words.contains { $0.count >= 4 && key(e.company).contains($0) }
        }
    }

    static func describe(_ e: Entry) -> String {
        "\(e.company) — \(e.role) · \(e.status) · \(e.date.formatted(date: .abbreviated, time: .omitted))"
            + (e.resume.map { " · \($0)" } ?? "") + (e.url.map { " · \($0)" } ?? "") + (e.notes.map { " · \($0)" } ?? "")
    }

    /// The tracker as a result card, newest first.
    static var card: ResultCard {
        let entries = all.sorted { $0.date > $1.date }
        let submitted = entries.filter { $0.status != "filled" && $0.status != "skipped" }.count
        return ResultCard(title: "Applications (\(entries.count))",
                          text: entries.isEmpty ? "Nothing yet — applications Clinqy fills or sends show up here."
                                                : "\(submitted) sent · \(entries.count - submitted) filled but not submitted, or skipped",
                          items: entries.map { e in
                              ResultCard.Item(title: "\(e.company) — \(e.role)",
                                              subtitle: "\(e.status) · \(e.date.formatted(date: .abbreviated, time: .omitted))" + (e.resume.map { " · \($0)" } ?? ""),
                                              detail: e.notes, link: e.url)
                          })
    }
}

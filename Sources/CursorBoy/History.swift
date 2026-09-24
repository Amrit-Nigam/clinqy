import Foundation

/// Past runs, newest first, kept in Application Support so the user can revisit or continue them.
@MainActor
final class History: ObservableObject {
    static let shared = History()

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let date: Date
        let request: String
        let answer: String
        let ok: Bool
        let steps: [String]
        let app: String?
        let result: ResultCard?
    }

    @Published private(set) var entries: [Entry] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CursorBoy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder.iso.decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func add(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
        save()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder.iso.encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}

/// Something a task produced for the user to look at: options, a plan, prices, a summary.
struct ResultCard: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id = UUID()
        let title: String
        let subtitle: String?
        let detail: String?
        let link: String?

        enum CodingKeys: String, CodingKey { case title, subtitle, detail, link }
    }

    let title: String
    let text: String?
    let items: [Item]

    /// Parses the agent's {"do":"show", "title", "text", "items":[{title, subtitle, detail, link}]}.
    init?(action: [String: Any]) {
        let title = (action["title"] as? String) ?? "Result"
        let text = action["text"] as? String
        let items = (action["items"] as? [[String: Any]] ?? []).compactMap { i -> Item? in
            guard let t = i["title"] as? String else { return nil }
            return Item(title: t, subtitle: i["subtitle"] as? String, detail: i["detail"] as? String, link: i["link"] as? String)
        }
        guard text?.isEmpty == false || !items.isEmpty else { return nil }
        self.init(title: title, text: text, items: items)
    }

    init(title: String, text: String?, items: [Item]) {
        self.title = title
        self.text = text
        self.items = items
    }

    /// Plain text for copying.
    var plain: String {
        var lines = [title]
        if let text { lines.append(text) }
        for i in items {
            lines.append("• " + [i.title, i.subtitle, i.detail, i.link].compactMap { $0 }.joined(separator: " — "))
        }
        return lines.joined(separator: "\n")
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

private extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

import Foundation

struct UsageEntry: Codable {
    let at: Date
    let provider: String
    let model: String
    let inputTokens: Int?
    let outputTokens: Int?
}

struct ProviderUsage: Identifiable, Equatable {
    var id: String { provider }
    let provider: String
    let requests: Int
    let inputTokens: Int
    let outputTokens: Int
    let meteredRequests: Int
}

struct DailyUsage: Identifiable, Equatable {
    var id: String { day }
    let day: String
    let requests: Int
    let inputTokens: Int
    let outputTokens: Int
}

struct UsageSummary: Equatable {
    let requests: Int
    let inputTokens: Int
    let outputTokens: Int
    let meteredRequests: Int
    let providers: [ProviderUsage]
    let days: [DailyUsage]
}

enum UsageRange: String, CaseIterable, Identifiable {
    case month = "This month"
    case thirtyDays = "Last 30 days"
    case allTime = "All time"
    var id: String { rawValue }

    var start: Date? {
        start(at: Date(), calendar: .current)
    }

    func start(at now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .month:
            return calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case .allTime:
            return nil
        }
    }
}

enum UsageStore {
    private static let lock = NSLock()
    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Clinqy/usage.jsonl")
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static var cache = UsageSummaryCache()

    static func record(provider: Provider, model: String, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        let entry = UsageEntry(at: Date(), provider: provider.rawValue, model: model,
                               inputTokens: inputTokens, outputTokens: outputTokens)
        lock.withLock {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                var data = try encoder.encode(entry)
                data.append(0x0A)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
                cache.invalidate()
            } catch {
                let message = "usage: couldn't save local usage: \(error.localizedDescription)"
                Task { @MainActor in Agent.writeLog(message) }
            }
        }
    }

    static func summary(range: UsageRange) -> UsageSummary {
        lock.withLock { cache.summary(file: fileURL, range: range) }
    }

    fileprivate static func summarize(_ entries: [UsageEntry], start: Date?, calendar: Calendar) -> UsageSummary {
        let selected = entries.filter { entry in start.map { entry.at >= $0 } ?? true }
        var grouped: [String: (requests: Int, input: Int, output: Int, metered: Int)] = [:]
        var daily: [String: (requests: Int, input: Int, output: Int)] = [:]
        for entry in selected {
            var row = grouped[entry.provider, default: (0, 0, 0, 0)]
            row.requests += 1
            if let input = entry.inputTokens { row.input += input }
            if let output = entry.outputTokens { row.output += output }
            if entry.inputTokens != nil || entry.outputTokens != nil { row.metered += 1 }
            grouped[entry.provider] = row

            let parts = calendar.dateComponents([.year, .month, .day], from: entry.at)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            var dayRow = daily[key, default: (0, 0, 0)]
            dayRow.requests += 1
            dayRow.input += entry.inputTokens ?? 0
            dayRow.output += entry.outputTokens ?? 0
            daily[key] = dayRow
        }
        let providers = grouped.map { name, row in
            ProviderUsage(provider: name, requests: row.requests, inputTokens: row.input,
                          outputTokens: row.output, meteredRequests: row.metered)
        }.sorted { $0.requests > $1.requests }
        let days = daily.map { day, row in
            DailyUsage(day: day, requests: row.requests, inputTokens: row.input, outputTokens: row.output)
        }.sorted { $0.day < $1.day }
        return UsageSummary(requests: providers.reduce(0) { $0 + $1.requests },
                            inputTokens: providers.reduce(0) { $0 + $1.inputTokens },
                            outputTokens: providers.reduce(0) { $0 + $1.outputTokens },
                            meteredRequests: providers.reduce(0) { $0 + $1.meteredRequests },
                            providers: providers, days: days)
    }
}

/// Cache immutable log snapshots, invalidating on appends, replacement, truncation and timezone changes.
/// Rolling 30-day summaries are recalculated from cached entries so entries expire at the exact cutoff.
struct UsageSummaryCache {
    private struct Stamp: Equatable {
        let file: URL
        let size: UInt64
        let modified: Date
        let inode: UInt64
    }
    private var stamp: Stamp?
    private var loaded = false
    private var entries: [UsageEntry] = []
    private var summaries: [UsageRange: (start: Date?, calendar: Calendar, value: UsageSummary)] = [:]
    private(set) var loads = 0

    mutating func invalidate() { loaded = false; summaries.removeAll() }

    mutating func summary(file: URL, range: UsageRange, now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let current: Stamp? = attributes.flatMap { attributes in
            guard let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
            return Stamp(file: file, size: size.uint64Value, modified: modified, inode: inode.uint64Value)
        }
        if !loaded || current != stamp {
            summaries.removeAll()
            entries = []
            stamp = current
            loaded = current == nil // A missing log is empty; retry unreadable existing files next time.
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                entries = text.split(separator: "\n").compactMap { try? decoder.decode(UsageEntry.self, from: Data($0.utf8)) }
                loads += 1
                loaded = true
            }
        }
        let start = range.start(at: now, calendar: calendar)
        if let cached = summaries[range], cached.start == start, cached.calendar == calendar { return cached.value }
        let value = UsageStore.summarize(entries, start: start, calendar: calendar)
        if range != .thirtyDays { summaries[range] = (start, calendar, value) }
        return value
    }
}

import Foundation

struct UsageEntry: Codable {
    let at: Date
    let provider: String
    let model: String
    let inputTokens: Int?
    let outputTokens: Int?
}

struct ProviderUsage: Identifiable {
    var id: String { provider }
    let provider: String
    let requests: Int
    let inputTokens: Int
    let outputTokens: Int
    let meteredRequests: Int
}

struct DailyUsage: Identifiable {
    var id: String { day }
    let day: String
    let requests: Int
    let inputTokens: Int
    let outputTokens: Int
}

struct UsageSummary {
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
        let calendar = Calendar.current
        let now = Date()
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
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

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
            } catch {
                let message = "usage: couldn't save local usage: \(error.localizedDescription)"
                Task { @MainActor in Agent.writeLog(message) }
            }
        }
    }

    static func summary(range: UsageRange) -> UsageSummary {
        let entries: [UsageEntry] = lock.withLock {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? decoder.decode(UsageEntry.self, from: Data($0.utf8)) }
        }
        let selected = entries.filter { entry in range.start.map { entry.at >= $0 } ?? true }
        var grouped: [String: (requests: Int, input: Int, output: Int, metered: Int)] = [:]
        var daily: [String: (requests: Int, input: Int, output: Int)] = [:]
        for entry in selected {
            var row = grouped[entry.provider, default: (0, 0, 0, 0)]
            row.requests += 1
            if let input = entry.inputTokens { row.input += input }
            if let output = entry.outputTokens { row.output += output }
            if entry.inputTokens != nil || entry.outputTokens != nil { row.metered += 1 }
            grouped[entry.provider] = row

            let day = Calendar.current.startOfDay(for: entry.at)
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
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

import Foundation

/// Requests to run later, once or on repeat ("every weekday at 9 check my placement mail"). Stored in Application
/// Support as schedules.json; the app delegate's timer runs whatever is due, and the menu lists and removes them.
@MainActor
enum Scheduler {
    enum Repeat: String, Codable, CaseIterable {
        case none, daily, weekdays, hourly

        var label: String {
            switch self {
            case .none: return "once"
            case .daily: return "daily"
            case .weekdays: return "weekdays"
            case .hourly: return "hourly"
            }
        }
    }

    enum MissedRunPolicy: String, Codable, CaseIterable {
        /// One occurrence runs after wake/relaunch; older repeat occurrences are coalesced.
        case catchUpLatest
        case skipAfterTwoHours

        var label: String {
            switch self {
            case .catchUpLatest: return "Catch up once after wake or relaunch"
            case .skipAfterTwoHours: return "Skip when more than two hours late"
            }
        }
    }

    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        var request: String
        var next: Date
        var rule: Repeat
        var lastRun: Date?
        // Optional for compatibility with schedules created before missed-run policy was explicit.
        var missedRunPolicy: MissedRunPolicy? = nil
        var policy: MissedRunPolicy { missedRunPolicy ?? .skipAfterTwoHours }

        /// Stable across a crash between durable task creation and schedule acknowledgement.
        var occurrenceID: String { "schedule:" + id.uuidString.lowercased() + ":" + String(Int64(next.timeIntervalSince1970 * 1000)) }
    }

    struct Dispatch {
        let item: Item
        let taskID: UUID
    }

    /// File-backed state with injectable storage for recovery tests. The task store acts as a durable outbox:
    /// create/deduplicate the occurrence there BEFORE advancing the schedule here. Recovery can safely retry
    /// the handoff, but never replays an existing running, interrupted or completed task.
    @MainActor
    final class Store {
        let file: URL
        private(set) var storageError: String?
        private(set) var lastNotice: String?

        init(file: URL) { self.file = file }

        var all: [Item] { (try? load()) ?? [] }

        private func load() throws -> [Item] {
            do {
                guard FileManager.default.fileExists(atPath: file.path) else { return [] }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode([Item].self, from: Data(contentsOf: file)).sorted { $0.next < $1.next }
            } catch {
                storageError = "Schedules couldn't be read safely. The existing file was preserved; scheduled starts are disabled."
                throw error
            }
        }

        private func save(_ items: [Item]) throws {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(items).write(to: file, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                storageError = nil
            } catch {
                storageError = "Couldn't save schedules. The occurrence stays due until its task is safely queued and the schedule is saved."
                throw error
            }
        }

        @discardableResult
        func add(_ item: Item) -> Bool {
            do { var items = try load(); items.append(item); try save(items); return true }
            catch { return false }
        }

        @discardableResult
        func remove(_ id: UUID) -> Bool {
            do { try save(try load().filter { $0.id != id }); return true }
            catch { return false }
        }

        func dispatchDue(now: Date = Date(), enqueue: (Item, String) -> UUID?) -> Dispatch? {
            do {
                var items = try load()
                for index in items.indices where items[index].next <= now {
                    let item = items[index]
                    let skip = item.policy == .skipAfterTwoHours && now.timeIntervalSince(item.next) > 2 * 3600
                    if skip {
                        advance(&items, index: index, now: now, dispatched: false)
                        try save(items)
                        lastNotice = "Skipped missed schedule: “\(item.request)” (more than two hours late)."
                        // Mutating indices invalidates the iteration; another due item is handled next tick.
                        return nil
                    }
                    guard let taskID = enqueue(item, item.occurrenceID) else {
                        storageError = "Scheduled task couldn't be saved. Its schedule stays due; check Tasks & Recovery."
                        return nil
                    }
                    advance(&items, index: index, now: now, dispatched: true)
                    try save(items)
                    lastNotice = nil
                    return Dispatch(item: item, taskID: taskID)
                }
                return nil
            } catch { return nil }
        }

        private func advance(_ items: inout [Item], index: Int, now: Date, dispatched: Bool) {
            if items[index].rule == .none { items.remove(at: index) }
            else {
                if dispatched { items[index].lastRun = now }
                items[index].next = Scheduler.nextOccurrence(after: now, from: items[index].next, rule: items[index].rule)
            }
        }
    }

    private static let store = Store(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clinqy/schedules.json"))
    static var all: [Item] { store.all }
    static var storageError: String? { store.storageError }
    static var lastNotice: String? { store.lastNotice }

    /// Schedules `request` at `when`. Missed repeating runs coalesce into one catch-up by default.
    @discardableResult
    static func add(request: String, when: Date, repeat rule: Repeat = .none, missed: MissedRunPolicy = .catchUpLatest) -> String {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "FAILED: nothing to schedule" }
        var first = when
        if first < Date() {
            first = rule == .none ? Calendar.current.date(byAdding: .day, value: 1, to: first) ?? first : nextOccurrence(after: Date(), from: first, rule: rule)
        }
        if rule == .weekdays, Calendar.current.isDateInWeekend(first) { first = nextOccurrence(after: first, from: first, rule: .weekdays) }
        let item = Item(request: text, next: first, rule: rule, missedRunPolicy: missed)
        guard store.add(item) else { return "FAILED: " + (store.storageError ?? "Couldn't save schedule") }
        Agent.writeLog("scheduled: “\(text)” · \(describe(item))")
        return "scheduled: “\(text)” — \(describe(item)); \(missed.label.lowercased())"
    }

    /// Schedules from a natural phrase: "at 9am", "tomorrow 8:30", "in 20 minutes", "every weekday at 9",
    /// "daily at 18:00", "every hour". nil when the phrase can't be read.
    @discardableResult
    static func add(request: String, phrase: String, missed: MissedRunPolicy = .catchUpLatest) -> String? {
        guard let (when, rule) = parse(phrase) else { return nil }
        return add(request: request, when: when, repeat: rule, missed: missed)
    }

    @discardableResult
    static func remove(_ id: UUID) -> Bool { store.remove(id) }

    /// "Tomorrow 9:00 AM · weekdays".
    static func describe(_ item: Item) -> String {
        let cal = Calendar.current
        let time = item.next.formatted(date: .omitted, time: .shortened)
        let day = cal.isDateInToday(item.next) ? "today" : cal.isDateInTomorrow(item.next) ? "tomorrow"
            : item.next.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        switch item.rule {
        case .none: return "\(day) \(time)"
        case .hourly: return "every hour, next \(time)"
        case .daily: return "daily at \(time)"
        case .weekdays: return "weekdays at \(time)"
        }
    }

    static func dispatchDue(now: Date = Date(), enqueue: (Item, String) -> UUID?) -> Dispatch? {
        store.dispatchDue(now: now, enqueue: enqueue)
    }

    /// Latest daily occurrence already due today. Restarts use its stable timestamp for task deduplication.
    static func dailyOccurrence(time: String, now: Date = Date(), lastRun: Date?, catchUp: Bool = true) -> Date? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute),
              let occurrence = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now),
              occurrence <= now, lastRun.map({ $0 < occurrence }) ?? true else { return nil }
        // Legacy workflow schedules have no explicit missed-run policy. Preserve their original minute-only
        // behavior; durable queued occurrences still resume through TaskStore after dispatch.
        if !catchUp, now.timeIntervalSince(occurrence) >= 60 { return nil }
        return occurrence
    }

    private static func nextOccurrence(after now: Date, from base: Date, rule: Repeat) -> Date {
        let cal = Calendar.current
        var d = base
        switch rule {
        case .none: return base
        case .hourly:
            while d <= now { d = cal.date(byAdding: .hour, value: 1, to: d) ?? now.addingTimeInterval(3600) }
        case .daily, .weekdays:
            repeat { d = cal.date(byAdding: .day, value: 1, to: d) ?? now.addingTimeInterval(86400) }
            while d <= now || (rule == .weekdays && cal.isDateInWeekend(d))
        }
        return d
    }

    // MARK: - Natural phrases

    /// Reads "in 20 minutes", "at 9", "at 9:30 pm", "tomorrow at 8", "tonight", "every weekday at 9am",
    /// "daily 18:00", "every morning", "every hour", "monday at 10". Returns the first run and the repeat rule.
    static func parse(_ phrase: String, now: Date = Date()) -> (Date, Repeat)? {
        let p = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let cal = Calendar.current
        func has(_ pattern: String) -> Bool { p.range(of: pattern, options: .regularExpression) != nil }
        func match(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) else { return nil }
            return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: p).map { String(p[$0]) } ?? "" }
        }

        // "in 20 minutes", "in 2 hours", "in an hour"
        if let m = match(#"\bin (\d+|an?|half an) ?(min|minute|minutes|mins|hour|hours|hr|hrs)\b"#) {
            let n = Int(m[1]) ?? (m[1] == "half an" ? 0 : 1)
            let minutes = m[2].hasPrefix("h") ? (m[1] == "half an" ? 30 : n * 60) : n
            return (now.addingTimeInterval(TimeInterval(minutes * 60)), .none)
        }

        let rule: Repeat = has(#"\bevery ?hour|\bhourly\b"#) ? .hourly
            : has(#"\b(every )?(weekday|weekdays|working day|workday)s?\b|\bmon(day)?\s*(-|to|–)\s*fri(day)?\b"#) ? .weekdays
            : has(#"\b(every ?day|daily|every (morning|evening|night|afternoon))\b"#) ? .daily
            : .none
        if rule == .hourly {
            let minute = match(#":(\d{2})"#).flatMap { Int($0[1]) } ?? cal.component(.minute, from: now)
            var d = cal.date(bySettingHour: cal.component(.hour, from: now), minute: minute, second: 0, of: now) ?? now
            if d <= now { d = cal.date(byAdding: .hour, value: 1, to: d) ?? d }
            return (d, .hourly)
        }

        // Time of day: "9", "9:30", "9am", "9.30 pm", "18:00", "noon", or a part of the day.
        var hour: Int?, minute = 0
        if has(#"\bnoon\b"#) { hour = 12 } else if has(#"\bmidnight\b"#) { hour = 0 }
        else if let m = match(#"\b(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?![\d/])"#), !m[1].isEmpty,
                (p.range(of: #"\b(at|@|by|around)\s*\d"#, options: .regularExpression) != nil || !m[3].isEmpty || !m[2].isEmpty
                 || p.range(of: #"^\d"#, options: .regularExpression) != nil || rule != .none) {
            var h = Int(m[1]) ?? 0
            minute = Int(m[2]) ?? 0
            if m[3].hasPrefix("p"), h < 12 { h += 12 }
            if m[3].hasPrefix("a"), h == 12 { h = 0 }
            // "at 7" with no am/pm, said after 7 am: the 7 o'clock still ahead today (7 pm).
            if m[3].isEmpty, h >= 1, h < 12, !m[1].hasPrefix("0"), rule == .none, !has(#"\b(tomorrow|morning|sun|mon|tue|tues|wed|thu|thurs|fri|sat|sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#),
               let today = cal.date(bySettingHour: h, minute: minute, second: 0, of: now), today <= now,
               let later = cal.date(bySettingHour: h + 12, minute: minute, second: 0, of: now), later > now { h += 12 }
            guard h < 24, minute < 60 else { return nil }
            hour = h
        }
        else if has(#"\bmorning\b"#) { hour = 9 } else if has(#"\bafternoon\b"#) { hour = 14 }
        else if has(#"\bevening\b"#) { hour = 18 } else if has(#"\b(tonight|night)\b"#) { hour = 21 }

        // Day: today (default), tomorrow, or a weekday name.
        var day = now
        var explicitDay = false
        if has(#"\btomorrow\b"#) { day = cal.date(byAdding: .day, value: 1, to: now) ?? now; explicitDay = true }
        else if let m = match(#"\b(sun|mon|tue|wed|thu|fri|sat)(day|s|sday|nesday|rsday|urday)?\b"#), rule == .none {
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            if let idx = names.firstIndex(of: m[1]) {
                day = cal.nextDate(after: cal.startOfDay(for: now), matching: DateComponents(weekday: idx + 1), matchingPolicy: .nextTime) ?? now
                explicitDay = true
            }
        }
        guard let hour else { return nil }
        guard var d = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { return nil }
        if d <= now {
            if explicitDay { return nil }
            d = cal.date(byAdding: .day, value: 1, to: d) ?? d
        }
        return (d, rule)
    }
}

import EventKit

/// Calendar events and reminders straight through EventKit: local, instant and exact, instead of clicking
/// through Calendar's UI. Dates come from the model as local "yyyy-MM-dd HH:mm" (or ISO 8601).
@MainActor
enum Events {
    private static let store = EKEventStore()

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Access

    private static func access(_ type: EKEntityType) async throws {
        let status = EKEventStore.authorizationStatus(for: type)
        if status == .fullAccess || (type == .event && status == .writeOnly) { return }
        let what = type == .event ? "Calendars" : "Reminders"
        guard status == .notDetermined else {
            throw Failure("no access to \(what): turn it on for Clinqy in System Settings → Privacy & Security → \(what)")
        }
        let granted = type == .event ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
        guard granted else { throw Failure("the user didn't allow access to \(what)") }
    }

    static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess && EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    static func requestAccess() {
        Task { try? await access(.event); try? await access(.reminder) }
    }

    // MARK: Dates

    private static let formats = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"]

    /// A local date-time from the model. Date-only strings mean the start of that day.
    static func date(_ raw: Any?) -> Date? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let d = ISO8601DateFormatter().date(from: s) { return d }   // with a zone ("…Z", "+05:30")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in formats {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    private static func hasTime(_ raw: Any?) -> Bool { (raw as? String)?.contains(":") == true }

    private static func show(_ d: Date, time: Bool = true) -> String {
        time ? d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
             : d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    // MARK: Calendar

    /// op: create · list (from/to, default today → +7 days) · free (a day's busy times and free gaps) · find (query) · delete (id)
    static func event(_ a: [String: Any]) async throws -> String {
        try await access(.event)
        let op = (a["op"] as? String ?? "create").lowercased()
        switch op {
        case "create", "add":
            guard let title = a["title"] as? String, !title.isEmpty else { throw Failure("event needs a title") }
            guard let start = date(a["start"]) else { throw Failure("event needs start as \"yyyy-MM-dd HH:mm\" (local time)") }
            let allDay = a["all_day"] as? Bool ?? !hasTime(a["start"])
            let minutes = (a["minutes"] as? NSNumber)?.doubleValue ?? 30
            let end = date(a["end"]) ?? (allDay ? start : start.addingTimeInterval(minutes * 60))
            guard end >= start else { throw Failure("end is before start") }
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = end
            event.isAllDay = allDay
            event.location = a["location"] as? String
            event.notes = a["notes"] as? String
            if let link = a["url"] as? String { event.url = URL(string: link) }
            event.calendar = try calendar(named: a["calendar"] as? String, for: .event)
            if let alert = (a["alert_minutes"] as? NSNumber)?.doubleValue { event.addAlarm(EKAlarm(relativeOffset: -alert * 60)) }
            let clashes = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .filter { !$0.isAllDay && $0.eventIdentifier != nil }
            try store.save(event, span: .thisEvent)
            let when = allDay ? show(start, time: false) + " (all day)" : "\(show(start)) – \(end.formatted(date: .omitted, time: .shortened))"
            return "added “\(title)” to \(event.calendar.title): \(when)"
                + (clashes.isEmpty ? "" : ". Note: it overlaps " + clashes.prefix(3).map { "“\($0.title ?? "")”" }.joined(separator: ", "))

        case "list", "find", "search":
            let from = date(a["from"]) ?? (op == "list" ? Calendar.current.startOfDay(for: Date()) : Date().addingTimeInterval(-30 * 86400))
            let to = date(a["to"]).map { hasTime(a["to"]) ? $0 : $0.addingTimeInterval(86400) } ?? from.addingTimeInterval((op == "list" ? 7 : 90) * 86400)
            var events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
            if let q = (a["query"] as? String)?.lowercased(), !q.isEmpty {
                let words = q.split(separator: " ").map(String.init)
                events = events.filter { e in
                    let hay = [e.title, e.location, e.notes].compactMap { $0 }.joined(separator: " ").lowercased()
                    return words.allSatisfy(hay.contains)
                }
            }
            guard !events.isEmpty else { return "no events \(show(from, time: false)) – \(show(to, time: false))\((a["query"] as? String).map { " matching “\($0)”" } ?? "")" }
            return "events:\n" + events.sorted { $0.startDate < $1.startDate }.prefix(60).map(line).joined(separator: "\n")

        case "free", "busy":
            let day = Calendar.current.startOfDay(for: date(a["day"] ?? a["from"]) ?? Date())
            let startHour = (a["from_hour"] as? Int) ?? 9, endHour = (a["to_hour"] as? Int) ?? 19
            let open = day.addingTimeInterval(Double(startHour) * 3600), close = day.addingTimeInterval(Double(endHour) * 3600)
            let busy = store.events(matching: store.predicateForEvents(withStart: open, end: close, calendars: nil))
                .filter { !$0.isAllDay && $0.availability != .free }.sorted { $0.startDate < $1.startDate }
            var gaps: [String] = [], cursor = open
            for e in busy {
                if e.startDate.timeIntervalSince(cursor) >= 15 * 60 { gaps.append("\(cursor.formatted(date: .omitted, time: .shortened))–\(e.startDate.formatted(date: .omitted, time: .shortened))") }
                cursor = max(cursor, e.endDate)
            }
            if close.timeIntervalSince(cursor) >= 15 * 60 { gaps.append("\(cursor.formatted(date: .omitted, time: .shortened))–\(close.formatted(date: .omitted, time: .shortened))") }
            return "\(show(day, time: false)), \(startHour):00–\(endHour):00. Busy: " + (busy.isEmpty ? "nothing" : busy.map(line).joined(separator: "; "))
                + ". Free: " + (gaps.isEmpty ? "no gap of 15 min or more" : gaps.joined(separator: ", "))

        case "delete", "remove":
            guard let id = a["id"] as? String, let e = store.event(withIdentifier: id) else { throw Failure("delete needs the event's id (from list/find)") }
            let title = e.title ?? ""
            try store.remove(e, span: .thisEvent)
            return "deleted “\(title)” (\(show(e.startDate)))"

        default:
            throw Failure("event op: create, list, find, free or delete")
        }
    }

    private static func line(_ e: EKEvent) -> String {
        let when = e.isAllDay ? show(e.startDate, time: false) + " all day"
            : "\(show(e.startDate))–\(e.endDate.formatted(date: .omitted, time: .shortened))"
        return "- \(when) · \(e.title ?? "(no title)")\(e.location.map { " @ \($0)" } ?? "") [\(e.calendar.title); id \(e.eventIdentifier ?? "?")]"
    }

    // MARK: Reminders

    /// op: create · list (open ones; optional list name) · complete (id or title)
    static func reminder(_ a: [String: Any]) async throws -> String {
        try await access(.reminder)
        let op = (a["op"] as? String ?? "create").lowercased()
        switch op {
        case "create", "add":
            guard let title = a["title"] as? String, !title.isEmpty else { throw Failure("reminder needs a title") }
            let r = EKReminder(eventStore: store)
            r.title = title
            r.notes = a["notes"] as? String
            r.calendar = try calendar(named: a["list"] as? String, for: .reminder)
            if let due = date(a["due"]) {
                let timed = hasTime(a["due"])
                r.dueDateComponents = Calendar.current.dateComponents(timed ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: due)
                if timed { r.addAlarm(EKAlarm(absoluteDate: due)) }
            }
            if let p = a["priority"] as? String { r.priority = ["high": 1, "medium": 5, "low": 9][p.lowercased()] ?? 0 }
            try store.save(r, commit: true)
            return "added reminder “\(title)” to \(r.calendar.title)\(date(a["due"]).map { ", due \(show($0, time: hasTime(a["due"])))" } ?? "")"

        case "list", "complete", "done":
            let lists = (a["list"] as? String).flatMap { name in store.calendars(for: .reminder).filter { $0.title.lowercased() == name.lowercased() } }
            let open: [EKReminder] = await withCheckedContinuation { done in
                store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)) {
                    done.resume(returning: $0 ?? [])
                }
            }
            if op == "list" {
                guard !open.isEmpty else { return "no open reminders" }
                return "open reminders:\n" + open.prefix(60).map { r in
                    "- \(r.title ?? "")\(r.dueDateComponents?.date.map { " (due \(show($0)))" } ?? "") [\(r.calendar.title); id \(r.calendarItemIdentifier)]"
                }.joined(separator: "\n")
            }
            let key = ((a["id"] ?? a["title"]) as? String ?? "").lowercased()
            guard !key.isEmpty, let r = open.first(where: { $0.calendarItemIdentifier.lowercased() == key })
                    ?? open.first(where: { ($0.title ?? "").lowercased() == key })
                    ?? open.first(where: { ($0.title ?? "").lowercased().contains(key) }) else {
                throw Failure("no open reminder like “\(key)”")
            }
            r.isCompleted = true
            try store.save(r, commit: true)
            return "marked “\(r.title ?? "")” done"

        default:
            throw Failure("reminder op: create, list or complete")
        }
    }

    /// The named calendar/list (case-insensitive, then partial), else the default one.
    private static func calendar(named name: String?, for type: EKEntityType) throws -> EKCalendar {
        let all = store.calendars(for: type).filter(\.allowsContentModifications)
        if let name, !name.isEmpty {
            let n = name.lowercased()
            if let hit = all.first(where: { $0.title.lowercased() == n }) ?? all.first(where: { $0.title.lowercased().contains(n) }) { return hit }
        }
        let fallback = type == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        guard let cal = fallback ?? all.first else { throw Failure("no \(type == .event ? "calendar" : "reminders list") to add to") }
        return cal
    }
}

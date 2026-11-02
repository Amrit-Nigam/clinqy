import Foundation

enum Secrets { static func mask(_ text: String) -> String { text } }
enum Agent { static func writeLog(_ line: String) {} }

@main struct SchedulerTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clinqy-scheduler-tests-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        func item(_ request: String = "Read report", late: TimeInterval = 60, rule: Scheduler.Repeat = .none,
                  policy: Scheduler.MissedRunPolicy? = .catchUpLatest) -> Scheduler.Item {
            Scheduler.Item(request: request, next: now.addingTimeInterval(-late), rule: rule, missedRunPolicy: policy)
        }
        let tasksFile = root.appendingPathComponent("tasks.json")
        let tasks = TaskStore(file: tasksFile)
        let schedulesFile = root.appendingPathComponent("schedules.json")
        let schedules = Scheduler.Store(file: schedulesFile)
        let first = item()
        check(schedules.add(first), "persists schedule")
        check(schedules.dispatchDue(now: now, enqueue: { _, _ in nil }) == nil, "failed durable queue does not dispatch")
        check(schedules.all.first?.id == first.id, "failed enqueue does not acknowledge schedule")
        check(schedules.storageError != nil, "enqueue failure is surfaced")
        let dispatch = schedules.dispatchDue(now: now) { request, key in
            check(!schedules.all.isEmpty, "schedule remains due before durable enqueue")
            return tasks.enqueue(request.request, source: .mac, background: true, idempotencyKey: key)
        }!
        check(schedules.all.isEmpty, "one-off removed only after enqueue")
        check(tasks.record(dispatch.taskID)?.background == true, "scheduled task is background")
        check(tasks.record(dispatch.taskID)?.dispatchKey == first.occurrenceID, "occurrence key retained")
        check(tasks.start(dispatch.taskID), "starts queued task")
        check(tasks.beginAction(dispatch.taskID, kind: "send"), "side effect checkpoint saved")

        // Simulate crash after task creation but before schedule acknowledgement by restoring the old
        // schedule file while retaining tasks.json. An in-flight send is never started again.
        check(schedules.add(first), "restores unacknowledged schedule")
        let restoredTasks = TaskStore(file: tasksFile)
        let restoredSchedules = Scheduler.Store(file: schedulesFile)
        let recovered = restoredSchedules.dispatchDue(now: now) { request, key in
            restoredTasks.enqueue(request.request, source: .mac, background: true, idempotencyKey: key)
        }!
        check(recovered.taskID == dispatch.taskID, "handoff retry deduplicates existing task")
        check(restoredTasks.records.count == 1, "no duplicate task after crash")
        check(restoredTasks.record(recovered.taskID)?.state == .interrupted, "uncertain send remains interrupted")
        check(!restoredTasks.start(recovered.taskID, explicitlyReviewed: true), "interrupted side effect cannot replay")
        check(restoredTasks.record(recovered.taskID)?.pendingAction == "send", "uncertain outcome retained")

        // Crash before execution retains a reviewable queue rather than silently losing or replaying it.
        let second = item("Queued before crash")
        check(restoredSchedules.add(second), "adds queued crash case")
        let queued = restoredTasks.enqueue(second.request, source: .mac, background: true, idempotencyKey: second.occurrenceID)!
        let again = TaskStore(file: tasksFile)
        let queuedDispatch = restoredSchedules.dispatchDue(now: now) { request, key in
            again.enqueue(request.request, source: .mac, background: true, idempotencyKey: key)
        }!
        check(queuedDispatch.taskID == queued && again.record(queued)?.requiresReview == true, "restored queue requires explicit review")
        check(!again.start(queued), "restored schedule never auto-starts")

        // Acknowledgement failure after durable enqueue must retain both the due occurrence and task.
        let failureURL = root.appendingPathComponent("ack.json")
        let failure = Scheduler.Store(file: failureURL)
        let third = item("Ack failed")
        check(failure.add(third), "adds acknowledgement failure case")
        let original = try Data(contentsOf: failureURL)
        var durableID: UUID?
        let failed = failure.dispatchDue(now: now) { request, key in
            durableID = again.enqueue(request.request, source: .mac, background: true, idempotencyKey: key)
            try! fm.removeItem(at: failureURL)
            try! fm.createDirectory(at: failureURL, withIntermediateDirectories: false)
            return durableID
        }
        check(failed == nil && failure.storageError != nil, "acknowledgement write failure reported")
        check(again.record(durableID)?.state == .queued, "task survives failed acknowledgement in current process")
        try fm.removeItem(at: failureURL)
        try original.write(to: failureURL)
        let recoveredAck = failure.dispatchDue(now: now) { request, key in
            again.enqueue(request.request, source: .mac, background: true, idempotencyKey: key)
        }
        check(recoveredAck?.taskID == durableID, "acknowledgement retry returns same queued task")
        check(failure.all.isEmpty && failure.storageError == nil, "successful acknowledgement clears failure")

        let missed = Scheduler.Store(file: root.appendingPathComponent("missed.json"))
        check(missed.add(item("Catch up", late: 30 * 3600, rule: .hourly)), "adds missed repeat")
        var enqueues = 0
        check(missed.dispatchDue(now: now) { _, _ in enqueues += 1; return UUID() } != nil, "default catches up latest once")
        check(enqueues == 1 && missed.all.first!.next > now, "coalesces backlog into one occurrence")
        check(missed.dispatchDue(now: now) { _, _ in enqueues += 1; return UUID() } == nil && enqueues == 1, "does not replay missed backlog")
        let legacy = Scheduler.Store(file: root.appendingPathComponent("legacy.json"))
        check(legacy.add(item("Legacy skip", late: 3 * 3600, policy: nil)), "adds legacy schedule")
        check(legacy.all.first?.policy == .skipAfterTwoHours, "preserves legacy missed-run policy")
        check(legacy.dispatchDue(now: now) { _, _ in preconditionFailure("must not enqueue skipped job") } == nil, "legacy late occurrence skipped")
        check(legacy.all.isEmpty && legacy.lastNotice != nil, "skipped occurrence is visible")
        let explicitSkip = Scheduler.Store(file: root.appendingPathComponent("skip.json"))
        check(explicitSkip.add(item("Explicit skip", late: 3 * 3600, policy: .skipAfterTwoHours)), "adds explicit skip policy")
        check(explicitSkip.dispatchDue(now: now) { _, _ in preconditionFailure("must not enqueue") } == nil, "explicit skip is enforced")

        let brokenURL = root.appendingPathComponent("broken.json")
        try Data("broken".utf8).write(to: brokenURL)
        let broken = Scheduler.Store(file: brokenURL)
        check(!broken.add(item()) && broken.storageError != nil, "corrupt schedules reject writes")
        check(broken.dispatchDue(now: now) { _, _ in preconditionFailure("must not enqueue") } == nil, "corrupt schedules never dispatch")
        check(try String(contentsOf: brokenURL, encoding: .utf8) == "broken", "corrupt original preserved")
        let scheduleMode = try fm.attributesOfItem(atPath: schedulesFile.path)[.posixPermissions] as? Int
        check(scheduleMode == 0o600, "schedule contents are private")
        check(Scheduler.dailyOccurrence(time: "99:00", now: now, lastRun: nil) == nil, "invalid daily time rejected")
        let midnight = Calendar.current.startOfDay(for: now)
        check(Scheduler.dailyOccurrence(time: "00:00", now: now, lastRun: nil) == midnight, "daily workflow catches up today")
        check(Scheduler.dailyOccurrence(time: "00:00", now: now, lastRun: now) == nil, "acknowledged daily workflow not repeated")
        check(Scheduler.dailyOccurrence(time: "00:00", now: midnight.addingTimeInterval(30), lastRun: nil, catchUp: false) == midnight, "legacy workflow remains eligible within its scheduled minute")
        check(Scheduler.dailyOccurrence(time: "00:00", now: midnight.addingTimeInterval(60), lastRun: nil, catchUp: false) == nil, "legacy workflow does not unexpectedly catch up later")
        check(BackgroundPolicy.route(["do": "verify", "path": "/tmp/report.pdf"], hasWorkerPage: false) == .api, "saved-file verification uses direct tools")
        check(BackgroundPolicy.route(["do": "verify", "text": "Submitted"], hasWorkerPage: true) == .browser, "owned browser verification allowed")
        if case .attention = BackgroundPolicy.route(["do": "verify", "id": "e2", "value": "changed"], hasWorkerPage: true) { checks += 1 }
        else { preconditionFailure("background verification must not inspect native field") }
        if case .attention = BackgroundPolicy.route(["do": "verify", "text": "Submitted"], hasWorkerPage: false) { checks += 1 }
        else { preconditionFailure("no worker must not inspect foreground") }
        print("PASS: \(checks) durable scheduling and recovery checks")
    }
}

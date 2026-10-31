import Foundation
import IOKit.pwr_mgt

@main struct TaskPowerAssertionTests {
    @MainActor static func main() {
        var created: [(String, UInt32)] = [], released: [UInt32] = [], next: UInt32 = 0
        var fail = false, checks = 0
        let manager = TaskPowerAssertions(driver: .init(create: { type, _ in
            if fail { return nil }
            next += 1; created.append((type, next)); return next
        }, release: { released.append($0) }))
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
        check(manager.activeTaskCount == 0 && created.isEmpty, "idle app holds no assertion")
        let a = manager.begin(preventDisplaySleep: false)
        check(created.count == 1 && created[0].0 == kIOPMAssertionTypePreventUserIdleSystemSleep, "background task prevents system idle sleep")
        let b = manager.begin(preventDisplaySleep: false)
        check(created.count == 1 && manager.activeTaskCount == 2, "overlapping tasks share the system assertion")
        let c = manager.begin(preventDisplaySleep: true)
        check(created.count == 2 && created[1].0 == kIOPMAssertionTypePreventUserIdleDisplaySleep, "foreground work additionally keeps display awake")
        manager.end(a); manager.end(a)
        check(manager.activeTaskCount == 2 && released.isEmpty, "duplicate finish never releases another task's lease")
        manager.end(c)
        check(released == [2] && manager.activeTaskCount == 1, "foreground completion releases only display while background work continues")
        manager.update(b, preventDisplaySleep: true)
        check(created.count == 3 && manager.foregroundTaskCount == 1, "foreground handoff acquires display protection")
        manager.end(b)
        check(Set(released) == [1,2,3] && manager.activeTaskCount == 0, "last completion releases all remaining assertions")
        let failedTask = manager.begin(preventDisplaySleep: true)
        manager.end(failedTask)
        check(released.count == 5, "failure and stop use the same idempotent end path")
        _ = manager.begin(preventDisplaySleep: true); _ = manager.begin(preventDisplaySleep: false)
        manager.shutdown(); manager.shutdown()
        check(manager.activeTaskCount == 0 && released.count == 7 && Set(released).count == 7, "quit releases every assertion exactly once with overlapping tasks")
        fail = true
        let missing = manager.begin(preventDisplaySleep: false)
        check(manager.activeTaskCount == 1 && created.count == 7, "creation failure preserves lease accounting without an invalid assertion")
        fail = false
        let retry = manager.begin(preventDisplaySleep: false)
        check(created.count == 8, "a later task retries assertion creation")
        manager.end(missing); manager.end(retry)
        check(released.count == 8, "recovered assertion is released once")
        manager.update(UUID(), preventDisplaySleep: true)
        check(created.count == 8, "expired lease cannot resurrect assertions")
        print("PASS \(checks) task power assertion lifecycle and overlap checks")
    }
}

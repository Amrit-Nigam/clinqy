import Foundation
import IOKit.pwr_mgt

/// One system assertion shared by running tasks, plus a display assertion while foreground work needs it.
/// UUID leases make duplicate finish/stop callbacks harmless; queued tasks own no lease.
@MainActor
final class TaskPowerAssertions {
    struct Driver {
        var create: (_ type: String, _ reason: String) -> IOPMAssertionID?
        var release: (IOPMAssertionID) -> Void
        static let system = Driver(create: { type, reason in
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
            guard result == kIOReturnSuccess else {
                NSLog("Clinqy couldn't create its task power assertion (error %d)", result)
                return nil
            }
            return id
        }, release: { _ = IOPMAssertionRelease($0) })
    }
    static let shared = TaskPowerAssertions()
    private let driver: Driver
    private var leases: [UUID: Bool] = [:]
    private var systemAssertion: IOPMAssertionID?
    private var displayAssertion: IOPMAssertionID?
    var activeTaskCount: Int { leases.count }
    var foregroundTaskCount: Int { leases.values.filter { $0 }.count }
    init(driver: Driver = .system) { self.driver = driver }

    @discardableResult
    func begin(preventDisplaySleep: Bool) -> UUID {
        let token = UUID(); leases[token] = preventDisplaySleep; reconcile(); return token
    }
    func update(_ token: UUID, preventDisplaySleep: Bool) {
        guard leases[token] != nil else { return }
        leases[token] = preventDisplaySleep; reconcile()
    }
    func end(_ token: UUID) {
        guard leases.removeValue(forKey: token) != nil else { return }
        reconcile()
    }
    func shutdown() { leases.removeAll(); reconcile() }

    private func reconcile() {
        if leases.isEmpty {
            if let id = systemAssertion { driver.release(id); systemAssertion = nil }
        } else if systemAssertion == nil {
            systemAssertion = driver.create(kIOPMAssertionTypePreventUserIdleSystemSleep, "Clinqy is running a task")
        }
        if !leases.values.contains(true) {
            if let id = displayAssertion { driver.release(id); displayAssertion = nil }
        } else if displayAssertion == nil {
            displayAssertion = driver.create(kIOPMAssertionTypePreventUserIdleDisplaySleep, "Clinqy is using the Mac screen for a task")
        }
    }
}

import Foundation

enum Secrets { static func mask(_ text: String) -> String { text.replacingOccurrences(of: "test-secret", with: "[private]") } }
@main struct BackgroundTaskTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-task-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tasks.json")
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let store = TaskStore(file: file)
        let id = store.enqueue("Submit a sample form", source: .telegram, conversationID: 42)!
        check(store.start(id), "starts persisted task")
        check(store.beginAction(id, kind: "click"), "writes checkpoint before action")
        let queued = store.enqueue("Next task", source: .telegram, conversationID: 42)!
        let restored = TaskStore(file: file)
        check(restored.record(id)?.state == .interrupted, "running becomes interrupted")
        check(restored.record(id)?.pendingAction == "click", "uncertain action survives restart")
        check(!restored.start(id, explicitlyReviewed: true), "never replays interrupted submit")
        check(!restored.start(queued), "restored queue requires review")
        check(restored.start(queued, explicitlyReviewed: true), "review starts queued request")
        restored.endAction(queued, kind: "read", ok: true, completedSteps: 1)
        check(restored.record(queued)?.lastConfirmedStep == "read", "records confirmed stage")
        restored.finish(queued, ok: true, answer: "Complete")
        let final = TaskStore(file: file)
        check(final.record(queued)?.state == .succeeded, "terminal result retained")
        let secret = final.enqueue("Use test-secret", source: .mac)!
        check(final.record(secret)?.request == "Use [private]", "redacts persisted request")
        check(!final.start(secret, explicitlyReviewed: true), "redacted request must be rewritten")
        let missing = final.enqueue("Upload", files: [root.appendingPathComponent("missing")], source: .mac)!
        check(!final.start(missing) && final.active == nil, "missing attachment cannot run or block queue")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        check(mode == 0o600, "history is private")
        let bad = root.appendingPathComponent("broken.json")
        try Data("broken".utf8).write(to: bad)
        let corrupt = TaskStore(file: bad)
        check(corrupt.enqueue("No execution", source: .mac) == nil, "corrupt storage fails closed")
        check(try String(contentsOf: bad, encoding: .utf8) == "broken", "preserves corrupt original")
        func denied(_ action: [String: Any]) -> Bool { if case .attention = BackgroundPolicy.route(action, hasWorkerPage: true) { return true }; return false }
        for action: [String: Any] in [["do":"open_app","name":"Finder"], ["do":"shell"], ["do":"applescript"], ["do":"paste_snaps"], ["do":"files","op":"reveal"], ["do":"key","keys":"cmd+v"], ["do":"table","to":"clipboard"], ["do":"click","id":"e2"]] {
            check(denied(action), "blocks shared desktop action: \(action)")
        }
        check(BackgroundPolicy.route(["do":"files","op":"list"], hasWorkerPage: false) == .api, "Finder work routes to filesystem")
        check(BackgroundPolicy.route(["do":"type","id":"w2"], hasWorkerPage: true) == .browser, "owned web field allowed")
        check(BackgroundPolicy.route(["do":"key","keys":"cmd+a"], hasWorkerPage: true) == .browser, "owned select-all allowed")
        print("PASS: \(checks) task recovery and background policy checks")
    }
}

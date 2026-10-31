import Foundation

@main struct ComputerControlTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label); checks += 1
        }
        let now = Date(timeIntervalSince1970: 1000)
        var lease = ControlLease(now: now)
        let token = lease.observe(now: now)
        check(lease.accepts(session: lease.session, now: now), "lease owner accepted")
        check(!lease.accepts(session: "other", now: now), "other client refused")
        check(!lease.accepts(session: lease.session, now: now.addingTimeInterval(121)), "expired owner refused")
        check(!lease.consume("stale", now: now), "wrong observation refused")
        check(lease.consume(token, now: now), "first delivery permitted")
        check(!lease.consume(token, now: now), "retry cannot redeliver after lost reply")
        let next = lease.observe(now: now)
        check(next != token && lease.consume(next, now: now), "fresh observation accepted")
        for kind in PointerGesture.Kind.allCases {
            let start = PointerGesture.Point(x: 10, y: 20), end = PointerGesture.Point(x: 100, y: 200)
            let plan = PointerGesture(kind: kind, start: start, end: kind == .drag ? end : nil)!
            var held = false
            for event in plan.events {
                if event.phase == .down { check(!held, "never press twice without release"); held = true }
                if event.phase == .up { check(held, "release follows press"); held = false }
                if event.phase == .move && event.held { check(held, "drag moves keep button held") }
            }
            check(!held, "gesture releases button")
            check(plan.events.first!.point == start, "gesture starts at observed source")
            if kind == .drag { check(plan.events.last!.point == end, "drag ends at observed destination") }
            if kind == .double_click { check(plan.events.filter { $0.phase == .down }.map(\.count) == [1, 2], "double click carries click counts") }
            if kind == .right_click { check(plan.events.filter { $0.phase == .down }.allSatisfy(\.right), "context click uses right button") }
        }
        check(PointerGesture(kind: .drag, start: .init(x: 1, y: 2)) == nil, "drag needs destination")
        check(PointerGesture(kind: .hover, start: .init(x: .nan, y: 2)) == nil, "nonfinite coordinates refused")
        check(ControlProtocol.validate(["do": "shell", "cmd": "anything"]) != nil, "no direct arbitrary scripts")
        check(ControlProtocol.validate(["do": "drag", "id": "w3"]) != nil, "incomplete drag refused")
        check(ControlProtocol.validate(["do": "drag", "id": "w3", "to_id": "w8"]) == nil, "semantic drag accepted")
        check(ControlProtocol.validate(["do": "click", "x": true, "y": 4]) != nil, "boolean is not coordinate")
        check(ControlProtocol.validate(["do": "click", "x": Double.infinity, "y": 4]) != nil, "infinite coordinate refused")
        check(ControlProtocol.validate(["do": "wait", "for": "Saved", "seconds": 16]) != nil, "bounded wait")
        check(ControlProtocol.validate(["do": "verify", "value": "A"]) != nil, "field check needs identity")
        check(ControlProtocol.validate(["do": "verify", "text": "Saved", "contains": "A"]) != nil, "contains requires file")
        check(ControlProtocol.validate(["do": "type", "text": "A", "submit": "true"]) != nil, "string not boolean")
        check(ControlProtocol.validate(["do": "click", "id": "w1", "script": "x"]) != nil, "unknown keys refused")
        check(ControlProtocol.validateRequest(["op": "observe", "task": "Read the page"]) == nil, "initial control goal accepted")
        check(ControlProtocol.validateRequest(["op": "observe", "task": "Read", "image": "false"]) != nil, "image flag must be boolean")
        check(ControlProtocol.validateRequest(["op": "act", "action": ["do": "click", "id": "w1"]]) != nil, "no action without ownership")
        check(ControlProtocol.validateRequest(["op": "release", "session": lease.session, "complete": true]) == nil, "owned release request accepted")
        check(ControlProtocol.validateRequest(["op": "act", "session": lease.session, "observation": UUID().uuidString,
                                              "action": ["do": "shell"]]) != nil, "unsupported action refused before app launch")
        for browser in ["Chrome", "Google Chrome", "Arc", "Brave", "Brave Browser", "Edge", "Microsoft Edge", "browser"] {
            check(BackgroundPolicy.route(["do": "open_app", "name": browser], hasWorkerPage: false) == .browser,
                  "opening a supported browser stays in the background: \(browser)")
        }
        if case .attention = BackgroundPolicy.route(["do": "open_app", "name": "TextEdit"], hasWorkerPage: false) { checks += 1 }
        else { preconditionFailure("native app was treated as a background browser") }
        for kind in ["hover", "right_click", "double_click", "drag"] {
            let web: [String: Any] = ["do": kind, "id": "w1", "to_id": "w2"]
            check(BackgroundPolicy.route(web, hasWorkerPage: true) == .browser, "owned semantic gesture stays in browser")
            if case .attention = BackgroundPolicy.route(web, hasWorkerPage: false) { checks += 1 }
            else { preconditionFailure("gesture fell through without owned page") }
            if case .attention = BackgroundPolicy.route(["do": kind, "id": "e1"], hasWorkerPage: true) { checks += 1 }
            else { preconditionFailure("native gesture leaked into background") }
        }
        var goal = CompletionEvidence()
        check(!goal.needsVerification, "read-only goal needs no mutation proof")
        goal.record(kind: "files", outcome: .confirmed, op: "list")
        check(!goal.needsVerification, "file listing isn't an edit")
        goal.record(kind: "shell", outcome: .confirmed)
        check(goal.needsVerification, "exit zero does not prove a goal")
        goal.record(kind: "look", outcome: .confirmed)
        check(goal.needsVerification, "image isn't a checked postcondition")
        goal.record(kind: "verify", outcome: .failed)
        check(goal.needsVerification, "failed verification doesn't clear goal")
        goal.record(kind: "verify", outcome: .confirmed)
        check(!goal.needsVerification, "checked postcondition clears goal")
        goal.record(kind: "drag", outcome: .uncertain)
        check(goal.needsVerification, "later uncertain mutation invalidates proof")
        check(!VisionPolicy.capture(mode: .minimal, explicit: false, first: true, native: true, changed: true,
                                   documentChanged: true, knownElements: 10, failures: 0), "minimal stays explicit")
        for mode in [VisionPolicy.Mode.auto, .always, .minimal] {
            check(VisionPolicy.capture(mode: mode, explicit: true, first: false, native: false, changed: false,
                                       documentChanged: false, knownElements: 20, failures: 0), "explicit look always honored")
        }
        check(VisionPolicy.capture(mode: .auto, explicit: false, first: true, native: false, changed: false,
                                   documentChanged: false, knownElements: 20, failures: 0), "initial image even with rich DOM")
        check(VisionPolicy.capture(mode: .auto, explicit: false, first: false, native: true, changed: true,
                                   documentChanged: false, knownElements: 20, failures: 0), "native transition image")
        check(!VisionPolicy.capture(mode: .auto, explicit: false, first: false, native: false, changed: true,
                                    documentChanged: false, knownElements: 20, failures: 0), "ordinary DOM changes keep fast path")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("result.txt")
        try "the expected paragraph".write(to: file, atomically: true, encoding: .utf8)
        let baseline = Date().addingTimeInterval(-5)
        check(SavedFileEvidence.check(path: file.path, since: baseline, contains: "expected paragraph") != nil, "artifact actual contents verified")
        check(SavedFileEvidence.check(path: file.path, since: baseline, contains: "fabricated result") == nil, "wrong artifact contents refused")
        check(SavedFileEvidence.check(path: file.path, since: Date().addingTimeInterval(10)) == nil, "old artifact cannot prove new write")
        check(SavedFileEvidence.check(path: dir.path, since: baseline) == nil, "directory isn't saved artifact")
        try Data().write(to: file)
        check(SavedFileEvidence.check(path: file.path, since: baseline) == nil, "empty artifact refused")
        let graph = ["field": ["sheet"], "sheet": ["main"], "main": ["app"], "otherField": ["otherWindow"], "otherWindow": ["app"], "cycle": ["cycle"]]
        check(NativeWindowHierarchy.contains("field", root: "main", parents: { graph[$0] ?? [] }, equal: ==), "field inside attached sheet belongs to the exact observed window")
        check(!NativeWindowHierarchy.contains("otherField", root: "main", parents: { graph[$0] ?? [] }, equal: ==), "another window in the same app is still rejected")
        check(!NativeWindowHierarchy.contains("cycle", root: "main", parents: { graph[$0] ?? [] }, equal: ==), "cyclic accessibility parents fail safely")
        check(NativeWindowHierarchy.contains("main", root: "main", parents: { graph[$0] ?? [] }, equal: ==), "exact observed root remains valid")
        check(TaskCompletionPolicy.reportsFailure("I couldn't send the screenshot to WhatsApp."), "explicit failed send cannot be labelled successful")
        check(TaskCompletionPolicy.reportsFailure("Unable to attach the image."), "blocked attachment is a failed result")
        check(!TaskCompletionPolicy.reportsFailure("Sent the photo and verified it in the chat."), "verified successful send remains successful")
        check(!TaskCompletionPolicy.requestsWriteUp("Send me a screenshot of Cursor app"), "standalone screenshot does not force a document")
        check(!TaskCompletionPolicy.requestsWriteUp("Send it on WhatsApp\n\nPrevious Telegram task: Create a doc and paste screenshots"), "follow-up context cannot force a new write-up")
        check(TaskCompletionPolicy.requestsWriteUp("Create a guide with the screenshots in a Google Doc"), "actual write-up still requires screenshot insertion")
        check(!TaskCompletionPolicy.requestsWriteUp("Do not create a document; send the screenshot"), "explicit no-document request respected")
        print("PASS \(checks) gesture, ownership, replay refusal, vision and final artifact checks")
    }
}

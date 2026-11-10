import Foundation
import CryptoKit

@main struct ComputerControlTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label); checks += 1
        }
        let now = Date(timeIntervalSince1970: 1000)
        check(VisualEvidencePolicy.accepts(run: "r", observedRun: "r", sameTarget: true, observedAt: now, actionAt: now.addingTimeInterval(-1)), "fresh scoped evidence accepted")
        check(!VisualEvidencePolicy.accepts(run: "r", observedRun: "old", sameTarget: true, observedAt: now, actionAt: now.addingTimeInterval(-1)), "previous run evidence refused")
        check(!VisualEvidencePolicy.accepts(run: "r", observedRun: "r", sameTarget: false, observedAt: now, actionAt: now.addingTimeInterval(-1)), "unrelated target evidence refused")
        check(!VisualEvidencePolicy.accepts(run: "r", observedRun: "r", sameTarget: true, observedAt: now, actionAt: now), "pre-action evidence refused")
        check(!VisualEvidencePolicy.sameDocument(nil, nil), "restored missing document identity refused")
        check(!VisualEvidencePolicy.sameDocument("old", "new"), "navigated document refused")
        check(VisualEvidencePolicy.sameDocument("same", "same"), "same document accepted")
        check(!VisualEvidencePolicy.exhaustedCompletionAttempts(2) && VisualEvidencePolicy.exhaustedCompletionAttempts(3), "completion recovery bounded at three")
        check(ObservationRecoveryPolicy.canRetry(attempts: 0), "first observation failure gets fresh observation")
        check(ObservationRecoveryPolicy.canRetry(attempts: 1), "second observation failure gets final recovery")
        check(!ObservationRecoveryPolicy.canRetry(attempts: 2), "repeated observation failures stop without replay")
        let inferred = AutonomousInspectionPolicy.verificationAction(["user_confirms": "Receipt ready", "visual": "guess"], claim: "Receipt ready")
        check(inferred["user_confirms"] == nil && inferred["visual"] == nil, "inspection cannot recursively ask or accept visual guesses")
        check(inferred["text"] as? String == "Receipt ready", "fallback checks exact claim, never inferred success")
        let explicit = AutonomousInspectionPolicy.verificationAction(["user_confirms": "saved", "path": "/tmp/result", "contains": "expected"], claim: "saved")
        check(explicit["path"] as? String == "/tmp/result" && explicit["contains"] as? String == "expected" && explicit["text"] == nil, "artifact evidence preserved ahead of claim text")
        let hiddenHint = VerificationEvidence.browserText(["title": "Practice", "text": "Show hint", "nativeText": "Hint: SAPPHIRE"])
        let revealedHint = VerificationEvidence.browserText(["title": "Practice", "text": "Show hint\nHint: SAPPHIRE"])
        check(VerificationEvidence.newText("Hint: SAPPHIRE", before: hiddenHint, after: revealedHint), "unrelated native text cannot suppress new task DOM evidence")
        check(!VerificationEvidence.newText("Hint: SAPPHIRE", before: revealedHint, after: revealedHint), "preexisting task DOM hint remains insufficient")
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
        check(BackgroundPolicy.route(["do": "set_state", "id": "w2", "state": 6], hasWorkerPage: true) == .browser,
              "range state uses the owned browser page")
        for action: [String: Any] in [["do": "set_state", "id": "e2", "state": 6], ["do": "set_state", "state": 6]] {
            if case .attention = BackgroundPolicy.route(action, hasWorkerPage: true) { checks += 1 }
            else { preconditionFailure("range accepted a native or missing target") }
        }
        let conditionWait: [String: Any] = ["do": "wait", "condition": ["kind": "ready"]]
        check(BackgroundPolicy.route(conditionWait, hasWorkerPage: true) == .browser, "structured waits require browser routing")
        if case .attention = BackgroundPolicy.route(conditionWait, hasWorkerPage: false) { checks += 1 }
        else { preconditionFailure("structured wait accepted absent owned page") }
        check(BackgroundPolicy.route(["do": "wait", "ms": 100], hasWorkerPage: false) == .api, "plain delay requires no browser")
        // Delivered is not confirmed, but it is not a failure either.
        check(ActionOutcome.unverified.delivered && ActionOutcome.confirmed.delivered, "delivered input is ok")
        check(!ActionOutcome.uncertain.delivered && !ActionOutcome.failed.delivered && !ActionOutcome.refused.delivered, "unknown delivery, failure and refusal are not ok")
        // Consequential classification.
        check(ConsequentialInput.classify(kind: "click", riskyLabel: true) && !ConsequentialInput.classify(kind: "click"), "risky label decides a click")
        check(ConsequentialInput.classify(kind: "type", submit: true) && !ConsequentialInput.classify(kind: "type"), "submit:true is consequential")
        check(ConsequentialInput.classify(kind: "key", keys: "return") && ConsequentialInput.classify(kind: "key", keys: "cmd+s")
              && !ConsequentialInput.classify(kind: "key", keys: "cmd+a") && !ConsequentialInput.classify(kind: "key", keys: "tab"), "risky keys")
        check(ConsequentialInput.classify(kind: "shell") && ConsequentialInput.classify(kind: "applescript") && ConsequentialInput.classify(kind: "email"), "scripts and email")
        // Receipt → outcome.
        let modal = EffectReceipt(dialogOpened: true, mutationCount: 4)
        let added = EffectReceipt(addedText: "Item added to your cart", mutationCount: 2)
        let ripple = EffectReceipt(focusChanged: true, mutationCount: 3)
        let clock = EffectReceipt(addedText: "10:42:01", removedText: "10:42:00", mutationCount: 2)
        let rerender = EffectReceipt(addedText: "Cart | Checkout", removedText: "Checkout | Cart", mutationCount: 6)
        check(EffectClassification.click(receipt: modal, consequential: false, expectation: nil) == .confirmed, "opened dialog confirms an ordinary click")
        check(EffectClassification.click(receipt: added, consequential: false, expectation: nil) == .confirmed, "new text confirms an ordinary click")
        check(EffectClassification.click(receipt: EffectReceipt(urlChanged: true), consequential: false, expectation: nil) == .confirmed, "navigation confirms")
        check(EffectClassification.click(receipt: EffectReceipt(targetStateChanged: true), consequential: false, expectation: nil) == .confirmed, "target state confirms")
        check(EffectClassification.click(receipt: ripple, consequential: false, expectation: nil) == .unverified, "focus or attribute churn is not an effect")
        check(EffectClassification.click(receipt: clock, consequential: false, expectation: nil) == .unverified, "digit-only text churn is not attributable")
        check(EffectClassification.click(receipt: rerender, consequential: false, expectation: nil) == .unverified, "re-rendered identical text is not new")
        let ago = EffectReceipt(addedText: "4 seconds ago", removedText: "3 seconds ago", mutationCount: 2)
        check(EffectClassification.click(receipt: ago, consequential: false, expectation: nil) == .unverified, "time-ago churn is not attributable")
        check(EffectClassification.click(receipt: EffectReceipt(addedText: "Updated just now", mutationCount: 1), consequential: false, expectation: nil) == .unverified,
              "a relative timestamp alone is not attributable")
        check(EffectClassification.click(receipt: EffectReceipt(addedText: "Step 2 of 3", removedText: "Step 1 of 3", mutationCount: 2), consequential: false, expectation: nil) == .confirmed,
              "a wizard step change in the target's container confirms")
        check(EffectClassification.click(receipt: EffectReceipt(focusIntoNew: true, mutationCount: 2), consequential: false, expectation: nil) == .confirmed,
              "focus moving into newly added content confirms")
        check(EffectReceipt(["mutationCount": 2, "focusIntoNew": true])?.focusIntoNew == true, "focusIntoNew parsed from the extension")
        check(EffectClassification.click(receipt: EffectReceipt(focusChanged: true, mutationCount: 5), consequential: false, expectation: nil) == .unverified,
              "focus merely moving is still not an effect")
        check(EffectClassification.click(receipt: nil, consequential: false, expectation: nil) == .unverified, "no receipt cannot confirm")
        check(EffectClassification.click(receipt: added, consequential: true, expectation: nil) == .unverified, "a submit is never confirmed by any page change")
        check(EffectClassification.click(receipt: nil, consequential: true, expectation: true) == .confirmed, "a met expectation confirms even a submit")
        check(EffectClassification.click(receipt: added, consequential: false, expectation: false) == .unverified, "an unmet expectation overrides a page change")
        check(EffectReceipt(["mutationCount": 0, "urlChanged": false, "structural": false]).map(\.keepsListing) == true, "quiet receipt keeps the listing")
        check(EffectReceipt(["mutationCount": 3, "structural": true])?.keepsListing == false, "added elements force a relist")
        check(EffectReceipt(["mutationCount": 1])?.keepsListing == false, "older receipts without structure info relist")
        check(EffectReceipt(nil) == nil && EffectReceipt(["clicked": true]) == nil, "non-receipt replies are not receipts")
        check(EffectReceipt(addedText: "Saved | Draft", removedText: "Draft").netAddedText == "Saved", "net added text excludes re-rendered text")
        // Normalised readback.
        check(FieldReadback.matches(expected: "Amrit Nigam", actual: " amrit  nigam "), "case and whitespace reformatting is a match")
        check(FieldReadback.matches(expected: "9845012345", actual: "98450 12345"), "spaced phone is a match")
        check(FieldReadback.matches(expected: "9845012345", actual: "+91 98450-12345"), "country-code prefixed phone is a match")
        check(FieldReadback.matches(expected: "(555) 123-4567", actual: "5551234567"), "punctuation-free phone is a match")
        check(!FieldReadback.matches(expected: "9845012345", actual: "9845012346"), "different digits are a mismatch")
        check(!FieldReadback.matches(expected: "9845012345", actual: "19845012345"), "an extra digit without a country code is a mismatch")
        check(!FieldReadback.matches(expected: "Pune", actual: "Mumbai") && !FieldReadback.matches(expected: "Pune", actual: nil), "real mismatch or unreadable")
        check(!FieldReadback.matches(expected: "1,000", actual: "1000.00"), "amount reformatting with other digits is not assumed equal")
        // verify text: new, more frequent, or in the receipt's added text.
        check(VerificationEvidence.textEvidence("Item added", before: "Cart", after: "Cart Item added"), "newly present text")
        check(VerificationEvidence.textEvidence("Item added", before: "Item added", after: "Item added Item added"), "count rose")
        check(!VerificationEvidence.textEvidence("Item added", before: "Item added", after: "Item added"), "unchanged count is not evidence")
        check(VerificationEvidence.textEvidence("Saved", before: "Saved", after: "Saved", added: "Saved just now"), "receipt saw it added")
        check(!VerificationEvidence.textEvidence("Paid", before: "unpaid", after: "unpaid unpaid"), "fragments never count")
        check(!VerificationEvidence.textEvidence("Receipt", before: nil, after: "Receipt 123"), "missing baseline without a receipt is not evidence")
        check(VerificationEvidence.occurrences("ab", in: "ab ab abc ab") == 3, "whole-word occurrences")
        // Inline expect.
        check(ActionExpectation.problem(["text": "Added"]) == nil && ActionExpectation.problem("Added") == nil, "expect forms accepted")
        check(ActionExpectation.problem(["text": "A", "url": "/b"]) != nil && ActionExpectation.problem(["title": "x"]) != nil && ActionExpectation.problem(["text": ""]) != nil, "malformed expect refused")
        check(ActionContract.validate(["do": "click", "id": "w1", "expect": ["url": "/cart"]]) == nil, "click accepts expect")
        check(ActionContract.validate(["do": "type", "id": "w1", "text": "x", "expect": ["value": "x"]]) == nil, "type accepts expect")
        check(ActionContract.validate(["do": "key", "keys": "return", "expect": "Sent"]) == nil, "key accepts expect")
        check(ActionContract.validate(["do": "click", "id": "w1", "expect": ["colour": "red"]]) != nil, "bad expect is refused before input")
        check(ActionContract.validate(["do": "scroll", "dir": "down", "expect": "x"]) != nil, "expect only where it is read")
        check(VerificationEvidence.expectationMet(kind: "url", value: "/cart", beforeURL: "https://s.test/p", afterURL: "https://s.test/cart",
              beforeText: nil, afterText: nil, addedText: nil, fieldValue: nil), "changed URL meets url expectation")
        check(!VerificationEvidence.expectationMet(kind: "url", value: "/cart", beforeURL: "https://s.test/cart", afterURL: "https://s.test/cart",
              beforeText: nil, afterText: nil, addedText: nil, fieldValue: nil), "unchanged URL never meets it")
        check(VerificationEvidence.expectationMet(kind: "value", value: "9845012345", beforeURL: nil, afterURL: nil,
              beforeText: nil, afterText: nil, addedText: nil, fieldValue: "+91 98450 12345"), "value expectation uses normalised readback")
        check(!VerificationEvidence.expectationMet(kind: "text", value: "Sent", beforeURL: nil, afterURL: nil,
              beforeText: "Sent", afterText: "Sent", addedText: "", fieldValue: nil), "pre-existing text never meets a text expectation")
        // Completion evidence: CONFIRMED and ordinary delivered input need no separate verify; consequential gaps do.
        var ordinary = CompletionEvidence()
        ordinary.record(kind: "click", outcome: .unverified)
        ordinary.record(kind: "type", outcome: .confirmed)
        check(!ordinary.needsVerification, "ordinary delivered input needs no separate verify")
        ordinary.record(kind: "click", outcome: .unverified, consequential: true)
        check(ordinary.needsVerification, "unconfirmed submit needs evidence")
        ordinary.record(kind: "verify", outcome: .confirmed)
        check(!ordinary.needsVerification, "verify clears it")
        ordinary.record(kind: "click", outcome: .confirmed, consequential: true)
        check(!ordinary.needsVerification, "a submit confirmed by its expect needs nothing more")
        ordinary.record(kind: "key", outcome: .uncertain)
        check(ordinary.needsVerification, "unknown delivery always needs evidence")
        ordinary.acknowledgeUnconfirmed()
        check(!ordinary.needsVerification, "reported unconfirmed item closes the gate")
        check(CompletionEvidence.needsEvidence(kind: "set_value", outcome: .uncertain)
              && CompletionEvidence.needsEvidence(kind: "secondary_action", outcome: .uncertain), "native set_value/secondary_action are mutations")
        check(CompletionGate.decide(missingEvidence: false, reminders: 0) == .finish, "nothing missing finishes")
        check(CompletionGate.decide(missingEvidence: true, reminders: 0) == .remind, "first done reminds once")
        check(CompletionGate.decide(missingEvidence: true, reminders: 1) == .finishUnconfirmed, "then finishes as done with an unconfirmed item, never a failure")
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
        // --- Action contract: arguments the dispatcher would ignore must never change classification ---
        func classified(_ action: [String: Any]) -> Bool {
            var evidence = CompletionEvidence()
            // Unknown delivery always needs evidence for a mutation, so only `op` can change the classification here.
            evidence.record(kind: action["do"] as! String, outcome: .uncertain, op: action["op"] as? String ?? "")
            return evidence.needsVerification
        }
        check(classified(["do": "type", "id": "w1", "text": "x"]), "uncertain type dirties completion evidence")
        check(classified(["do": "type", "id": "w1", "text": "x", "op": "list"]), "type with unrelated op still dirties evidence")
        check(classified(["do": "shell", "cmd": "touch a", "op": "info"]), "shell with op:info still dirties evidence")
        check(classified(["do": "click", "id": "w1", "op": "check"]), "click with op:check still dirties evidence")
        check(!classified(["do": "pdf", "op": "info", "files": ["a.pdf"]]), "pdf info really is read only")
        check(classified(["do": "pdf", "op": "compress", "files": ["a.pdf"]]), "pdf compress is a mutation")
        check(ActionContract.validate(["do": "type", "id": "w1", "text": "x", "op": "list"]) != nil, "type rejects unused op")
        check(ActionContract.validate(["do": "shell", "cmd": "ls", "op": "info"]) != nil, "shell rejects unused op")
        check(ActionContract.validate(["do": "type", "id": "w1", "text": "x"]) == nil, "valid type accepted")
        check(ActionContract.validate(["do": "click", "id": "w1", "x": 1, "y": 2]) != nil, "click with two target modes rejected")
        check(ActionContract.validate(["do": "click", "id": "w1", "label": "hi"]) != nil, "click rejects unknown argument")
        check(ActionContract.validate(["do": "application", "op": "delete", "company": "X"]) != nil, "unknown application op rejected")
        check(ActionContract.validate(["do": "application", "op": "record", "company": "X", "role": "Y"]) == nil, "application record accepted")
        check(ActionContract.validate(["do": "scroll", "dir": "sideways"]) != nil, "unknown scroll direction rejected")
        check(ActionContract.validate(["do": "scroll"]) != nil, "missing scroll direction rejected")
        check(ActionContract.validate(["do": "scroll", "dir": "UP"]) == nil, "scroll direction is case-insensitive")
        check(ActionContract.validate(["do": "window", "op": "fullscreen", "on": "no"]) != nil, "malformed fullscreen on rejected")
        check(ActionContract.validate(["do": "window", "op": "fullscreen", "on": false]) == nil, "boolean fullscreen on accepted")
        check(ActionContract.validate(["do": "window", "op": "resize", "w": 1, "h": 2, "on": true]) != nil, "on only applies to fullscreen")
        check(ActionContract.validate(["do": "verify", "text": "Done", "path": "/tmp/a.txt"]) != nil, "verify with two predicates rejected")
        check(ActionContract.validate(["do": "verify", "url": "https://a", "text": "x"]) != nil, "verify url+text rejected")
        check(ActionContract.validate(["do": "verify", "id": "w1", "value": "v", "text": "x"]) != nil, "verify value+text rejected")
        check(ActionContract.validate(["do": "verify", "path": "/tmp/a", "contains": "x"]) == nil, "verify path+contains is one predicate")
        check(ActionContract.validate(["do": "verify", "id": "w1", "value": "v"]) == nil, "verify field value accepted")
        check(ActionContract.validate(["do": "verify", "value": "v"]) != nil, "verify value needs an id")
        check(ActionContract.validate(["do": "verify", "user_confirms": "uploaded"]) == nil, "verify user_confirms is a single predicate")
        check(ActionContract.validate(["do": "verify"]) != nil, "verify needs a predicate")
        // --- Exact value before submit ---
        check(SubmitReadback.allows(expected: "hello", actual: "hello"), "exact value may submit")
        check(!SubmitReadback.allows(expected: "hello", actual: "hello!"), "changed value must not submit")
        check(!SubmitReadback.allows(expected: "hello", actual: nil), "unreadable value must not submit")
        check(SubmitReadback.allows(expected: "secret", actual: nil, unreadable: true), "secure field cannot be read back and is not blocked on that alone")
        // --- Typed artifact verification ---
        let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artifacts) }
        let since = Date().addingTimeInterval(-5)
        let goodJSON = artifacts.appendingPathComponent("a.json"), badJSON = artifacts.appendingPathComponent("b.json")
        try "{\"a\": 1}".write(to: goodJSON, atomically: true, encoding: .utf8)
        try "{\"a\": ".write(to: badJSON, atomically: true, encoding: .utf8)
        check(SavedFileEvidence.check(path: goodJSON.path, since: since) != nil, "valid JSON artifact verified")
        check(SavedFileEvidence.check(path: badJSON.path, since: since) == nil, "truncated JSON artifact refused")
        let goodCSV = artifacts.appendingPathComponent("a.csv"), mergedCSV = artifacts.appendingPathComponent("b.csv"), quotedCSV = artifacts.appendingPathComponent("c.csv")
        try "a,b\n1,2\n".write(to: goodCSV, atomically: true, encoding: .utf8)
        try "a,b\n1,2 3,4,5\n".write(to: mergedCSV, atomically: true, encoding: .utf8)
        try "a,b\n\"x,y\",\"line\nbreak\"\n".write(to: quotedCSV, atomically: true, encoding: .utf8)
        check(SavedFileEvidence.check(path: goodCSV.path, since: since) != nil, "rectangular CSV verified")
        check(SavedFileEvidence.check(path: mergedCSV.path, since: since) == nil, "ragged CSV (merged records) refused")
        check(SavedFileEvidence.check(path: quotedCSV.path, since: since) != nil, "quoted CSV fields with delimiters and newlines stay rectangular")
        let pdf = artifacts.appendingPathComponent("a.pdf"), cutPDF = artifacts.appendingPathComponent("b.pdf")
        try "%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n%%EOF\n".write(to: pdf, atomically: true, encoding: .utf8)
        try "%PDF-1.4\n1 0 obj\n<<>>\n".write(to: cutPDF, atomically: true, encoding: .utf8)
        check(SavedFileEvidence.check(path: pdf.path, since: since) != nil, "complete PDF verified")
        check(SavedFileEvidence.check(path: cutPDF.path, since: since) == nil, "truncated PDF refused")
        let report = SavedFileEvidence.check(path: goodJSON.path, since: since) ?? ""
        check(report.contains("bytes") && report.contains("sha256") == false, "report includes size")
        let digest = SHA256.hash(data: Data("{\"a\": 1}".utf8)).map { String(format: "%02x", $0) }.joined()
        check(SavedFileEvidence.check(path: goodJSON.path, since: since, sha256: digest) != nil, "matching sha256 verified")
        check(SavedFileEvidence.check(path: goodJSON.path, since: since, sha256: String(repeating: "0", count: 64)) == nil, "wrong sha256 refused")
        check(SavedFileEvidence.check(path: goodJSON.path, since: since, minBytes: 1000) == nil, "too-small artifact refused")
        // --- A: unresolved input is carried; visual route is limited ---
        var carried = CompletionEvidence()
        carried.markUnverifiedCarryover()
        check(carried.needsVerification, "an unresolved input from an earlier segment keeps the goal unverified")
        carried.record(kind: "verify", outcome: .confirmed)
        check(!carried.needsVerification, "an explicit confirmed verify clears it")
        // --- B: valid url verify shape is not reported as malformed ---
        check(ActionContract.validate(["do": "verify", "url": "https://example.com/lab"]) == nil, "url-only verify is a well-formed request")
        check(URLEvidence.evaluate(expected: "https://a/b", current: "https://a/b", pendingURL: "https://a/b", hasPending: true) == .unchangedSincePending,
              "unchanged URL is reported as unchanged, not as a malformed verify")
        check(URLEvidence.evaluate(expected: "https://a/b", current: "https://a/b", pendingURL: "https://a/", hasPending: true) == .confirmed, "navigated URL confirms")
        check(URLEvidence.evaluate(expected: "https://a/b", current: "https://a/b", pendingURL: nil, hasPending: false) == .confirmed, "no pending input: current URL confirms")
        check(URLEvidence.evaluate(expected: "https://a/b", current: "https://c", pendingURL: "https://a/", hasPending: true) == .notReached, "different URL is not reached")
        struct BridgeDown: Error {}
        check(InputDelivery.pageScroll(error: BridgeDown()).status == .failed && !InputDelivery.pageScroll(error: BridgeDown()).isConfirmed, "a thrown page scroll never reports success")
        check(InputDelivery.pageScroll(error: nil).isConfirmed, "a completed page scroll is confirmed")
        check(InputDelivery.returnPress(delivered: false) == .uncertain && InputDelivery.returnPress(delivered: false).needsVerification, "an undelivered Return is uncertain and blocks replay")
        check(InputDelivery.returnPress(delivered: true) == .unverified, "a delivered Return still needs an application outcome")
        // --- Desktop options are validated, never ignored ---
        check(ActionContract.validate(["do": "click", "x": 1, "y": 2, "button": "right", "count": 2, "modifiers": ["cmd"], "duration_ms": 200]) == nil, "click options accepted")
        check(ActionContract.validate(["do": "click", "id": "e1", "button": "side"]) != nil, "unknown button refused")
        check(ActionContract.validate(["do": "click", "id": "e1", "count": 9]) != nil, "bad count refused")
        check(ActionContract.validate(["do": "hover", "id": "e1", "button": "right"]) != nil, "click options on another action refused")
        check(ActionContract.validate(["do": "scroll", "dir": "left", "unit": "pixels", "amount": 300]) == nil, "native scroll options accepted")
        check(ActionContract.validate(["do": "scroll", "dir": "down", "unit": "pages"]) != nil, "unit without amount refused")
        check(ActionContract.validate(["do": "scroll", "dir": "up", "direction": "down"]) != nil, "dir and direction together refused")
        check(ActionContract.validate(["do": "type", "id": "e1", "text": "x", "mode": "insert"]) == nil, "type insert accepted")
        check(ActionContract.validate(["do": "type", "id": "e1", "text": "x", "mode": "insert", "submit": true]) != nil, "insert cannot submit")
        check(ActionContract.validate(["do": "type", "id": "e1", "text": "x", "mode": "splice"]) != nil, "unknown mode refused")
        check(ActionContract.validate(["do": "set_state", "id": "e4", "state": "on"]) == nil, "set_state accepted")
        check(ActionContract.validate(["do": "set_state", "state": "on"]) != nil, "set_state needs id")
        check(classified(["do": "set_state", "id": "e4", "state": "on"]), "set_state dirties completion evidence")
        check(ControlProtocol.validate(["do": "click", "x": 1, "y": 2, "button": "right"]) == nil, "direct click options accepted")
        check(ControlProtocol.validate(["do": "scroll", "dir": "up", "button": "right"]) != nil, "direct click options only on click")
        check(ControlProtocol.validate(["do": "scroll", "direction": "right", "unit": "lines", "amount": 5]) == nil, "direct scroll options accepted")
        print("PASS \(checks) gesture, ownership, replay refusal, vision and final artifact checks")
    }
}

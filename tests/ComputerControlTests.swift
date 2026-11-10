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
        // A sent chat message on a native window: the AX text dump gains a new "hello" row (count rose), even though
        // an earlier message in the conversation already said "hello"; an unchanged dump is no evidence.
        let chatBefore = "Compose message \nhello \nSee you"
        let chatAfter = "Compose message \nhello \nSee you\nhello \n10:42"
        check(VerificationEvidence.textEvidence("hello", before: chatBefore, after: chatAfter), "native chat row count rise is evidence")
        check(!VerificationEvidence.textEvidence("hello", before: chatBefore, after: chatBefore), "unchanged native text is not evidence")
        check(VerificationEvidence.textEvidence("hello", before: "Compose message ", after: "Compose message \nhello "), "first message row is evidence")
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
        // set_value's read-back comparison, shared by type's background value-write fallback (round 9 → 10 regression).
        check(TextReadback.matches(expected: "clinqy test 7", actual: "clinqy test 7"), "exact read-back")
        check(TextReadback.matches(expected: "clinqy test 7", actual: "clinqy test 7\n"), "trailing newline only: accepted")
        check(TextReadback.matches(expected: "clinqy test 7", actual: " clinqy\u{00A0}test  7 "), "whitespace-only differences: accepted")
        check(!TextReadback.matches(expected: "clinqy test 7", actual: "clinqy test 8"), "different text: refused")
        check(!TextReadback.matches(expected: "clinqy test 7", actual: "clinqy test 7!"), "extra character: refused")
        check(!TextReadback.matches(expected: "clinqy test 7", actual: ""), "empty read-back: refused")
        check(!TextReadback.matches(expected: "   ", actual: ""), "whitespace-only expected never matches loosely")
        check(SubmitReadback.allows(expected: "clinqy test 7", actual: "clinqy test 7\n", tolerant: true)
              && !SubmitReadback.allows(expected: "clinqy test 7", actual: "clinqy test 7\n"), "tolerant only for the AX value write; typed text stays exact")
        check(!SubmitReadback.allows(expected: "clinqy test 7", actual: nil, tolerant: true), "tolerant never accepts an unreadable composer")
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
        // --- Owned tabs: a closed popup returns to its opener; open_url never duplicates an owned page ---
        check(OwnedTabRecovery.fallback(closed: 53, opener: 52, owned: [52, 53, 60]) == 52, "closed popup falls back to its owned opener")
        check(OwnedTabRecovery.fallback(closed: 53, opener: 40, owned: [52, 53, 60]) == 60, "foreign opener is never chosen; newest owned tab instead")
        check(OwnedTabRecovery.fallback(closed: 53, opener: nil, owned: [53]) == nil, "no other owned tab: no fallback")
        check(OwnedTabRecovery.samePage("http://127.0.0.1:5000/workflow?token=a#x", "http://127.0.0.1:5000/workflow?token=a"), "fragment ignored")
        check(OwnedTabRecovery.samePage("https://Example.test/a/", "https://example.test:443/a"), "host case, default port and trailing slash ignored")
        check(!OwnedTabRecovery.samePage("http://127.0.0.1:5000/workflow?token=a", "http://127.0.0.1:5000/workflow?token=b"), "different query is another page")
        check(!OwnedTabRecovery.samePage("http://127.0.0.1:5000/workflow", "http://127.0.0.1:5001/workflow"), "different port is another page")
        let ownedTabs: [(id: Int, url: String)] = [(52, "http://127.0.0.1:5000/workflow?token=a"), (53, "http://127.0.0.1:5000/popup?token=a"), (70, "http://127.0.0.1:5000/workflow?token=a")]
        check(OwnedTabRecovery.existingTab(for: "http://127.0.0.1:5000/workflow?token=a", current: nil, tabs: ownedTabs) == 52, "start URL already open: earliest owned tab reused")
        check(OwnedTabRecovery.existingTab(for: "http://127.0.0.1:5000/workflow?token=a", current: 70, tabs: ownedTabs) == 70, "current tab preferred when it already shows the page")
        check(OwnedTabRecovery.existingTab(for: "https://other.test/", current: 52, tabs: ownedTabs) == nil, "new page still opens")

        // --- Inability is never reported as success ---
        check(InabilityFinishPolicy.mustFail(answer: "Can't reach Chrome extension", deliveredMutations: 0, surfaceFailures: 2, taskSurfaceReached: false), "no-window inability fails")
        check(InabilityFinishPolicy.mustFail(answer: "I couldn't open the page because the browser had no current window.", deliveredMutations: 0, surfaceFailures: 1, taskSurfaceReached: false), "couldn't open fails")
        check(!InabilityFinishPolicy.mustFail(answer: "Can't reach Chrome extension", deliveredMutations: 0, surfaceFailures: 0, taskSurfaceReached: false), "no recorded surface failure: wording alone never decides")
        check(!InabilityFinishPolicy.mustFail(answer: "I couldn't find any open issues; the list is empty.", deliveredMutations: 0, surfaceFailures: 1, taskSurfaceReached: true), "read-only answer after reaching the page stays a success")
        check(!InabilityFinishPolicy.mustFail(answer: "Can't access the admin page, but the form is filled", deliveredMutations: 3, surfaceFailures: 1, taskSurfaceReached: false), "delivered work is judged by the other gates")
        check(!InabilityFinishPolicy.mustFail(answer: "The page title is Example Domain", deliveredMutations: 0, surfaceFailures: 1, taskSurfaceReached: false), "an actual answer is not an inability")

        // --- Receipt identity is per run ---
        check(RunReceiptRouting.dispatched(submitted: "job-receipt") == "job-receipt", "dispatched job carries its own receipt")
        check(RunReceiptRouting.dispatched(submitted: nil) == nil, "a dispatched job never borrows the foreground receipt")
        check(RunReceiptRouting.foreground(current: "fg", submitted: "bg", startsForegroundRun: false, autoContinuation: false) == "fg", "background dispatch leaves the foreground receipt intact")
        check(RunReceiptRouting.foreground(current: "fg", submitted: nil, startsForegroundRun: true, autoContinuation: true) == "fg", "auto-continuation keeps its receipt")
        check(RunReceiptRouting.foreground(current: nil, submitted: "new", startsForegroundRun: true, autoContinuation: false) == "new", "a new foreground run takes its receipt")
        check(RunReceiptRouting.cancelTarget(receipt: "bg", jobOwnsReceipt: true, foregroundReceipt: "fg") == .job, "job receipt cancels the job")
        check(RunReceiptRouting.cancelTarget(receipt: "fg", jobOwnsReceipt: false, foregroundReceipt: "fg") == .foreground, "foreground receipt cancels the foreground run")
        check(RunReceiptRouting.cancelTarget(receipt: "gone", jobOwnsReceipt: false, foregroundReceipt: "fg") == .none, "unknown receipt cancels nothing")

        // --- Explicit direct-control targets ---
        let apps: [(name: String?, bundleID: String?)] = [("Google Chrome", "com.google.Chrome"), ("Arc", "company.thebrowser.Browser"), ("Notes", "com.apple.Notes")]
        check(ControlTargetSelection.app(named: "google chrome", among: apps) == 0, "app by name")
        check(ControlTargetSelection.app(named: "com.apple.notes", among: apps) == 2, "app by bundle id")
        check(ControlTargetSelection.app(named: "Chrome", among: apps) == nil, "no fuzzy app guessing (never picks another browser)")
        let browserTabs: [(id: Int, url: String)] = [(11, "http://127.0.0.1:5000/workflow?token=a"), (12, "https://mail.test/inbox"), (13, "https://mail.test/sent")]
        check(ControlTargetSelection.tab("11", among: browserTabs) == 11, "tab by id")
        check(ControlTargetSelection.tab("99", among: browserTabs) == nil, "unknown tab id")
        check(ControlTargetSelection.tab("WORKFLOW", among: browserTabs) == 11, "tab by URL substring")
        check(ControlTargetSelection.tab("mail.test", among: browserTabs) == nil, "ambiguous URL substring refused")
        check(ControlProtocol.validateRequest(["op": "observe", "task": "Read", "app": "Google Chrome", "tab": "workflow"]) == nil, "explicit observe target accepted")
        check(ControlProtocol.validateRequest(["op": "observe", "task": "Read", "tab": 12]) == nil, "numeric tab id accepted")
        check(ControlProtocol.validateRequest(["op": "observe", "task": "Read", "app": ""]) != nil, "empty app refused")
        check(ControlProtocol.validateRequest(["op": "observe", "task": "Read", "tab": true]) != nil, "boolean tab refused")
        check(ControlProtocol.validateRequest(["op": "observe", "session": UUID().uuidString, "app": "Notes"]) != nil, "target only binds on the initial observe")
        // --- Round 5 J1: styled checkbox clicks are confirmed by the (proxied) input's checked flip ---
        let risky = { (label: String) in label.range(of: #"(?i)\b(share|submit|apply|send)\b"#, options: .regularExpression) != nil }
        check(!TickControl.consequential(label: "I consent to share my details", role: "checkbox", labelIsConsequential: risky), "a consent checkbox is not consequential")
        check(!TickControl.consequential(label: "Share my profile", role: "AXCheckBox", labelIsConsequential: risky), "native checkbox neither")
        check(TickControl.consequential(label: "Apply", role: "button", labelIsConsequential: risky), "the Apply button keeps its barrier")
        check(TickControl.consequential(label: "Share", role: nil, labelIsConsequential: risky), "unknown role falls back to the label")
        check(EffectClassification.tickClick(receipt: EffectReceipt(targetStateChanged: true), expectation: nil) == .confirmed, "checked flip confirms the tick")
        check(EffectClassification.tickClick(receipt: EffectReceipt(addedText: "Thanks for consenting"), expectation: nil) == .unverified, "page text alone doesn't confirm a tick")
        check(EffectClassification.tickClick(receipt: nil, expectation: nil) == .unverified, "no receipt, no confirmation")
        check(EffectClassification.click(receipt: EffectReceipt(targetStateChanged: true), consequential: true, expectation: nil) == .unverified, "consequential clicks still need explicit evidence")
        for want in ["checked", "on", "true", "Yes", "ticked"] { check(TickControl.matches(expected: want, actual: "checked"), "tick readback matches \(want)") }
        check(TickControl.matches(expected: "unchecked", actual: "unchecked") && !TickControl.matches(expected: "checked", actual: "unchecked"), "unticked readback")
        check(!TickControl.matches(expected: "checked", actual: "on"), "only the tick readback counts")

        // --- Round 5 C2: formatting is confirmed by the selected text's own font, never the toolbar toggle ---
        check(TextFormatting.style(forLabel: "Bold — Bold text") == .bold && TextFormatting.style(forLabel: "Italic") == .italic
              && TextFormatting.style(forLabel: "Underline") == .underline && TextFormatting.style(forLabel: "Boldly go") == nil, "formatting toggles by label")
        let regular = TextFormatting.Span(fontName: "Helvetica", boldTrait: false)
        let bold = TextFormatting.Span(fontName: "Helvetica-Bold", boldTrait: true)
        check(!TextFormatting.confirmed(.bold, on: true, spans: [regular]), "Helvetica Regular is not bold (the C2 false success)")
        check(TextFormatting.confirmed(.bold, on: true, spans: [bold]), "Helvetica-Bold is bold")
        check(!TextFormatting.confirmed(.bold, on: true, spans: [bold, regular]), "partly bold is not bold")
        check(!TextFormatting.confirmed(.bold, on: true, spans: []), "unreadable formatting is never confirmed")
        check(TextFormatting.confirmed(.bold, on: true, spans: [.init(fontName: "Avenir-Heavy")]), "font name implies weight when traits are unknown")
        check(TextFormatting.confirmed(.bold, on: false, spans: [regular]), "bold off confirmed by regular text")
        check(TextFormatting.confirmed(.underline, on: true, spans: [.init(fontName: "Helvetica", underline: true)]), "underline attribute")
        check(TextFormatting.range(of: "hello world", in: "hello world") == NSRange(location: 0, length: 11), "target text range")
        check(TextFormatting.range(of: "a", in: "a b a") == nil, "repeated target text is ambiguous")
        check(TextFormatting.range(of: "missing", in: "hello") == nil, "absent target text")
        check(TextFormatting.selectionVerified(selected: "hello world", target: "hello world") && !TextFormatting.selectionVerified(selected: "", target: nil)
              && !TextFormatting.selectionVerified(selected: "hello", target: "hello world") && !TextFormatting.selectionVerified(selected: nil, target: nil), "selection must read back")

        // --- Round 6 C2: an unconfirmed item never ends ok, whatever the answer's wording ---
        check(UnconfirmedFinishPolicy.verdict(ok: true, unconfirmed: ["the bold formatting"]) == .unconfirmed, "unconfirmed formatting is not ok (round 6 ok:true receipt)")
        check(UnconfirmedFinishPolicy.verdict(ok: true, unconfirmed: ["the click on \"Next\""]) == .unconfirmed, "a non-consequential unconfirmed item is not ok either")
        check(UnconfirmedFinishPolicy.verdict(ok: true, unconfirmed: []) == .ok, "nothing unconfirmed stays ok")
        check(UnconfirmedFinishPolicy.verdict(ok: false, unconfirmed: ["the bold formatting"]) == .failed, "a failed run stays a failure, not 'needs a look'")

        // --- Round 6 J2: a rejected upload is FAILED, carries the Note, and error text never confirms it ---
        check(UploadEvidence.afterCleared(heldFiles: 0, pageText: "Resume\nUpload failed\nApply", fileName: "resume.pdf") == .rejected, "0 files + 'Upload failed' is a rejection")
        check(UploadEvidence.afterCleared(heldFiles: 0, pageText: "resume.pdf: invalid file type", fileName: "resume.pdf") == .rejected, "named file with an invalid-type error is rejected")
        check(UploadEvidence.afterCleared(heldFiles: 0, pageText: "Resume\nApply", fileName: "resume.pdf") == .uncertain, "a cleared field without an error stays uncertain")
        check(UploadEvidence.afterCleared(heldFiles: 1, pageText: "Upload failed", fileName: "resume.pdf") == .attached, "a held file is attached")
        check(UploadEvidence.afterCleared(heldFiles: 0, pageText: "Payment error on another form", fileName: "resume.pdf") == .uncertain, "an unrelated error is not an upload rejection")
        let rejectedRun: [FailedClaimGuard.Attempt] = [.init(step: "Upload resume.pdf", failed: true), .init(step: "Verify outcome", failed: true)]
        check(FailedClaimGuard.failureNote(attempts: rejectedRun)?.contains("the upload of resume.pdf failed") == true, "a rejected upload's not-ok run carries the Note")
        for failure in ["Upload failed", "Error uploading file", "Couldn't attach resume.pdf", "Invalid file type", "File rejected"] {
            check(UploadEvidence.isFailureText(failure), "failure text: \(failure)")
            check(!UploadEvidence.textMayConfirm(failure, pendingKind: "upload", fileName: "resume.pdf"), "\(failure) never confirms a pending upload")
            check(!UploadEvidence.textMayConfirm(failure, pendingKind: "click", fileName: nil), "\(failure) never confirms a pending click")
        }
        check(UploadEvidence.textMayConfirm("resume.pdf", pendingKind: "upload", fileName: "resume.pdf"), "the file name confirms an upload")
        check(!UploadEvidence.textMayConfirm("Uploaded", pendingKind: "upload", fileName: "resume.pdf"), "nameless text doesn't confirm an upload")
        check(UploadEvidence.textMayConfirm("Application submitted", pendingKind: "click", fileName: nil), "ordinary confirmation text still confirms a click")

        // --- Round 6 W1: Return after the send approval re-resolves instead of reporting the target changed ---
        check(ReturnDelivery.decide(approvalShown: true, sameProcess: true, windowResolved: true, focusedInField: false, fieldHoldsText: true) == .refocusThenPress, "our own panel taking focus is not a target change")
        check(ReturnDelivery.decide(approvalShown: false, sameProcess: true, windowResolved: true, focusedInField: true, fieldHoldsText: true) == .press, "focused composer: press")
        check(ReturnDelivery.decide(approvalShown: false, sameProcess: true, windowResolved: true, focusedInField: false, fieldHoldsText: true) != .press
              && ReturnDelivery.decide(approvalShown: false, sameProcess: true, windowResolved: true, focusedInField: false, fieldHoldsText: true) != .refocusThenPress, "focus lost without an approval stays uncertain")
        check(ReturnDelivery.decide(approvalShown: true, sameProcess: true, windowResolved: false, focusedInField: true, fieldHoldsText: true) != .press, "a replaced window is never pressed")
        check(ReturnDelivery.decide(approvalShown: true, sameProcess: true, windowResolved: true, focusedInField: true, fieldHoldsText: false) != .press, "a changed composer is never sent")
        check(ReturnDelivery.decide(approvalShown: true, sameProcess: false, windowResolved: true, focusedInField: true, fieldHoldsText: true) != .press, "a restarted app is never pressed")

        // --- Round 8 #1: background typing always re-focuses the composer before Return, whatever moved focus ---
        check(ReturnDelivery.decide(approvalShown: false, background: true, sameProcess: true, windowResolved: true, focusedInField: false, fieldHoldsText: true) == .refocusThenPress, "background: lost focus without an approval is re-focused, not uncertain")
        check(ReturnDelivery.decide(approvalShown: false, background: true, sameProcess: true, windowResolved: true, focusedInField: true, fieldHoldsText: true) == .refocusThenPress, "background: always re-focus right before Return")
        check(ReturnDelivery.decide(approvalShown: false, background: true, sameProcess: true, windowResolved: false, focusedInField: false, fieldHoldsText: true) != .refocusThenPress, "background: a replaced window is not re-focused")
        check(ReturnDelivery.decide(approvalShown: false, background: true, sameProcess: false, windowResolved: true, focusedInField: false, fieldHoldsText: true) != .refocusThenPress, "background: a restarted app is not re-focused")
        check(ReturnDelivery.decide(approvalShown: false, background: true, sameProcess: true, windowResolved: true, focusedInField: false, fieldHoldsText: false) != .refocusThenPress, "background: a changed composer is not re-focused")
        check(ReturnDelivery.afterRefocus(focused: true, sameProcess: true, windowResolved: true, fieldHoldsText: true) == .press, "re-focus took: press")
        check(ReturnDelivery.afterRefocus(focused: false, sameProcess: true, windowResolved: true, fieldHoldsText: true) != .press, "re-focus failed: uncertain")
        check(ReturnDelivery.afterRefocus(focused: true, sameProcess: true, windowResolved: false, fieldHoldsText: true) != .press, "window changed during re-focus: uncertain")
        check(ReturnDelivery.afterRefocus(focused: true, sameProcess: false, windowResolved: true, fieldHoldsText: true) != .press, "app changed during re-focus: uncertain")
        check(ReturnDelivery.afterRefocus(focused: true, sameProcess: true, windowResolved: true, fieldHoldsText: false) != .press, "composer text changed during re-focus: uncertain")
        // --- Round 9 #2: background AX value fallback — the read-back of exactly the typed text gates Return ---
        check(ReturnDelivery.afterRefocus(focused: false, sameProcess: true, windowResolved: true, fieldHoldsText: true, valueSetFallback: true) == .press,
              "value written and read back, focus unreportable: press Return")
        check(ReturnDelivery.afterRefocus(focused: false, sameProcess: true, windowResolved: true, fieldHoldsText: false, valueSetFallback: true) != .press,
              "value fallback but the composer doesn't hold the text: never Return")
        check(ReturnDelivery.afterRefocus(focused: false, sameProcess: true, windowResolved: true, fieldHoldsText: true, valueSetFallback: true, focusInOtherField: true) != .press,
              "value fallback while another text field holds focus: Return would go there, uncertain")
        check(ReturnDelivery.afterRefocus(focused: false, sameProcess: true, windowResolved: false, fieldHoldsText: true, valueSetFallback: true) != .press
              && ReturnDelivery.afterRefocus(focused: false, sameProcess: false, windowResolved: true, fieldHoldsText: true, valueSetFallback: true) != .press,
              "value fallback in a replaced window or restarted app: never Return")
        check(ReturnDelivery.sent(composerAfter: "", rowsWithTextBefore: 0, rowsWithTextAfter: 1), "empty composer + new row: sent")
        check(ReturnDelivery.sent(composerAfter: " \n", rowsWithTextBefore: 1, rowsWithTextAfter: 2), "whitespace composer + new row: sent")
        check(!ReturnDelivery.sent(composerAfter: "clinqy test 3", rowsWithTextBefore: 0, rowsWithTextAfter: 1), "composer still holds the text: not confirmed")
        check(!ReturnDelivery.sent(composerAfter: "", rowsWithTextBefore: 1, rowsWithTextAfter: 1), "no new row: not confirmed")
        check(!ReturnDelivery.sent(composerAfter: nil, rowsWithTextBefore: 0, rowsWithTextAfter: 1), "unreadable composer: not confirmed")

        // --- Round 6 C3: a long text area whose centre is outside the window is aimed at its visible part ---
        let pinned = CGRect(x: 100, y: 100, width: 800, height: 600)
        let longText = CGRect(x: 120, y: -2400, width: 760, height: 3200)   // scrolled to the bottom: centre far above the window
        check(!pinned.contains(CGPoint(x: longText.midX, y: longText.midY)), "the long text area's own centre is outside the window")
        check(NativeAim.point(element: longText, window: pinned) == CGPoint(x: 500, y: 400), "aimed at the centre of its part inside the window")
        check(NativeAim.point(element: CGRect(x: 2000, y: 2000, width: 50, height: 50), window: pinned) == nil, "an element outside the window is refused")
        check(NativeAim.point(element: CGRect(x: 200, y: 200, width: 40, height: 20), window: pinned) == CGPoint(x: 220, y: 210), "an ordinary control keeps its centre")

        // --- Round 6 C2: background bold goes through the app's own Format ▸ Font ▸ Bold menu item ---
        let menus: [TextFormatting.MenuCandidate] = [
            .init(title: "Bold", ancestors: ["Format", "Font"]), .init(title: "Italic", ancestors: ["Format", "Font"]),
            .init(title: "Bold", ancestors: ["View", "Sidebar style"]), .init(title: "Underline", ancestors: ["Format", "Font"], enabled: false)]
        check(TextFormatting.menuChoice(menus, for: .bold) == 0, "Bold under Format ▸ Font wins over an unrelated Bold")
        check(TextFormatting.menuChoice(menus, for: .italic) == 1, "Italic under Format ▸ Font")
        check(TextFormatting.menuChoice(menus, for: .underline) == nil, "a disabled item is never pressed")
        check(TextFormatting.menuChoice([.init(title: "Bold", ancestors: ["Edit"]), .init(title: "Bold", ancestors: ["View"])], for: .bold) == nil, "ambiguous Bold items: nothing pressed")
        check(TextFormatting.menuChoice([.init(title: "Bold", ancestors: ["Text"])], for: .bold) == 0, "a single Bold item elsewhere is used")
        check(TextFormatting.menuChoice([.init(title: "Bold Text", ancestors: ["Format"])], for: .bold) == nil, "only an exact title counts")

        // --- Round 6 C2-covered/C3: the document text area is found by the pinned window's tree, not by visibility ---
        final class Node { let role: String; let kids: [Node]; init(_ role: String, _ kids: [Node] = []) { self.role = role; self.kids = kids } }
        let textArea = Node("AXTextArea", [Node("AXStaticText")])
        let textEdit = Node("AXWindow", [
            Node("AXToolbar", [Node("AXGroup", [Node("AXTextField"), Node("AXPopUpButton"), Node("AXCheckBox")])]),
            Node("AXScrollArea", [Node("AXRuler"), textArea, Node("AXScrollBar", [Node("AXValueIndicator")])]),
            Node("AXButton"), Node("AXButton"), Node("AXButton")])
        check(TextFormatting.documentTextArea(in: textEdit, role: \.role, children: \.kids) === textArea, "TextEdit's AXTextArea in its AXScrollArea is found (covered or scrolled: no frames involved)")
        let loose = Node("AXTextArea")
        let noScroll = Node("AXWindow", [Node("AXGroup", [loose]), Node("AXTextField")])
        check(TextFormatting.documentTextArea(in: noScroll, role: \.role, children: \.kids) === loose, "a single text area without a scroll area is the fallback")
        let preferred = Node("AXTextArea")
        let mixed = Node("AXWindow", [Node("AXTextArea"), Node("AXScrollArea", [Node("AXGroup", [preferred])])])
        check(TextFormatting.documentTextArea(in: mixed, role: \.role, children: \.kids) === preferred, "the scroll area's text area wins over a stray one")
        let two = Node("AXWindow", [Node("AXScrollArea", [Node("AXTextArea")]), Node("AXScrollArea", [Node("AXTextArea")])])
        check(TextFormatting.documentTextArea(in: two, role: \.role, children: \.kids) == nil, "two documents are ambiguous")
        check(TextFormatting.documentTextArea(in: Node("AXWindow", [Node("AXButton")]), role: \.role, children: \.kids) == nil, "no text area")
        var deep = Node("AXTextArea")
        for _ in 0..<40 { deep = Node("AXGroup", [deep]) }
        check(TextFormatting.documentTextArea(in: Node("AXWindow", [Node("AXScrollArea", [deep])]), role: \.role, children: \.kids) == nil, "the walk is depth-bounded")

        // --- Round 5 C3: a native click by visible text resolves to one target in the pinned window ---
        let doc = (1...179).map { "Line \($0)" }.joined(separator: "\n") + "\nClinqy final choice item"
        let window: [BackgroundPolicy.LabelCandidate] = [
            .init(id: "e1", role: "AXButton", label: "Bold"), .init(id: "e2", role: "AXButton", label: "Italic"),
            .init(id: "e3", role: "AXPopUpButton", label: "Font size"), .init(id: "e4", role: "AXTextArea", label: "", text: doc),
            .init(id: "e5", role: "AXButton", label: "Save"), .init(id: "e6", role: "AXButton", label: "Save As…")]
        check(BackgroundPolicy.labelTarget("Bold", among: window) == .element("e1"), "exact label resolves")
        check(BackgroundPolicy.labelTarget("\"italic\"", among: window) == .element("e2"), "case and quotes ignored")
        let finalRange = (doc as NSString).range(of: "Clinqy final choice item")
        check(BackgroundPolicy.labelTarget("Clinqy final choice item", among: window) == .selectText("e4", finalRange), "text inside the document is selected there")
        check(BackgroundPolicy.labelTarget("Line 1", among: window) == .ambiguous(["e4"]), "text repeated in the document is refused")
        check(BackgroundPolicy.labelTarget("Save", among: window) == .element("e5"), "exact match wins over partial")
        check(BackgroundPolicy.labelTarget("Size", among: window) == .element("e3"), "unique partial label match")
        check(BackgroundPolicy.labelTarget("Nothing here", among: window) == .none, "absent text is refused")
        check(BackgroundPolicy.labelTarget("Sav", among: window) == .ambiguous(["e5", "e6"]), "ambiguous partial match is refused")
        check(BackgroundPolicy.labelTarget("Go", among: [.init(id: "e1", role: "AXButton", label: "Go"), .init(id: "e2", role: "AXButton", label: "go")]) == .ambiguous(["e1", "e2"]), "duplicate exact labels are refused")
        print("PASS \(checks) gesture, ownership, replay refusal, vision and final artifact checks")
    }
}

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
        check(restored.record(id)?.pendingAction == nil && restored.record(id)?.unverifiedAction == "click", "unfinished dispatch becomes an uncertain outcome on restart")
        check(restored.record(id)?.pendingProvenance?.delivery == .unknown, "restart cannot invent delivery evidence")
        check(restored.actionHistory(id).first?.state == .unknown, "unfinished journal reservation recovers unknown")
        check(!restored.start(id, explicitlyReviewed: true), "never replays interrupted submit")
        check(!restored.start(queued), "restored queue requires review")
        check(restored.start(queued, explicitlyReviewed: true), "review starts queued request")
        restored.endAction(queued, kind: "read", outcome: .confirmed, completedSteps: 1)
        check(restored.record(queued)?.lastConfirmedStep == "read", "records confirmed stage")
        restored.finish(queued, ok: true, answer: "Complete")
        let final = TaskStore(file: file)
        check(final.record(queued)?.state == .succeeded, "terminal result retained")
        let uncertain = final.enqueue("Submit once", source: .mac)!
        check(final.start(uncertain), "starts uncertain action case")
        check(final.beginAction(uncertain, kind: "click"), "checkpoints one submission")
        check(final.endAction(uncertain, kind: "click", outcome: .uncertain, completedSteps: 0), "persists unknown delivery")
        check(final.record(uncertain)?.lastConfirmedStep == nil, "unknown delivery is never confirmed")
        check(final.record(uncertain)?.unverifiedAction == "click", "retains uncertain action separately")
        check(final.beginAction(uncertain, kind: "read", mutation: false), "permits independent readback")
        check(final.endAction(uncertain, kind: "read", outcome: .confirmed, completedSteps: 1), "records readback")
        check(final.record(uncertain)?.unverifiedAction == "click", "unrelated successful read does not erase uncertain input")
        check(final.actionHistory(uncertain).first?.state == .unknown, "unrelated read never confirms the mutation journal")
        let crash = TaskStore(file: file)
        check(crash.record(uncertain)?.unverifiedAction == "click", "uncertain outcome survives crash after delivery")
        final.finish(uncertain, ok: true, answer: "Done")
        check(final.record(uncertain)?.state == .failed, "cannot claim task success with unresolved side effect")
        let verified = final.enqueue("Submit and verify", source: .mac)!
        check(final.start(verified), "starts verification case")
        _ = final.beginAction(verified, kind: "click")
        _ = final.endAction(verified, kind: "click", outcome: .unverified, completedSteps: 0)
        check(final.confirmAction(verified, evidence: "new receipt number"), "explicit verification resolves input")
        check(final.record(verified)?.unverifiedAction == nil, "clears only verified outcome")
        final.finish(verified, ok: true, answer: "Receipt confirmed")
        check(final.record(verified)?.state == .succeeded, "verified task can complete")
        let scheduled = final.enqueue("Scheduled once", source: .mac, idempotencyKey: "schedule:42")!
        check(final.enqueue("Scheduled once", source: .mac, idempotencyKey: "schedule:42") == scheduled, "durable dispatch deduplicates queued occurrence")
        check(final.start(scheduled), "starts scheduled occurrence")
        final.finish(scheduled, ok: true, answer: "Complete")
        check(final.enqueue("Scheduled once", source: .mac, idempotencyKey: "schedule:42") == scheduled, "never re-enqueues completed scheduled occurrence")
        let absent: String? = nil
        let initial = "[false,null,null,null,null,\"\",\"https://example.test/\",\"old-text\",false]"
        let textChange = "[false,null,null,null,null,\"\",\"https://example.test/\",\"new-text\",true]"
        let checked = "[true,null,null,null,null,\"\",\"https://example.test/\",\"old-text\",true]"
        check(ActionOutcome.browserClick(before: absent, after: checked, consequential: false) == .unverified, "unreadable pre-state cannot confirm input")
        check(ActionOutcome.browserClick(before: initial, after: absent, consequential: false) == .unverified, "unreadable post-state cannot confirm input")
        check(ActionOutcome.browserClick(before: initial, after: textChange, consequential: false) == .unverified, "unrelated text or focus change does not confirm target")
        check(ActionOutcome.browserClick(before: initial, after: checked, consequential: false) == .confirmed, "target checked state is valid evidence")
        check(ActionOutcome.browserClick(before: initial, after: checked, consequential: true) == .unverified, "submission still requires acknowledgement")
        check(ActionOutcome.browserClick(before: "invalid", after: checked, consequential: false) == .unverified, "invalid observation fails closed")
        check(!VerificationEvidence.changedValue(before: "old", after: "new", expected: "new", sameTarget: true, fieldInput: false), "field value cannot confirm a consequential submit")
        check(!VerificationEvidence.changedValue(before: "old", after: "new", expected: "new", sameTarget: false, fieldInput: true), "unrelated field cannot confirm input")
        check(!VerificationEvidence.changedValue(before: "new", after: "new", expected: "new", sameTarget: true, fieldInput: true), "preexisting field value does not establish an uncertain input")
        check(!VerificationEvidence.changedValue(before: nil, after: "new", expected: "new", sameTarget: true, fieldInput: true), "unreadable baseline does not confirm input")
        check(VerificationEvidence.changedValue(before: "old", after: "new", expected: "new", sameTarget: true, fieldInput: true), "fresh changed target value confirms field input")
        check(!VerificationEvidence.appears("Paid", in: "pay:unpaid"), "a word fragment inside \"unpaid\" is not the word Paid")
        check(VerificationEvidence.appears("paid", in: "Status: PAID."), "whole word matches regardless of case and punctuation")
        check(!VerificationEvidence.appears("Order", in: "Your Orders"), "a plural is not the singular")
        check(VerificationEvidence.appears("for i, n in enumerate", in: "for\u{00A0}i,\u{00A0}\u{00A0}n in\tenumerate(nums)"), "non-breaking and repeated spaces match ordinary spaces")
        check(VerificationEvidence.appears("name=Amrit Nigam", in: "form:Keynote|name=Amrit Nigam|city=Pune"), "field-style text still matches inside a title")
        check(VerificationEvidence.appears("₹500", in: "Total ₹500 due"), "symbol edges match as written")
        check(!VerificationEvidence.newText("Paid", before: "pay:unpaid", after: "pay:unpaid"), "unchanged unpaid page is not a new Paid confirmation")
        check(!VerificationEvidence.newText("Receipt", before: "Receipt already present", after: "Receipt already present"), "preexisting receipt text cannot confirm another submit")
        check(!VerificationEvidence.newText("Receipt", before: nil, after: "Receipt 123"), "missing baseline cannot confirm new text")
        check(VerificationEvidence.newText("Receipt", before: "Submit", after: "Receipt 123"), "new receipt text is independent confirmation")
        let duplicate = [TargetResolution.Candidate(index: 2, identity: "Delete"), .init(index: 3, identity: "Delete")]
        check(TargetResolution.unique(index: 1, identity: "Delete", candidates: duplicate, stableIndex: false) == nil, "duplicate controls never resolve by nearest position")
        check(TargetResolution.unique(index: 2, identity: "Delete", candidates: duplicate, stableIndex: true) == 2, "valid live identity remains addressable")
        check(TargetResolution.unique(index: 1, identity: "Delete", candidates: [.init(index: 3, identity: "Delete")], stableIndex: false) == 3, "unique semantic match can be resolved")
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
        check(BackgroundPolicy.route(["do":"delegate"], hasWorkerPage: false) == .api, "delegation doesn't require foreground access")
        check(BackgroundPolicy.route(["do":"collect"], hasWorkerPage: false) == .api, "worker collection doesn't require foreground access")
        check(BackgroundPolicy.route(["do":"type","id":"w2"], hasWorkerPage: true) == .browser, "owned web field allowed")
        check(BackgroundPolicy.route(["do":"key","keys":"cmd+a"], hasWorkerPage: true) == .browser, "owned select-all allowed")
        check(BackgroundPolicy.route(["do":"tab","op":"list"], hasWorkerPage: false, allowTabDiscovery: true) == .browser, "explicit existing-tab request can discover URLs before opening a task page")
        if case .attention = BackgroundPolicy.route(["do":"tab","op":"list"], hasWorkerPage: false) {
            check(true, "ordinary workers cannot discover personal tabs")
        } else { check(false, "ordinary workers cannot discover personal tabs") }
        for op in ["switch", "close", "read", "look"] {
            if case .attention = BackgroundPolicy.route(["do":"tab","op":op], hasWorkerPage: false, allowTabDiscovery: true) {
                check(true, "discovery does not authorize input or page access: \(op)")
            } else { check(false, "discovery does not authorize input or page access: \(op)") }
        }
        // --- Requirements ledger, pending provenance and explicit resolution ---
        let ledgerFile = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledgerFile) }
        let ledger = TaskStore(file: ledgerFile)
        let wanted = "Create a doc named \"Lab 7 Report\" with 3 screenshots and captions, saved at ~/Documents/lab7.pdf"
        let ledgerID = ledger.enqueue(wanted, source: .mac, background: false)!
        check(ledger.start(ledgerID), "ledger task starts")
        let extracted = RequirementExtractor.extract(wanted)
        check(extracted.contains { $0.0 == .exactValue && $0.1 == "Lab 7 Report" }, "quoted exact name captured")
        check(extracted.contains { $0.0 == .screenshot && $0.1.hasPrefix("3") }, "required screenshot count captured")
        check(extracted.contains { $0.0 == .caption }, "caption requirement captured")
        check(extracted.contains { $0.0 == .deliverable && $0.1 == "~/Documents/lab7.pdf" }, "deliverable identity captured")
        check(ledger.addRequirements(ledgerID, extracted, provenance: "user request"), "requirements persist")
        check(ledger.addRequirements(ledgerID, extracted, provenance: "user request"), "adding again is idempotent")
        check(ledger.record(ledgerID)?.requirements?.count == extracted.count, "no duplicate requirements")
        // An unrelated true verification must not satisfy a different requirement.
        _ = ledger.beginAction(ledgerID, kind: "click")
        let origin = TaskStore.PendingProvenance(kind: "click", startedAt: Date(), url: "https://x.test/lab", tabID: 7, visualOK: true, delivery: .delivered)
        _ = ledger.endAction(ledgerID, kind: "click", outcome: .unverified, completedSteps: 1, provenance: origin)
        check(ledger.confirmAction(ledgerID, evidence: "text verified"), "text verification resolves the pending input")
        check(ledger.record(ledgerID)?.openRequirements.count == extracted.count, "an unrelated verification satisfies no requirement")
        check(ledger.satisfyRequirement(ledgerID, kind: .exactValue, matching: "Lab 7 Report", evidence: "field readback"), "exact value satisfied by its own evidence")
        check(ledger.record(ledgerID)?.openRequirements.contains { $0.kind == .exactValue } == false, "satisfied requirement closes")
        check(ledger.record(ledgerID)?.openRequirements.contains { $0.kind == .deliverable } == true, "deliverable stays open")
        // Provenance and requirements survive a restart (the task is interrupted, never replayed).
        _ = ledger.beginAction(ledgerID, kind: "click")
        _ = ledger.endAction(ledgerID, kind: "click", outcome: .unverified, completedSteps: 2, provenance: origin)
        let reloaded = TaskStore(file: ledgerFile)
        check(reloaded.record(ledgerID)?.pendingProvenance == origin, "pending provenance persists across restart")
        check(reloaded.record(ledgerID)?.unverifiedAction == "click", "pending uncertainty persists across restart")
        check(reloaded.record(ledgerID)?.openRequirements.contains { $0.kind == .deliverable } == true, "open requirements persist across restart")
        check(reloaded.record(ledgerID)?.state == .interrupted, "restart interrupts rather than replays")
        // User reports the effect absent: barrier lifted with no confirmed step claimed.
        let resolved = TaskStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-resolve-\(UUID().uuidString).json"))
        let rid = resolved.enqueue("click the lab help button", source: .mac, background: false)!
        _ = resolved.start(rid); _ = resolved.beginAction(rid, kind: "click")
        _ = resolved.endAction(rid, kind: "click", outcome: .unverified, completedSteps: 1, provenance: origin)
        check(resolved.record(rid)?.unverifiedAction == "click", "unknown click is pending")
        check(resolved.resolveAction(rid, evidence: "user reported no effect"), "explicit resolution persists")
        check(resolved.record(rid)?.unverifiedAction == nil && resolved.record(rid)?.pendingProvenance == nil, "resolution lifts the barrier")
        check(resolved.record(rid)?.lastConfirmedStep == nil, "a reported non-effect never becomes a confirmed step")
        // --- C: background routing says why, instead of claiming the owned tab is missing ---
        if case .attention(let reason) = BackgroundPolicy.route(["do": "click", "text": "PROJECT"], hasWorkerPage: true) {
            check(!reason.contains("No owned browser page target"), "owned tab present: text click is not blamed on a missing tab")
            check(reason.contains("w-id") || reason.contains("w<number>"), "text click in background points at element ids")
        } else { check(false, "background text click is not silently routed") }
        if case .attention(let reason) = BackgroundPolicy.route(["do": "click", "id": "w1"], hasWorkerPage: false) {
            check(reason.contains("No owned browser page target"), "missing owned tab is still reported")
        } else { check(false, "click without owned tab needs attention") }
        check(BackgroundPolicy.route(["do": "verify", "user_confirms": "uploaded"], hasWorkerPage: false) == .api, "user confirmation needs no page")
        check(BackgroundPolicy.route(["do": "click", "id": "w1"], hasWorkerPage: true) == .browser, "w-id click on owned tab allowed")
        // Durable identity, explicit resumption and outcome requirements exercise real SQLite reopen paths.
        let auditFile = root.appendingPathComponent("audit.sqlite")
        let audit = TaskStore(file: auditFile)
        let auditID = audit.enqueue("Produce two reports", source: .mac)!
        check(audit.start(auditID), "audit task starts")
        check(audit.addChecklist(auditID, titles: ["First report", "Second report"]), "requested outcomes persist")
        let dispatch = UUID()
        check(audit.beginAction(auditID, kind: "click", actionID: dispatch, runID: "fixture"), "reserves durable dispatch identity")
        check(audit.endAction(auditID, kind: "click", outcome: .confirmed, completedSteps: 1, actionID: dispatch), "confirms dispatched action")
        check(!audit.beginAction(auditID, kind: "click", actionID: dispatch), "a completed dispatch ID cannot be reused")
        check(audit.record(auditID)?.pendingAction == nil && audit.actionHistory(auditID).count == 1, "duplicate reservation is atomic and leaves no checkpoint")
        check(audit.verifyChecklist(auditID, step: "s1", evidence: "first artifact read"), "first outcome independently verified")
        check(!audit.verifyChecklist(auditID, step: "missing", evidence: "irrelevant"), "unknown outcome ID is refused")
        check(audit.finish(auditID, ok: true, answer: "Done"), "incomplete terminal state persists")
        check(audit.record(auditID)?.state == .failed, "unfinished checklist blocks success")
        var readyID: UUID?
        audit.onReady = { readyID = $0 }
        check(audit.requestResume(auditID) && readyID == auditID, "explicit resume queues same task identity")
        check(audit.start(auditID), "resumed task starts after fresh dispatch request")
        check(audit.record(auditID)?.checklist?.first?.complete == true && audit.record(auditID)?.openChecklist.map(\.id) == ["s2"], "resume preserves completed and unfinished outcomes")
        check(audit.verifyChecklist(auditID, step: "s2", evidence: "second artifact read"), "second outcome independently verified")
        let firstFile = root.appendingPathComponent("first.txt"), secondFile = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: firstFile)
        let alias = root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: firstFile)
        check(audit.addRequirements(auditID, [(.deliverable, firstFile.path), (.deliverable, secondFile.path)], provenance: "user"), "two independent file requirements")
        check(audit.satisfyDeliverable(auditID, path: alias.path, evidence: "alias resolves to first"), "canonical matching file path satisfies its requirement")
        check(audit.record(auditID)?.openRequirements.map(\.text) == [secondFile.path], "one verified file never clears another deliverable")
        check(audit.finish(auditID, ok: true, answer: "Done") && audit.record(auditID)?.state == .failed, "missing file evidence independently blocks completion")
        check(audit.requestResume(auditID) && audit.start(auditID), "file requirement failure can be inspected and continued")
        check(audit.satisfyDeliverable(auditID, path: secondFile.path, evidence: "second file independently checked"), "second file requirement accepts its own evidence")
        let faultDB = try SQLiteDatabase(file: auditFile)
        try faultDB.execute("CREATE TRIGGER refuse_completion BEFORE UPDATE ON tasks BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END;")
        check(!audit.finish(auditID, ok: true, answer: "Done"), "failed durable completion returns failure")
        check(audit.record(auditID)?.state == .running && audit.storageError != nil, "storage failure never publishes successful state")
        try faultDB.execute("DROP TRIGGER refuse_completion")
        check(audit.finish(auditID, ok: true, answer: "Both reports verified"), "completion persists after storage recovers")
        let finishedAudit = TaskStore(file: auditFile)
        check(finishedAudit.record(auditID)?.state == .succeeded && finishedAudit.record(auditID)?.openRequirements.isEmpty == true, "successful completion survives restart")
        let pendingID = finishedAudit.enqueue("One uncertain input", source: .mac)!
        check(finishedAudit.start(pendingID) && finishedAudit.beginAction(pendingID, kind: "click"), "new pending dispatch recorded")
        check(finishedAudit.finish(pendingID, ok: false, answer: "Stopped"), "cancellation persists")
        check(finishedAudit.actionHistory(pendingID).first?.state == .unknown, "cancelled in-flight dispatch is unknown")
        check(finishedAudit.requestResume(pendingID) && finishedAudit.start(pendingID), "cancelled task explicitly resumes")
        check(finishedAudit.record(pendingID)?.unverifiedAction == "click", "resumed cancelled task retains unknown barrier")
        check(!finishedAudit.beginAction(pendingID, kind: "type"), "resume never authorizes new mutation over unknown input")
        check(finishedAudit.resolveAction(pendingID, evidence: "user checked no effect") && finishedAudit.actionHistory(pendingID).first?.state == .resolved, "explicit review resolves but never confirms unknown dispatch")
        // A popup's result can appear in its exact owned opener, but closure or an unrelated tab is
        // never evidence. Each baseline belongs to that parent document before the child input.
        func openerEvidence(delivery: ActionOutcome.Delivery = .delivered, consequential: Bool = false,
                            sameRun: Bool = true, sameConnection: Bool = true,
                            expectedTab: Int? = 10, currentTab: Int? = 10,
                            expectedDocument: String? = "parent-doc", currentDocument: String? = "parent-doc",
                            before: String? = "Review window opened", after: String? = "Local review confirmed") -> Bool {
            OwnedOpenerEvidencePolicy.accepts(kind: "click", delivery: delivery, consequential: consequential,
                sameRun: sameRun, sameConnection: sameConnection, expectedTab: expectedTab, currentTab: currentTab,
                expectedDocument: expectedDocument, currentDocument: currentDocument,
                expected: "Local review confirmed", before: before, after: after)
        }
        check(openerEvidence(), "fresh owned-parent confirmation resolves known delivered ordinary click")
        check(!openerEvidence(delivery: .unknown), "unknown delivery cannot use alternate opener evidence")
        check(!openerEvidence(delivery: .notAttempted), "unsent input cannot use alternate opener evidence")
        check(!openerEvidence(consequential: true), "consequential inputs retain their original verification boundary")
        check(!openerEvidence(sameRun: false), "restored or unrelated run cannot reuse opener baseline")
        check(!openerEvidence(sameConnection: false), "another browser connection cannot reuse opener baseline")
        check(!openerEvidence(currentTab: 11), "sibling or child tab is not the captured parent")
        check(!openerEvidence(expectedTab: nil), "missing parent identity is rejected")
        check(!openerEvidence(currentDocument: "reloaded-parent"), "same URL with a changed parent document is rejected")
        check(!openerEvidence(expectedDocument: nil), "missing document provenance is rejected")
        check(!openerEvidence(before: "Local review confirmed"), "preexisting parent acknowledgement proves nothing new")
        check(!openerEvidence(before: nil), "child text cannot substitute for an absent parent baseline")
        check(!openerEvidence(after: nil), "popup closure alone provides no result evidence")
        check(!openerEvidence(after: "Review window opened"), "opening acknowledgement cannot confirm later child action")
        let restoredOpener = OwnedOpenerEvidencePolicy.permitsObservation(kind: "click", delivery: .delivered, consequential: false,
            sameRun: true, sameConnection: true, expectedTab: 10, currentTab: 10,
            expectedDocument: "parent-doc", currentDocument: "parent-doc")
        check(restoredOpener, "captured owned opener can restore observation when child is unavailable")
        for action: [String: Any] in [["do": "verify", "text": "Local review confirmed"], ["do": "read"], ["do": "tab", "op": "list"], ["do": "tab", "op": "switch", "id": 10]] {
            check(BackgroundPolicy.route(action, hasWorkerPage: restoredOpener) == .browser, "restored opener makes read-only verification and tab routes reachable")
            if case .attention = BackgroundPolicy.route(action, hasWorkerPage: false) { check(true, "no recovered target still fails closed") }
            else { check(false, "no recovered target still fails closed") }
        }
        check(!OwnedOpenerEvidencePolicy.permitsObservation(kind: "click", delivery: .unknown, consequential: false,
            sameRun: true, sameConnection: true, expectedTab: 10, currentTab: 10,
            expectedDocument: "parent-doc", currentDocument: "parent-doc"), "unknown delivery does not acquire a new observation route")
        check(!openerEvidence(after: "Review window opened"), "restoring observation cannot itself resolve pending input")
        print("PASS: \(checks) task recovery and background policy checks")
    }
}

import Foundation

@main
struct NotificationLedgerTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

    static func main() {
        var ledger = NotificationLedger()
        let first = ledger.issue(options: ["Yes", "No"], sensitive: false)
        check(first.actions.map(\.title) == ["Yes", "No"], "options become actions")
        check(ledger.resolve(notificationID: first.id, action: "option.1", typed: nil) == .answer("No", run: nil), "live option resolves")

        // A newer question retires the older one: a delayed response to the first must not answer the second.
        let second = ledger.issue(options: ["Send", "Cancel"], sensitive: false)
        check(first.id != second.id, "each question has its own identity")
        check(second.replaced == first.id, "replaced question is reported for removal")
        check(ledger.resolve(notificationID: first.id, action: "option.0", typed: nil) == .stale, "old option is stale")
        check(ledger.resolve(notificationID: first.id, action: "reply", typed: "yes") == .stale, "old typed reply is stale")
        check(ledger.resolve(notificationID: second.id, action: "option.0", typed: nil) == .answer("Send", run: nil), "new option uses new options")

        // Empty typed reply opens Clinqy instead of answering.
        check(ledger.resolve(notificationID: second.id, action: "reply", typed: "  ") == .open(question: true, run: nil), "blank reply opens")

        // Sensitive questions expose no answer path.
        let secret = ledger.issue(options: ["x"], sensitive: true)
        check(secret.actions.isEmpty, "sensitive has no actions")
        check(ledger.resolve(notificationID: secret.id, action: "option.0", typed: nil) == .open(question: true, run: nil), "sensitive option cannot answer")

        // Cleared question: nothing resolves.
        ledger.clear()
        check(ledger.resolve(notificationID: secret.id, action: "reply", typed: "x") == .stale, "cleared is stale")

        // Done notifications are not questions.
        check(ledger.resolve(notificationID: "clinqy.done.abc", action: "show", typed: nil) == .open(question: false, run: nil), "done opens work")

        // Parallel browser jobs each keep their own live question, answered back to the right run.
        let jobA = UUID(), jobB = UUID()
        let main = ledger.issue(options: ["Go ahead", "Not now"], sensitive: false)
        let a = ledger.issue(options: ["Delhi", "Mumbai"], sensitive: false, run: jobA)
        let b = ledger.issue(options: ["Engineer"], sensitive: false, run: jobB)
        check(a.replaced == nil && b.replaced == nil, "different runs do not retire each other's questions")
        check(ledger.resolve(notificationID: a.id, action: "option.1", typed: nil) == .answer("Mumbai", run: jobA), "job A's answer routes to job A")
        check(ledger.resolve(notificationID: b.id, action: "reply", typed: "Designer") == .answer("Designer", run: jobB), "typed reply routes to job B")
        check(ledger.resolve(notificationID: main.id, action: "option.0", typed: nil) == .answer("Go ahead", run: nil), "main agent question unaffected")
        check(ledger.liveID == b.id, "newest live question is tracked")
        check(ledger.clear(run: jobA) == a.id, "clearing a run returns its notification")
        check(ledger.resolve(notificationID: a.id, action: "option.0", typed: nil) == .stale, "answered job question is stale")
        check(ledger.resolve(notificationID: b.id, action: "option.0", typed: nil) == .answer("Engineer", run: jobB), "other job still live")
        let a2 = ledger.issue(options: ["Pune"], sensitive: false, run: jobA)
        let b2 = ledger.issue(options: ["Lead"], sensitive: false, run: jobB)
        check(b2.replaced == b.id && a2.replaced == nil, "same run replaces only its own question")
        check(ledger.resolve(notificationID: b.id, action: "option.0", typed: nil) == .stale, "replaced job question is stale")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("notification ledger: all checks passed")
    }
}

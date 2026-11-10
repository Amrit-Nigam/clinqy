import AppKit
import Foundation

// Safety.swift names the secure-input owner with this helper from the app; the test supplies the same shape.
extension NSRunningApplication { var cleanName: String? { localizedName } }

@main struct AskingPolicyTests {
    static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL: " + message) }
    }

    static func main() {
        riskTable()
        preauthorisation()
        askApproval()
        autonomyDecisions()
        overrides()
        alwaysAllowStorage()
        blockLists()
        batching()
        guard failures == 0 else { print("\(failures) asking-policy check(s) failed"); exit(1) }
        print("PASS asking policy: risk table, pre-authorisation, autonomy levels, always-allow, block lists, ask batching")
    }

    /// (label, context, request) → asks?
    static func riskTable() {
        let rows: [(String, String, String, Bool)] = [
            // Money always asks unless the request names it.
            ("Pay ₹500", "", "open the checkout page", true),
            ("Pay ₹500", "", "pay for my order", false),
            ("Place order", "", "find a usb-c cable on amazon", true),
            ("Place order", "", "buy the cheapest usb-c cable", false),
            ("Book now", "", "find flights to mumbai", true),
            ("Book now", "", "book the 7am flight to mumbai", false),
            ("Transfer", "", "check my balance", true),
            // Sending to someone.
            ("Send", "", "open my inbox", true),
            ("Send", "", "message mom hi", false),
            ("Send", "", "draft a reply but don't send it", true),
            // Permanent deletion asks; recoverable removal doesn't.
            ("Delete", "", "open my inbox", true),
            ("Delete", "", "delete the spam emails", false),
            ("Remove", "Shopping cart", "update my cart", false),
            ("Remove", "This will permanently delete the project. This cannot be undone.", "tidy the project list", true),
            ("Move to Trash", "", "clean up downloads", false),
            // Public posting asks; a share dialog doesn't.
            ("Post", "", "post this on linkedin", false),
            ("Post", "", "check my notifications", true),
            ("Share", "Share this document — copy link", "open the doc", false),
            ("Share", "Share to your feed — visible to everyone", "open the doc", true),
            // Generic submit/apply: only when the context implies money, messaging or posting.
            ("Submit", "Job application · Name · Email · Phone · Resume", "fill this application", false),
            ("Apply", "Filters · Price range", "show me cheaper hotels", false),
            ("Submit", "Checkout · Card number · CVV · Total ₹1,299", "fill the address", true),
            ("Submit", "Contact us · Message · Subject", "open the contact page", true),
            ("Submit", "", "fill the form but don't submit", true),
            ("Submit application", "", "fill the Easy Apply form but don't submit it", true),
            ("Submit application", "", "apply to this job with my details", false),
            // Harmless.
            ("Search", "", "anything", false),
            ("Next", "Checkout · Card number", "anything", false),
        ]
        for (label, context, request, asks) in rows {
            let got = Safety.needsConfirmation(label: label, request: request, context: context) != nil
            check(got == asks, "\(label) [\(context.prefix(30))] for “\(request)” should \(asks ? "" : "not ")ask")
        }
        check(RiskClassifier.classify(label: "Submit", context: "Checkout · Total $20") == .payment, "money context upgrades submit")
        check(RiskClassifier.classify(label: "Submit") == .general, "bare submit is general")
        check(RiskClassifier.classify(label: "Search") == nil, "search is harmless")
        check(Safety.isConsequential("Submit") && Safety.isConsequential("Share") && Safety.isConsequential("Remove"),
              "verification keeps the broad list")
        check(!Safety.isConsequential("Next"), "next is ordinary")
        check(Safety.isYes("Yes, always on github.com") && !Safety.isYes(QuestionPolicyStub.skip), "always answers are yes, timeout defaults are not")
    }

    static func preauthorisation() {
        check(PreAuthorization.covers(label: "Submit", kind: .formSubmit, request: "fill the form and submit it"), "submit named")
        check(PreAuthorization.covers(label: "Submit", kind: .formSubmit, request: "Submitting the form is fine"), "submitting named")
        check(PreAuthorization.covers(label: "Send", kind: .message, request: "send it to Riya"), "send named")
        check(PreAuthorization.covers(label: "Buy now", kind: .payment, request: "buy it"), "buy named")
        check(!PreAuthorization.covers(label: "Pay", kind: .payment, request: "open the checkout page"), "checkout page is not paying")
        check(!PreAuthorization.covers(label: "Submit", kind: .formSubmit, request: "fill the form, don't submit"), "negation wins")
        check(!PreAuthorization.covers(label: "Send", kind: .message, request: "write to Riya without sending"), "without sending")
        check(!PreAuthorization.covers(label: "Post", kind: .publicPost, request: "check the poster sizes"), "poster isn't post")
        // (label, kind, request, pre-authorised?) — every loose match from the review, plus the intended positives.
        let table: [(String, RiskKind, String, Bool)] = [
            ("Place order", .payment, "compare these in order to pick one", false),
            ("Submit", .formSubmit, "I'll submit it myself, just fill it", false),
            ("Submit", .formSubmit, "let me submit it, just fill the fields", false),
            ("Book", .booking, "find books", false),
            ("Book now", .booking, "find books about Goa", false),
            ("Send", .message, "email me a summary", false),
            ("Send to others", .message, "email me a summary", false),
            ("Send", .message, "send me the link", false),
            ("Send", .message, "copy the text", false),
            ("Send", .message, "read the message from Riya", false),
            ("Delete", .deletion, "clear the search", false),
            ("Delete account", .deletion, "delete the spam", false),
            ("Pay", .payment, "you shouldn't pay yet", false),
            ("Pay", .payment, "I won't pay for it, just add it to the cart", false),
            ("Pay", .payment, "Don't, under any circumstances, pay", false),
            ("Buy now", .payment, "add it to the cart; I'll buy it later", false),
            ("Post", .publicPost, "draft a post but never post it", false),
            // Still pre-authorised.
            ("Delete account", .deletion, "delete my account", true),
            ("Delete", .deletion, "delete the spam", true),
            ("Send", .message, "email Riya the summary", true),
            ("Send", .message, "write the reply and send it to Riya", true),
            ("Book now", .booking, "book the 7am flight to mumbai", true),
            ("Place order", .payment, "buy the cheapest usb-c cable", true),
            ("Submit", .formSubmit, "please submit the form", true),
            ("Send money", .transfer, "send money to mom", true),
            ("Cancel subscription", .deletion, "cancel my netflix subscription", true),
            ("Cancel subscription", .deletion, "cancel the search", false),
        ]
        for (label, kind, request, expected) in table {
            check(PreAuthorization.covers(label: label, kind: kind, request: request) == expected,
                  "“\(request)” should \(expected ? "" : "not ")pre-authorise \(label)")
        }
        check(PreAuthorization.negated(["pay"], in: "Don't, under any circumstances, pay"), "comma-separated negation")
        check(PreAuthorization.negated(["send"], in: "you shouldn't send it"), "shouldn't negates")
        check(PreAuthorization.negated(["submit"], in: "I'll submit it myself"), "first person negates")
        check(!PreAuthorization.negated(["submit"], in: "fill it and submit it"), "plain instruction is not negated")
        check(!PreAuthorization.covers(label: "Send", kind: .message, request: "Clear the search, then copy the text"), "label-derived generic words removed")
    }

    static func askApproval() {
        let unrelated = AskApproval.grants(question: "Is the blue one OK?", options: ["Yes", "No"], reply: "Yes", planFlag: false,
                                           autonomy: .irreversible, planApproved: false, timedOut: false)
        check(!unrelated.plan && unrelated.kinds.isEmpty, "an unrelated yes confirms nothing")
        let address = AskApproval.grants(question: "Use the saved address?", options: ["Yes", "No"], reply: "Yes", planFlag: false,
                                         autonomy: .plan, planApproved: false, timedOut: false)
        check(!address.plan && address.kinds.isEmpty, "an unflagged yes never approves the plan")
        let plan = AskApproval.grants(question: "1. Fill 2. Send. OK?", options: ["Go ahead", "Change something"], reply: "Go ahead",
                                      planFlag: true, autonomy: .plan, planApproved: false, timedOut: false)
        check(plan.plan && plan.kinds.isEmpty, "the flagged plan ask approves the plan only")
        let send = AskApproval.grants(question: "Should I send it to Riya?", options: ["Yes", "No"], reply: "Yes", planFlag: false,
                                      autonomy: .irreversible, planApproved: false, timedOut: false)
        check(send.kinds == [.message], "a yes to sending confirms sending only")
        let timeout = AskApproval.grants(question: "Should I send it?", options: ["Yes", "No"], reply: "Yes", planFlag: true,
                                         autonomy: .plan, planApproved: false, timedOut: true)
        check(!timeout.plan && timeout.kinds.isEmpty, "a timeout approves nothing")
        check(!AskApproval.grants(question: "Should I send it?", options: ["Yes", "No"], reply: "No", planFlag: false,
                                  autonomy: .irreversible, planApproved: false, timedOut: false).kinds.contains(.message), "no confirms nothing")
        // Timeout defaults are always marked as Clinqy's, never the user's plain option.
        let wrapped = AskApproval.timeoutReply("No")
        check(wrapped?.hasPrefix("[No reply after ") == true && wrapped != "No", "option default is marked as a timeout")
        check(AskApproval.defaultOption(wrapped) == "No", "the picked option can be read back")
        check(AskApproval.timeoutReply(QuestionPolicyStub.skip) == QuestionPolicyStub.skip, "free-text default unchanged")
        check(AskApproval.timeoutReply(nil) == nil, "no default stays a decline")
        check(!Safety.isYes(wrapped ?? ""), "a wrapped default is never a yes")
    }

    static func autonomyDecisions() {
        typealias S = AskingPolicy.Situation
        check(AskingPolicy.shouldAsk(S(kind: .payment)), "default asks before paying")
        check(!AskingPolicy.shouldAsk(S(kind: .general)), "default never asks for general")
        check(AskingPolicy.shouldAsk(S(kind: .formSubmit)), "default reviews an unnamed form submit")
        check(!AskingPolicy.shouldAsk(S(kind: .formSubmit, preauthorized: true)), "named submit needs no review")
        check(!AskingPolicy.shouldAsk(S(kind: .payment, preauthorized: true)), "named purchase needs no yes")
        check(AskingPolicy.shouldAsk(S(kind: .payment, preauthorized: true, negated: true)), "negation beats pre-authorisation")
        // plan: after approval only money asks.
        check(!AskingPolicy.shouldAsk(S(kind: .deletion, autonomy: .plan, planApproved: true)), "plan approved covers deletion")
        check(!AskingPolicy.shouldAsk(S(kind: .message, autonomy: .plan, planApproved: true)), "plan approved covers sending")
        check(AskingPolicy.shouldAsk(S(kind: .payment, autonomy: .plan, planApproved: true)), "plan still asks before paying")
        check(AskingPolicy.shouldAsk(S(kind: .deletion, autonomy: .plan, planApproved: false)), "unapproved plan behaves like default")
        // trusted: only trusted scopes skip.
        check(!AskingPolicy.shouldAsk(S(kind: .payment, autonomy: .trusted, trustedScope: true)), "trusted site skips")
        check(AskingPolicy.shouldAsk(S(kind: .payment, autonomy: .trusted, trustedScope: false)), "untrusted site still asks")
        check(AskingPolicy.shouldAsk(S(kind: .payment, autonomy: .irreversible, trustedScope: true)), "trusted scope needs trusted level")
        check(!AskingPolicy.shouldAsk(S(kind: .publicPost, alwaysAllowedKind: true)), "stored always-allow for this kind skips at any level")
        check(Autonomy.parse(nil) == .irreversible && Autonomy.parse("PLAN") == .plan && Autonomy.parse("trusted") == .trusted
              && Autonomy.parse("nonsense") == .irreversible, "AUTONOMY parsing defaults safely")
        check(AskingPolicy.confirmOptions(scopeName: "github.com") == ["Yes, go ahead", "Yes, always on github.com", "No"], "always option offered")
        check(AskingPolicy.confirmOptions(scopeName: nil) == ["Yes, go ahead", "No"], "no scope, no always option")
        check(AskingPolicy.isAlways("Yes, always on github.com") && !AskingPolicy.isAlways("Yes, go ahead"), "always reply detected")
        // A timeout default never picks an approving option.
        check(!AskingPolicy.confirmOptions(scopeName: "x.com").filter { $0.hasPrefix("Yes") }.contains("No"), "yes options are distinct from no")
    }

    static func overrides() {
        check(TaskAutonomyOverride.parse("book it, don't ask me") == .noAsk, "don't ask me")
        check(TaskAutonomyOverride.parse("clean up the inbox without asking") == .noAsk, "without asking")
        check(TaskAutonomyOverride.parse("tidy my files but ask before anything") == .askAll, "ask before anything")
        check(TaskAutonomyOverride.parse("check with me before you delete") == .askAll, "check with me before")
        check(TaskAutonomyOverride.parse("ask Riya what time works") == nil, "asking someone else isn't an override")
        typealias S = AskingPolicy.Situation
        check(AskingPolicy.shouldAsk(S(kind: .general, override: .askAll)), "ask-all asks even general")
        check(AskingPolicy.shouldAsk(S(kind: .formSubmit, override: .askAll, preauthorized: true)), "ask-all beats pre-authorisation")
        check(!AskingPolicy.shouldAsk(S(kind: .formSubmit, override: .noAsk)), "no-ask skips the review")
        check(AskingPolicy.shouldAsk(S(kind: .payment, override: .noAsk)), "no-ask never approves paying")
        check(AskingPolicy.shouldAsk(S(kind: .message, override: .noAsk)), "no-ask never approves sending")
    }

    static func alwaysAllowStorage() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("asking-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AlwaysAllowStore(url: dir.appendingPathComponent("always-allow.json"))
        check(!store.allows("publicPost", scope: "github.com"), "empty store allows nothing")
        check(store.add("publicPost", scope: "GitHub.com"), "add writes")
        check(store.allows("publicPost", scope: "github.com"), "rule is case-insensitive")
        check(!store.allows("payment", scope: "github.com"), "rule is per kind")
        check(!store.allows("publicPost", scope: "gitlab.com"), "rule is per site")
        check(store.hasAnyRule(scope: "github.com") && !store.hasAnyRule(scope: nil), "any-rule lookup")
        check(store.add(AlwaysAllowStore.foreground, scope: "app:numbers"), "foreground rule writes")
        check(!store.hasAnyRule(scope: "app:numbers"), "a foreground rule doesn't make an app trusted")
        check(store.add("adopt_tab", scope: "amazon.com"), "adopt-tab rule writes")
        check(!store.hasAnyRule(scope: "amazon.com"), "working in an open tab never makes a site trusted for payments")
        check(AlwaysAllowStore(url: store.url).allows(AlwaysAllowStore.foreground, scope: "app:Numbers"), "rules persist across instances")
        check(store.remove("publicPost", scope: "github.com") && !store.allows("publicPost", scope: "github.com"), "remove works")
        check(AskingPolicy.scope(url: "https://www.github.com/a/b?x=1") == "github.com", "site scope is the bare host")
        check(AskingPolicy.scope(url: "about:blank") == nil, "blank page has no scope")
        check(AskingPolicy.scope(app: "Numbers") == "app:numbers", "app scope")
    }

    static func blockLists() {
        check(AccessBlocklist.originRefusal(url: "https://www.chase.com/login", blocked: nil, allowed: nil) != nil, "chase blocked")
        check(AccessBlocklist.originRefusal(url: "https://netbanking.hdfcbank.com/", blocked: nil, allowed: nil) != nil, "netbanking blocked")
        check(AccessBlocklist.originRefusal(url: "https://www.icicibank.com", blocked: nil, allowed: nil) != nil, "*bank.com blocked")
        check(AccessBlocklist.originRefusal(url: "https://my.1password.com", blocked: nil, allowed: nil) != nil, "password manager site blocked")
        check(AccessBlocklist.originRefusal(url: "https://www.bankrate.com", blocked: nil, allowed: nil) == nil, "bankrate is not a bank")
        check(AccessBlocklist.originRefusal(url: "https://github.com", blocked: nil, allowed: nil) == nil, "ordinary site allowed")
        check(AccessBlocklist.originRefusal(url: "https://chase.com", blocked: nil, allowed: "chase.com") == nil, "allowed list unblocks")
        check(AccessBlocklist.originRefusal(url: "https://chase.com", blocked: "none", allowed: nil) == nil, "none empties the list")
        check(AccessBlocklist.originRefusal(url: "https://intranet.corp.example", blocked: "default, *.corp.example", allowed: nil) != nil, "custom pattern")
        check(AccessBlocklist.originRefusal(url: "https://chase.com", blocked: "default, *.corp.example", allowed: nil) != nil, "default keyword keeps defaults")
        check(AccessBlocklist.originRefusal(url: "https://chase.com", blocked: "example.org", allowed: nil) == nil, "explicit list replaces defaults")
        check(AccessBlocklist.originRefusal(url: "x-apple.systempreferences:com.apple.preference.security?Privacy", blocked: nil, allowed: nil) != nil,
              "privacy settings URL blocked")
        check(AccessBlocklist.appRefusal(name: "1Password", bundleID: nil, windowTitle: nil, blocked: nil, allowed: nil) != nil, "1Password blocked")
        check(AccessBlocklist.appRefusal(name: "Keychain Access", bundleID: "com.apple.keychainaccess", windowTitle: nil, blocked: nil, allowed: nil) != nil, "Keychain blocked")
        check(AccessBlocklist.appRefusal(name: "System Settings", bundleID: "com.apple.systempreferences", windowTitle: "Privacy & Security", blocked: nil, allowed: nil) != nil,
              "privacy pane blocked")
        check(AccessBlocklist.appRefusal(name: "System Settings", bundleID: "com.apple.systempreferences", windowTitle: "Appearance", blocked: nil, allowed: nil) == nil,
              "other settings panes allowed")
        check(AccessBlocklist.appRefusal(name: "Notes", bundleID: "com.apple.Notes", windowTitle: nil, blocked: nil, allowed: nil) == nil, "Notes allowed")
        check(AccessBlocklist.appRefusal(name: "Notes", bundleID: nil, windowTitle: nil, blocked: "default,Notes", allowed: nil) != nil, "custom app block")
        check(AskingPolicy.hostMatches("a.b.example.com", pattern: "example.com") && !AskingPolicy.hostMatches("notexample.com", pattern: "example.com"),
              "subdomain matching")
    }

    static func batching() {
        let isConfirmation: (String) -> Bool = { $0.lowercased().contains("should i") || $0.lowercased().contains("go ahead") }
        let commits: ([String: Any]) -> Bool = { !["type", "read", "open_url", "scroll"].contains($0["do"] as? String ?? "") }
        func kinds(_ actions: [[String: Any]]) -> [String] { actions.map { ($0["do"] as? String ?? "") + (($0["id"] as? String).map { ":" + $0 } ?? "") } }
        let batch: [[String: Any]] = [
            ["do": "ask", "question": "What's your LinkedIn URL?"],
            ["do": "type", "id": "w3", "text": "Pune"],
            ["do": "type", "id": "w4", "text": "5 years"],
            ["do": "click", "id": "w9"],
        ]
        check(kinds(AskBatching.reorder(batch, isConfirmation: isConfirmation, commits: commits)) == ["type:w3", "type:w4", "ask", "click:w9"],
              "independent fills run before the question; the click waits")
        let confirm: [[String: Any]] = [["do": "ask", "question": "Should I submit?", "options": ["Yes", "No"]], ["do": "type", "id": "w3", "text": "x"]]
        check(kinds(AskBatching.reorder(confirm, isConfirmation: isConfirmation, commits: commits)) == ["ask", "type:w3"], "a go-ahead question keeps its place")
        let secret: [[String: Any]] = [["do": "ask", "question": "Password?", "sensitive": true], ["do": "type", "id": "w3", "text": "x"]]
        check(kinds(AskBatching.reorder(secret, isConfirmation: isConfirmation, commits: commits)) == ["ask", "type:w3"], "private input keeps its place")
        let yesNo: [[String: Any]] = [["do": "ask", "question": "Use the Pune address?", "options": ["Yes", "No"]], ["do": "read"]]
        check(kinds(AskBatching.reorder(yesNo, isConfirmation: isConfirmation, commits: commits)) == ["ask", "read"], "yes/no options keep their place")
        let two: [[String: Any]] = [["do": "ask", "question": "Which city?"], ["do": "read"], ["do": "ask", "question": "Which date?"], ["do": "scroll"]]
        check(kinds(AskBatching.reorder(two, isConfirmation: isConfirmation, commits: commits)) == ["read", "ask", "scroll", "ask"], "asks keep their relative order")
        let alone: [[String: Any]] = [["do": "ask", "question": "Which city?"]]
        check(kinds(AskBatching.reorder(alone, isConfirmation: isConfirmation, commits: commits)) == ["ask"], "single ask unchanged")
    }
}

/// The free-text timeout default (same prefix as QuestionPolicy.skipText) must never parse as a yes.
enum QuestionPolicyStub { static let skip = "[No reply after 10 min] Skip this step: don't do anything irreversible for it." }

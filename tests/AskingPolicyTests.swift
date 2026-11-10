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
        originScopes()
        planGate()
        declinedSteps()
        answeredAndDeclinedChecklist()
        blockLists()
        batching()
        guard failures == 0 else { print("\(failures) asking-policy check(s) failed"); exit(1) }
        print("PASS asking policy: risk table, pre-authorisation, autonomy levels, always-allow, origin scopes, plan gate, declined steps, block lists, ask batching")
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
        // --- Round 6 W: sending to your own chat is not sending to another person ---
        for request in ["In WhatsApp, message myself clinqy test 1", "send clinqy test 1 to myself on WhatsApp", "message me hello on WhatsApp",
                        "Open my Message yourself chat and send clinqy test 2", "send hi to my own chat", "whatsapp myself the list"] {
            check(PreAuthorization.selfMessage(request), "self-message: \(request)")
        }
        for request in ["don't message myself", "message Riya hello", "read the message yourself", "open WhatsApp", "never send anything to myself"] {
            check(!PreAuthorization.selfMessage(request), "not a self-message: \(request)")
        }
        check(PreAuthorization.isSelfChat(["Amrit Nigam", "Message yourself"]) && PreAuthorization.isSelfChat(["Amrit (You)"])
              && PreAuthorization.isSelfChat(["Saved Messages"]), "self chat markers")
        check(!PreAuthorization.isSelfChat(["Riya", "online"]), "another person's chat is not the self chat")

        // --- Round 8 #2: one self-send decision for a native Send click and for Return ---
        for label in ["Send", "send button", "paper-plane", "paperplane.fill", "Send message", "Paper plane icon"] {
            check(SelfSend.isSendControl(label), "send control: \(label)")
        }
        for label in ["Send money", "Send invoice", "Send to Riya", "Delete", "Sender", "Attach", ""] {
            check(!SelfSend.isSendControl(label), "not a send control: \(label)")
        }
        let selfChat = ["Amrit Nigam", "Message yourself", "Type a message"]
        let selfRequest = "In WhatsApp, message myself clinqy test 4"
        check(SelfSend.exempt(request: selfRequest, control: "Send", headerTexts: selfChat), "self request + self chat + Send click: no approval")
        check(SelfSend.exempt(request: selfRequest, control: "Send message", headerTexts: selfChat), "self request + self chat + Return: no approval")
        check(SelfSend.exempt(request: selfRequest, control: "Send", headerTexts: ["Saved Messages"]), "Saved Messages counts")
        check(SelfSend.exempt(request: selfRequest, control: "paper-plane", headerTexts: ["Amrit (You)"]), "(You) + paper-plane counts")
        check(!SelfSend.exempt(request: selfRequest, control: "Send", headerTexts: ["Riya", "online"]), "another person's chat still asks")
        check(!SelfSend.exempt(request: "In WhatsApp, message Riya hello", control: "Send", headerTexts: selfChat), "a request to someone else still asks")
        check(!SelfSend.exempt(request: "don't message myself", control: "Send", headerTexts: selfChat), "a negated self-message still asks")
        check(!SelfSend.exempt(request: selfRequest, control: "Send money", headerTexts: selfChat), "a non-Send control still asks")
        check(!SelfSend.exempt(request: selfRequest, control: "Delete chat", headerTexts: selfChat), "deleting in the self chat still asks")
        check(!SelfSend.exempt(request: selfRequest, control: "Send", headerTexts: nil), "an unresolved header still asks")

        // --- Round 8: the self-chat marker counts only in the OPEN conversation's header, never the chat list ---
        typealias N = ConversationHeader.Node
        func window(sidebarRow: String, header: [String]?, subtitle: String? = nil) -> N {
            // Sidebar on the left (x 0–300): search field + chat list; conversation pane on the right (x 300–1000).
            let sidebar = N(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 300, height: 800), children: [
                N(role: "AXTextField", texts: ["Search"], frame: CGRect(x: 10, y: 10, width: 280, height: 30)),
                N(role: "AXList", frame: CGRect(x: 0, y: 50, width: 300, height: 750), children: [
                    N(role: "AXRow", texts: [sidebarRow], frame: CGRect(x: 0, y: 50, width: 300, height: 60)),
                    N(role: "AXRow", texts: ["Amrit Nigam (You)", "Message yourself"], frame: CGRect(x: 0, y: 110, width: 300, height: 60)),
                ]),
            ])
            var pane: [N] = []
            if let header {
                var group = N(role: "AXGroup", frame: CGRect(x: 300, y: 0, width: 700, height: 60), children: header.map {
                    N(role: "AXStaticText", texts: [$0], frame: CGRect(x: 320, y: 10, width: 300, height: 20)) })
                if let subtitle { group.children.append(N(role: "AXStaticText", texts: [subtitle], frame: CGRect(x: 320, y: 32, width: 300, height: 18))) }
                pane.append(group)
            }
            pane.append(N(role: "AXScrollArea", frame: CGRect(x: 300, y: 60, width: 700, height: 680), children: [
                N(role: "AXStaticText", texts: ["Message yourself"], frame: CGRect(x: 320, y: 100, width: 300, height: 20))]))
            pane.append(N(role: "AXGroup", frame: CGRect(x: 300, y: 740, width: 700, height: 60), children: [
                N(role: "AXTextArea", frame: CGRect(x: 320, y: 750, width: 600, height: 40), isComposer: true),
                N(role: "AXButton", texts: ["Send"], frame: CGRect(x: 930, y: 750, width: 40, height: 40))]))
            return N(role: "AXWindow", texts: ["WhatsApp"], frame: CGRect(x: 0, y: 0, width: 1000, height: 800), children: [
                sidebar, N(role: "AXGroup", frame: CGRect(x: 300, y: 0, width: 700, height: 800), children: pane)])
        }
        let riya = ConversationHeader.resolve(root: window(sidebarRow: "Message yourself", header: ["Riya"], subtitle: "online"), windowTitle: "WhatsApp")
        check(riya == ["Riya", "online"], "the open header is Riya's, not the sidebar row: \(String(describing: riya))")
        check(!SelfSend.exempt(request: selfRequest, control: "Send", headerTexts: riya), "sidebar says Message yourself, header says Riya: ask")
        let own = ConversationHeader.resolve(root: window(sidebarRow: "Riya", header: ["Amrit Nigam"], subtitle: "Message yourself"), windowTitle: "WhatsApp")
        check(own == ["Amrit Nigam", "Message yourself"], "the open header is the self chat: \(String(describing: own))")
        check(SelfSend.exempt(request: selfRequest, control: "Send", headerTexts: own), "header Amrit Nigam / Message yourself: no ask")
        let unresolved = ConversationHeader.resolve(root: window(sidebarRow: "Message yourself", header: nil), windowTitle: nil)
        check(unresolved == nil, "no header and no window title: unresolved, never the sidebar or message list")
        check(!SelfSend.exempt(request: selfRequest, control: "Send", headerTexts: unresolved), "unresolved header: ask")
        let titled = ConversationHeader.resolve(root: window(sidebarRow: "Message yourself", header: nil), windowTitle: "WhatsApp")
        check(titled == ["WhatsApp"] && !SelfSend.exempt(request: selfRequest, control: "Send", headerTexts: titled), "the window title is the fallback; WhatsApp's is no marker")
        let savedTitle = ConversationHeader.resolve(root: window(sidebarRow: "Riya", header: nil), windowTitle: "Saved Messages")
        check(SelfSend.exempt(request: selfRequest, control: "Send", headerTexts: savedTitle), "a chat name in the window title counts")
        var twoHeaders = window(sidebarRow: "Riya", header: ["Amrit Nigam"], subtitle: "Message yourself")
        twoHeaders.children[1].children.insert(N(role: "AXGroup", frame: CGRect(x: 300, y: 0, width: 700, height: 20), children: [
            N(role: "AXStaticText", texts: ["Riya"], frame: CGRect(x: 320, y: 0, width: 100, height: 20))]), at: 0)
        check(ConversationHeader.resolve(root: twoHeaders, windowTitle: "WhatsApp") == nil, "two header candidates: ambiguous, ask")
        var noComposer = window(sidebarRow: "Riya", header: ["Amrit Nigam"], subtitle: "Message yourself")
        noComposer.children[1].children[2].children[0].isComposer = false
        check(ConversationHeader.resolve(root: noComposer, windowTitle: "Saved Messages") == nil, "no composer: unresolved")

        // --- Round 9: WhatsApp's real shape. The header is a nav bar at the top of the conversation column
        // (Window > G > G > G > G > G > [AXButton name, AXGroup > AXStaticText subtitle], ~10 pt below the window's top),
        // the message list is a plain group (not a list/table/scroll area) directly above the composer bar, and the
        // composer the run holds may be the observed field (id) or the app's focused element inside it (no id).
        struct WA { var name = "Amrit Nigam", subtitle = "Message yourself", sidebarRow = "Riya", bubble = "clinqy test 5"
                    var dx: CGFloat = 0, dy: CGFloat = 0, focusedInner = false, flatBubbles = false, header = true }
        func whatsapp(_ o: WA) -> N {
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x + o.dx, y: y + o.dy, width: w, height: h) }
            let sidebar = N(role: "AXGroup", frame: r(20, 33, 450, 826), children: [
                N(role: "AXGroup", frame: r(20, 33, 450, 52), children: [N(role: "AXStaticText", texts: ["Chats"], frame: r(40, 45, 80, 20))]),
                N(role: "AXTextField", texts: ["Search"], frame: r(30, 90, 430, 30)),
                N(role: "AXTable", frame: r(20, 130, 450, 729), children: [
                    N(role: "AXRow", texts: [o.sidebarRow], frame: r(20, 130, 450, 70)),
                    N(role: "AXRow", texts: ["Amrit Nigam (You)", "Message yourself"], frame: r(20, 200, 450, 70))])])
            let navBar = N(role: "AXGroup", frame: r(470, 33, 981, 52), children: [
                N(role: "AXGroup", frame: r(580, 38, 400, 42), children: [
                    N(role: "AXButton", texts: [o.name], frame: r(593, 43, 90, 20)),
                    N(role: "AXGroup", frame: r(689, 45, 120, 18), children: [N(role: "AXStaticText", texts: [o.subtitle], frame: r(689, 45, 120, 18))])]),
                N(role: "AXButton", texts: ["Video call"], frame: r(1350, 45, 30, 30))])
            let bubbles = (0..<6).map { i in
                N(role: "AXGroup", frame: r(500, 100 + CGFloat(i) * 110, 600, 60), children: [
                    N(role: "AXStaticText", texts: [i == 0 ? "Message yourself (You)" : o.bubble], frame: r(510, 105 + CGFloat(i) * 110, 500, 20))]) }
            let messages = N(role: "AXGroup", frame: r(470, 85, 981, 700), children: bubbles)
            var field = N(role: "AXTextArea", texts: ["Compose message"], frame: r(540, 795, 800, 40), isComposer: !o.focusedInner)
            if o.focusedInner { field.children = [N(role: "AXTextArea", frame: r(545, 800, 790, 30), isComposer: true)] }
            let composerBar = N(role: "AXGroup", frame: r(470, 785, 981, 74), children: [
                N(role: "AXButton", texts: ["Attach"], frame: r(480, 800, 30, 30)),
                N(role: "AXGroup", frame: r(540, 795, 800, 40), children: [field]),
                N(role: "AXButton", texts: ["Send"], frame: r(1400, 800, 30, 30))])
            let chatView = N(role: "AXGroup", frame: r(470, 85, 981, 774), children: o.flatBubbles ? bubbles + [composerBar] : [messages, composerBar])
            let column = N(role: "AXGroup", frame: r(470, 33, 981, 826), children: (o.header ? [navBar] : []) + [chatView])
            return N(role: "AXWindow", texts: ["WhatsApp"], frame: r(20, 33, 1431, 826), children: [
                N(role: "AXGroup", frame: r(20, 33, 1431, 826), children: [N(role: "AXGroup", frame: r(20, 33, 1431, 826), children: [sidebar, column])])])
        }
        let waRequest = "In WhatsApp, message myself (Amrit Nigam, Message yourself) \"clinqy test 6\""
        for (label, o) in [("foreground, id composer", WA()), ("foreground, id-less focused inner field", WA(focusedInner: true)),
                           ("background lane (virtual screen offset), id composer", WA(dx: 6000, dy: 200)),
                           ("background lane, id-less focused inner field", WA(dx: 6000, dy: 200, focusedInner: true))] {
            let header = ConversationHeader.resolve(root: whatsapp(o), windowTitle: "WhatsApp")
            check(header?.contains("Message yourself") == true && header?.contains("Amrit Nigam") == true && header?.contains("clinqy test 5") == false,
                  "\(label): the nav bar header is read, not the plain-group message list: \(String(describing: header))")
            check(SelfSend.exempt(request: waRequest, control: "Send message", headerTexts: header), "\(label): verified self chat, type-submit needs no approval")
            check(ConversationHeader.candidateCount(root: whatsapp(o)) == 1, "\(label): exactly one header candidate")
        }
        for o in [WA(name: "Riya", subtitle: "online", sidebarRow: "Message yourself"), WA(name: "Riya", subtitle: "online", sidebarRow: "Message yourself", dx: 6000, focusedInner: true)] {
            let header = ConversationHeader.resolve(root: whatsapp(o), windowTitle: "WhatsApp")
            check(header?.contains("Riya") == true && !SelfSend.exempt(request: waRequest, control: "Send message", headerTexts: header),
                  "another chat open: the sidebar row and a bubble saying Message yourself never count: \(String(describing: header))")
        }
        let flat = ConversationHeader.resolve(root: whatsapp(WA(name: "Riya", subtitle: "online", flatBubbles: true)), windowTitle: "WhatsApp")
        check(flat == nil, "message bubbles flat beside the composer: a top bubble saying (You) is no header; ambiguous, ask")
        let flatNoHeader = ConversationHeader.resolve(root: whatsapp(WA(name: "Riya", subtitle: "online", flatBubbles: true, header: false)), windowTitle: "WhatsApp")
        check(!SelfSend.exempt(request: waRequest, control: "Send message", headerTexts: flatNoHeader), "no header, flat bubbles: never exempt (\(String(describing: flatNoHeader)))")
        let noHeader = ConversationHeader.resolve(root: whatsapp(WA(header: false)), windowTitle: "WhatsApp")
        check(noHeader == ["WhatsApp"] && !SelfSend.exempt(request: waRequest, control: "Send message", headerTexts: noHeader),
              "no header bar: the message list is never read as one; the window title has no marker, ask")
        var twoBars = whatsapp(WA())
        twoBars.children[0].children[0].children[1].children.insert(N(role: "AXGroup", frame: CGRect(x: 470, y: 33, width: 981, height: 30), children: [
            N(role: "AXStaticText", texts: ["Riya"], frame: CGRect(x: 600, y: 38, width: 80, height: 20))]), at: 0)
        check(ConversationHeader.resolve(root: twoBars, windowTitle: "WhatsApp") == nil, "two header bars over the composer: ambiguous, ask")

        // --- Round 10: "1 header candidate" yet no marker. Live AX paths: name AXButton at Window>G>G>G>G>G>AXButton
        // (x593,y43) and the marker AXStaticText one group deeper (x689,y45), beside it. Here the name button, the
        // subtitle group, help-only icon buttons, the message list and the composer bar share one container, and the
        // subtitle's group reports no frame: it was never a candidate, so only the name was read.
        struct WA10 { var name = "Amrit Nigam", subtitle = "Message yourself", sidebarRow = "Riya"
                      var subtitleFramed = false, subtitleX: CGFloat = 689, nameHelp: String? = nil, nameDescription: String? = nil
                      var subtitleShown = true, bubbleBelowHeader: String? = nil, extraHeader: String? = nil, dx: CGFloat = 0, dy: CGFloat = 0 }
        func whatsapp10(_ o: WA10) -> N {
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x + o.dx, y: y + o.dy, width: w, height: h) }
            let sidebar = N(role: "AXGroup", frame: r(20, 33, 450, 826), children: [
                N(role: "AXGroup", frame: r(20, 33, 450, 52), children: [N(role: "AXStaticText", texts: ["Chats"], frame: r(40, 45, 80, 20))]),
                N(role: "AXTable", frame: r(20, 130, 450, 729), children: [
                    N(role: "AXRow", texts: [o.sidebarRow], frame: r(20, 130, 450, 70)),
                    N(role: "AXRow", texts: ["Amrit Nigam (You)", "Message yourself"], frame: r(20, 200, 450, 70))])])
            var name = N(role: "AXButton", texts: [o.name] + (o.nameDescription.map { [$0] } ?? []), frame: r(593, 43, 90, 20))
            if let help = o.nameHelp { name.help = [help] }
            var conv: [N] = [name]
            if o.subtitleShown {
                conv.append(N(role: "AXGroup", frame: o.subtitleFramed ? r(o.subtitleX, 45, 120, 18) : nil, children: [
                    N(role: "AXStaticText", texts: [o.subtitle], frame: r(o.subtitleX, 45, 120, 18))]))
            }
            conv.append(N(role: "AXButton", frame: r(1350, 45, 30, 30), help: ["Video call"]))
            conv.append(N(role: "AXButton", frame: r(1390, 45, 30, 30), help: ["Search"]))
            if let extra = o.extraHeader { conv.append(N(role: "AXStaticText", texts: [extra], frame: r(900, 45, 100, 20))) }
            if let bubble = o.bubbleBelowHeader {   // a frameless message group right under the header bar
                conv.append(N(role: "AXGroup", children: [N(role: "AXStaticText", texts: [bubble], frame: r(510, 100, 400, 20))]))
            }
            conv.append(N(role: "AXGroup", frame: r(470, 130, 981, 650), children: (0..<4).map { i in
                N(role: "AXGroup", frame: r(500, 140 + CGFloat(i) * 120, 600, 60), children: [
                    N(role: "AXStaticText", texts: ["clinqy test 7"], frame: r(510, 145 + CGFloat(i) * 120, 500, 20))]) }))
            conv.append(N(role: "AXGroup", frame: r(470, 785, 981, 74), children: [
                N(role: "AXGroup", frame: r(540, 795, 800, 40), children: [
                    N(role: "AXTextArea", texts: ["Compose message"], frame: r(540, 795, 800, 40), isComposer: true)]),
                N(role: "AXButton", texts: ["Send"], frame: r(1400, 800, 30, 30))]))
            let column = N(role: "AXGroup", frame: r(470, 33, 981, 826), children: [
                N(role: "AXGroup", frame: r(470, 33, 981, 826), children: [N(role: "AXGroup", frame: r(470, 33, 981, 826), children: conv)])])
            return N(role: "AXWindow", texts: ["WhatsApp"], frame: r(20, 33, 1431, 826), children: [
                N(role: "AXGroup", frame: r(20, 33, 1431, 826), children: [N(role: "AXGroup", frame: r(20, 33, 1431, 826), children: [sidebar, column])])])
        }
        let wa10Request = "In WhatsApp, message myself (Amrit Nigam, Message yourself) \"clinqy test 7\""
        func exempt10(_ o: WA10) -> Bool {
            SelfSend.exempt(request: wa10Request, control: "Send", headerTexts: ConversationHeader.resolve(root: whatsapp10(o), windowTitle: "WhatsApp"))
        }
        for (label, o) in [("frameless subtitle group beside the name", WA10()),
                           ("background lane offset", WA10(dx: 6000, dy: 200)),
                           ("framed subtitle in its own sibling group", WA10(subtitleFramed: true, subtitleX: 689)),
                           ("(You) subtitle", WA10(subtitle: "(You)")),
                           ("marker only in the name button's AXHelp", WA10(nameHelp: "Amrit Nigam (You)", subtitleShown: false)),
                           ("marker in the name button's AXDescription", WA10(nameDescription: "Message yourself", subtitleShown: false))] {
            let tree = whatsapp10(o)
            if o.subtitleFramed {
                // A framed subtitle is a second header-like sibling: still ambiguous by the existing rule, ask.
                check(ConversationHeader.resolve(root: tree, windowTitle: "WhatsApp") == nil, "\(label): two candidates stay ambiguous")
                continue
            }
            check(ConversationHeader.candidateCount(root: tree) == 1, "\(label): exactly one header candidate (help-only icon buttons are none)")
            check(exempt10(o), "\(label): the self marker in the same top bar is read: no Send approval (\(String(describing: ConversationHeader.resolve(root: tree, windowTitle: "WhatsApp"))))")
            check(ConversationHeader.resolve(root: tree, windowTitle: "WhatsApp")?.contains("clinqy test 7") == false, "\(label): the message list is never read")
        }
        check(!exempt10(WA10(name: "Riya", subtitle: "online", sidebarRow: "Message yourself")),
              "another chat open, the sidebar row says Message yourself: ask")
        check(!exempt10(WA10(name: "Riya", subtitle: "online", sidebarRow: "Message yourself", bubbleBelowHeader: "Message yourself (You)")),
              "a frameless message just below the header bar never counts: ask")
        check(!exempt10(WA10(name: "Riya", subtitle: "Message yourself", subtitleX: 200)),
              "a frameless marker beside the conversation (sidebar columns) never counts: ask")
        check(!exempt10(WA10(name: "Riya", subtitle: "online", nameHelp: "Riya")), "help without a marker: ask")
        check(ConversationHeader.resolve(root: whatsapp10(WA10(extraHeader: "Riya")), windowTitle: "WhatsApp") == nil,
              "a second header-like text in the bar: ambiguous, ask")
        // --- Round 11: WhatsApp Catalyst's real AX ids and invisible LEFT-TO-RIGHT MARKs (U+200E) ---
        check(AXText.normalized("(\u{200E}You)") == "(you)", "U+200E stripped from the badge")
        check(AXText.normalized(" \u{202A}Saved\u{2069}   Messages\u{FEFF} ") == "saved messages", "bidi controls stripped, spaces collapsed")
        check(AXText.sameName("\u{200E}Amrit  Nigam", "amrit nigam\u{200F}"), "chat names compare normalised")
        check(!AXText.sameName("Riya", "Amrit Nigam"), "different names differ")
        check(PreAuthorization.isSelfChat(["(\u{200E}You)"]), "(\\u200EYou) is the self badge")
        check(PreAuthorization.isSelfChat(["\u{200E}Message\u{200E} yourself"]), "Message yourself with marks")
        check(PreAuthorization.isSelfChat(["\u{200E}You"]), "a bare You header")
        check(PreAuthorization.isSelfChat(["\u{2066}SAVED MESSAGES\u{2069}"]), "Saved Messages with isolates")
        check(!PreAuthorization.isSelfChat(["Riya", "online", "Your message"]), "no marker, no self chat")
        struct WA11 { var name = "Amrit Nigam", badge = true, bubble = "Your message, clinqy test 8, Sent to \u{200E}You, 10:01"
                      var secondHeaderBar = false, badgeID = true, ids = true }
        func whatsapp11(_ o: WA11) -> N {
            func id(_ s: String) -> String? { o.ids ? s : nil }
            let sidebarBar = N(role: "AXGroup", frame: CGRect(x: 20, y: 33, width: 519, height: 46), children: [
                N(role: "AXButton", texts: ["\u{200E}New Chat"], frame: CGRect(x: 480, y: 40, width: 30, height: 30), identifier: id("NavigationBar_NewChatButton")),
                N(role: "AXStaticText", texts: ["\u{200E}Search"], frame: CGRect(x: 30, y: 60, width: 480, height: 18), identifier: id("TokenizedSearchBar_TextView")),
            ], identifier: id("WDSNavigationBar"))
            let sidebar = N(role: "AXGroup", frame: CGRect(x: 20, y: 33, width: 519, height: 826), children: [
                sidebarBar,
                N(role: "AXTable", frame: CGRect(x: 20, y: 130, width: 519, height: 729), children: [
                    N(role: "AXRow", texts: ["\u{200E}Amrit Nigam (\u{200E}You)", "\u{200E}Message yourself"], frame: CGRect(x: 20, y: 130, width: 519, height: 70))])])
            var barKids: [N] = [N(role: "AXButton", texts: [o.name], frame: CGRect(x: 600, y: 40, width: 120, height: 20), identifier: id("NavigationBar_HeaderViewButton"))]
            barKids.append(N(role: "AXGroup", children: o.badge
                ? [N(role: "AXStaticText", texts: ["(\u{200E}You)"], frame: CGRect(x: 725, y: 42, width: 40, height: 18), identifier: o.badgeID ? id("WABadgedLabel_You") : nil)]
                : [N(role: "AXStaticText", texts: ["\u{200E}online"], frame: CGRect(x: 725, y: 42, width: 60, height: 18))]))
            barKids.append(N(role: "AXGroup", frame: CGRect(x: 1300, y: 40, width: 60, height: 30)))
            barKids.append(N(role: "AXButton", frame: CGRect(x: 1400, y: 40, width: 30, height: 30), identifier: id("NavigationBar_MoreButton")))
            let headerBar = N(role: "AXGroup", frame: CGRect(x: 540, y: 33, width: 911, height: 46), children: barKids, identifier: id("WDSNavigationBar"))
            let bubbles = (0..<3).map { i in
                N(role: "AXStaticText", texts: [o.bubble], frame: CGRect(x: 600, y: 120 + CGFloat(i) * 80, width: 500, height: 60), identifier: id("WAMessageBubbleTableViewCell")) }
            let pane = N(role: "AXGroup", frame: CGRect(x: 540, y: 79, width: 911, height: 780), children: [
                N(role: "AXGroup", frame: CGRect(x: 540, y: 79, width: 911, height: 700), children: bubbles),
                N(role: "AXGroup", frame: CGRect(x: 540, y: 785, width: 911, height: 74), children: [
                    N(role: "AXTextArea", texts: ["\u{200E}Type a message"], frame: CGRect(x: 600, y: 795, width: 760, height: 40), isComposer: true),
                    N(role: "AXButton", texts: ["\u{200E}Send"], frame: CGRect(x: 1400, y: 800, width: 30, height: 30))])])
            var convKids = [headerBar, pane]
            if o.secondHeaderBar {
                convKids.insert(N(role: "AXGroup", frame: CGRect(x: 540, y: 33, width: 911, height: 46), children: [
                    N(role: "AXButton", texts: ["Riya"], frame: CGRect(x: 600, y: 40, width: 120, height: 20), identifier: id("NavigationBar_HeaderViewButton"))],
                    identifier: id("WDSNavigationBar")), at: 0)
            }
            let conv = N(role: "AXGroup", frame: CGRect(x: 540, y: 33, width: 911, height: 826), children: convKids)
            // /0/0/1/2/0 is the header bar: window > group > group > [sidebar, spacer, conversation].
            return N(role: "AXWindow", texts: ["\u{200E}WhatsApp"], frame: CGRect(x: 20, y: 33, width: 1431, height: 826), children: [
                N(role: "AXGroup", frame: CGRect(x: 20, y: 33, width: 1431, height: 826), children: [
                    N(role: "AXGroup", frame: CGRect(x: 20, y: 33, width: 1431, height: 826), children: [
                        sidebar, N(role: "AXGroup", frame: CGRect(x: 539, y: 33, width: 1, height: 826)), conv])])])
        }
        let wa11Request = "In WhatsApp, message myself \"clinqy test 8\""
        func exempt11(_ o: WA11) -> Bool {
            SelfSend.exempt(request: wa11Request, control: "\u{200E}Send", headerTexts: ConversationHeader.resolve(root: whatsapp11(o), windowTitle: "\u{200E}WhatsApp"))
        }
        let selfTree = whatsapp11(WA11())
        check(selfTree.children[0].children[0].children[2].children[0].identifier == "WDSNavigationBar", "fixture: header bar at /0/0/2/0 of the conversation")
        check(ConversationHeader.candidateCount(root: selfTree) == 1, "real WhatsApp ids: exactly one identified header bar")
        let selfHeader = ConversationHeader.resolve(root: selfTree, windowTitle: "\u{200E}WhatsApp")
        check(selfHeader?.contains { $0.contains("Search") || $0.contains("New Chat") || $0.contains("clinqy test 8") } == false,
              "the sidebar bar and message bubbles are never read: \(String(describing: selfHeader))")
        check(exempt11(WA11()), "real WhatsApp self chat with U+200E badge: no ask (\(String(describing: selfHeader)))")
        check(exempt11(WA11(badgeID: false)), "the (\\u200EYou) badge text alone, without its id, counts")
        check(!exempt11(WA11(name: "Riya", badge: false, bubble: "Your message, hi, Sent to You, 10:02")), "Riya's chat, a bubble says Sent to You: ask")
        check(!exempt11(WA11(name: "Riya", badge: false, bubble: "Message yourself (You)")), "Riya's chat, a bubble says (You): ask")
        check(ConversationHeader.resolve(root: whatsapp11(WA11(secondHeaderBar: true)), windowTitle: "WhatsApp") == nil,
              "two identified header bars: ambiguous, ask")
        check(!exempt11(WA11(secondHeaderBar: true)), "two identified header bars: ask")
        // No ids (another app with the same shape): the generic heuristic still decides, with normalised markers.
        check(exempt11(WA11(ids: false)), "no ids: the generic fallback reads the (\\u200EYou) badge beside the name")
        check(!exempt11(WA11(name: "Riya", badge: false, bubble: "Sent to You", ids: false)), "no ids, Riya's chat: ask")

        // "message X <text>" names the recipient and the send: that exact send needs no second yes.
        check(PreAuthorization.covers(label: "Send message", kind: .message, request: "In WhatsApp, message Riya hello there"), "message Riya <text> pre-authorises the send")
        check(PreAuthorization.covers(label: "Send message", kind: .message, request: "On WhatsApp, message Riya that I'm late"), "message Riya that … pre-authorises the send")
        check(!PreAuthorization.covers(label: "Send message", kind: .message, request: "In WhatsApp, open Riya's chat; don't message her"), "a negated message is never pre-authorised")
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

    /// "Yes, always" is scoped by origin: a non-default port is its own site; 80/443 are the bare host.
    static func originScopes() {
        check(AskingPolicy.scope(url: "http://127.0.0.1:63447/checkout") == "127.0.0.1:63447", "local port kept")
        check(AskingPolicy.scope(url: "http://127.0.0.1:64524/") != AskingPolicy.scope(url: "http://127.0.0.1:63447/"), "different local ports are different sites")
        check(AskingPolicy.scope(url: "https://example.com:443/x") == "example.com", "443 is the bare host")
        check(AskingPolicy.scope(url: "http://example.com:80/") == "example.com", "80 is the bare host")
        check(AskingPolicy.scope(url: "http://example.com:443/") == "example.com", "default ports normalise whatever the scheme")
        check(AskingPolicy.scope(url: "https://example.com:8443/") == "example.com:8443", "public non-default port kept")
        check(AskingPolicy.scope(url: "http://[::1]:3000/") == "[::1]:3000", "IPv6 literal with port")
        check(AskingPolicy.scope(url: "localhost:5173") == "localhost:5173", "scheme-less host:port")
        check(AskingPolicy.host(of: "http://127.0.0.1:63447/a") == "127.0.0.1", "host(of:) still drops the port")
        for local in ["localhost", "127.0.0.1", "10.0.0.5", "192.168.1.20", "172.20.1.1", "169.254.3.3", "[::1]", "fd12::1", "app.localhost", "mac.local", "100.101.1.1"] {
            check(AskingPolicy.isLocalHost(local), "local host \(local)")
        }
        for remote in ["example.com", "8.8.8.8", "172.32.0.1", "fdroid.org", "192.169.1.1"] { check(!AskingPolicy.isLocalHost(remote), "public host \(remote)") }
        check(AskingPolicy.legacyScope("example.com:8443") == "example.com", "public port reads the old host-only rule")
        check(AskingPolicy.legacyScope("127.0.0.1:64524") == nil, "local port never reads a host-only rule")
        check(AskingPolicy.legacyScope("example.com") == nil && AskingPolicy.legacyScope("app:numbers") == nil, "nothing to fall back to")
        check(AskingPolicy.scopeMatches("127.0.0.1:63447", pattern: "127.0.0.1:63447"), "allowed origin with port")
        check(!AskingPolicy.scopeMatches("127.0.0.1:64524", pattern: "127.0.0.1:63447"), "allowed origin port is exact")
        check(AskingPolicy.scopeMatches("localhost:3000", pattern: "localhost"), "portless allowed origin covers its host")
        check(AskingPolicy.scopeMatches("shop.example.com", pattern: "example.com") && AskingPolicy.scopeMatches("a.example.com:8080", pattern: "*.example.com"), "subdomains and wildcards")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("asking-scope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AlwaysAllowStore(url: dir.appendingPathComponent("always-allow.json"))
        // Retest B8: "Yes, always" on 127.0.0.1:63447 must not pay on 127.0.0.1:64524.
        check(store.add("payment", scope: AskingPolicy.scope(url: "http://127.0.0.1:63447/")!), "local always rule writes")
        check(store.allows("payment", scope: AskingPolicy.scope(url: "http://127.0.0.1:63447/pay")), "same service: no ask")
        check(!store.allows("payment", scope: AskingPolicy.scope(url: "http://127.0.0.1:64524/")), "other local port asks")
        check(!store.allows("payment", scope: AskingPolicy.scope(url: "http://localhost:63447/")), "other local host asks")
        check(!store.hasAnyRule(scope: "127.0.0.1:64524"), "other local port isn't trusted")
        // Old host-only rules: still read for public sites (any port), never across local ports.
        check(store.add("payment", scope: "127.0.0.1") && store.add("publicPost", scope: "example.com"), "legacy rules written")
        check(!store.allows("payment", scope: "127.0.0.1:64524") && !store.hasAnyRule(scope: "127.0.0.1:64524"), "legacy local host rule doesn't cover a port")
        check(store.allows("payment", scope: "127.0.0.1"), "legacy local rule still covers the default port")
        check(store.allows("publicPost", scope: AskingPolicy.scope(url: "https://example.com:443/")), "example.com:443 is example.com")
        check(store.allows("publicPost", scope: "example.com:8443") && store.hasAnyRule(scope: "example.com:8443"), "legacy public rule still read")
        check(!store.allows("publicPost", scope: "other.com:8443"), "legacy rule is per host")
    }

    static func planGate() {
        check(Autonomy.requestsPlan("show me the plan first, then fill the form"), "per-task plan phrase")
        check(Autonomy.requestsPlan("Ask once at the start, then book it"), "ask once at the start")
        check(!Autonomy.requestsPlan("plan my trip to Goa"), "planning a trip isn't the plan level")
        check(PlanGate.applies(autonomy: .plan, override: nil, dryRun: false), "plan level gates")
        check(!PlanGate.applies(autonomy: .irreversible, override: nil, dryRun: false), "default level doesn't gate")
        check(!PlanGate.applies(autonomy: .plan, override: nil, dryRun: true), "dry runs change nothing")
        for kind in ["read", "look", "snap", "verify", "wait", "ask", "plan", "scroll"] {
            check(!PlanGate.needsApproval(["do": kind], navigations: 0), "\(kind) runs before approval")
        }
        check(!PlanGate.needsApproval(["do": "open_url", "url": "http://127.0.0.1:1/"], navigations: 0), "opening the start page runs")
        check(PlanGate.needsApproval(["do": "open_url", "url": "http://x/"], navigations: 1), "further navigation waits")
        check(!PlanGate.needsApproval(["do": "tab", "op": "list"], navigations: 0) && PlanGate.needsApproval(["do": "tab", "op": "close"], navigations: 0), "tab ops")
        check(!PlanGate.needsApproval(["do": "pdf", "op": "info"], navigations: 0), "read-only pdf info")
        for kind in ["type", "click", "fill", "key", "choose", "set_value", "shell", "applescript", "delegate", "email", "upload"] {
            check(PlanGate.needsApproval(["do": kind], navigations: 0), "\(kind) needs the approved plan")
        }
        let q = PlanGate.question(request: "fill the form and pay", steps: ["Fill name", "Pay"])
        check(q.contains("1. Fill name") && q.contains("2. Pay") && q.contains("Go ahead?"), "question lists the plan")
        check(PlanGate.question(request: "fill the form", steps: []).contains("fill the form"), "no checklist: the request")
        check(PlanGate.options == ["Go ahead", "Change it", "Stop"], "options")
        check(PlanGate.interpret("Go ahead", timedOut: false) == .approve && PlanGate.interpret("yes", timedOut: false) == .approve, "approve")
        check(PlanGate.interpret("Stop", timedOut: false) == .stop && PlanGate.interpret("No", timedOut: false) == .stop, "stop")
        check(PlanGate.interpret(nil, timedOut: false) == .stop, "no answer stops")
        check(PlanGate.interpret(AskApproval.timeoutReply("Stop"), timedOut: true) == .stop, "timeout stops, never approves")
        check(PlanGate.interpret("Change it", timedOut: false) == .change(nil), "change asks what")
        check(PlanGate.interpret("use my work email", timedOut: false) == .change("use my work email"), "free text is the change")
        // The timeout default for the plan question is Stop.
        check(PlanDefaultStub.safeDefault(PlanGate.options) == "Stop", "timeout default picks Stop")
    }

    /// Live report B11: plan approved, blue design Yes, Pay No → the ask step is answered, the pay click is skipped,
    /// and nothing stale is left "Still required".
    static func answeredAndDeclinedChecklist() {
        let titles = ["Fill name Test and email test@example.test", "Ask user if blue design is OK", "Click primary button after approval"]
        let plan = PlanGate.question(request: "fill the form, ask me if the blue design is OK, then click the primary button", steps: titles)
        var answers: [ChecklistResolution.Answer] = [.init(question: plan, reply: "Go ahead")]
        var declined = DeclinedActions()
        var states = ChecklistResolution.resolve(titles, answers: answers, declined: declined)
        check(states[1] == .open, "approving the plan does not answer its ask step")
        answers.append(.init(question: "Is the blue design OK?", reply: "Yes"))
        states = ChecklistResolution.resolve(titles, answers: answers, declined: declined)
        check(states[1] == .answered("Answered by you: Yes"), "answered question resolves its ask step")
        check(states[2] == .open, "the click waits for its own approval")
        answers.append(.init(question: "About to click “Pay now”. Go ahead?", reply: "No"))
        declined.record(kind: .payment, label: "Pay now", scope: "127.0.0.1:64868", timedOut: false)
        states = ChecklistResolution.resolve(titles, answers: answers, declined: declined)
        check(states[1] == .answered("Answered by you: Yes"), "a later No does not reopen the answered design step")
        check(states[2] == .skipped("Skipped by you: “Pay now”"), "the approval-gated click is skipped by you: Pay now")
        check(states[0] == .open, "unrelated fill step is not settled by answers")
        check(!states[1...].contains(.open), "no stale required ask/click items remain")
        // Ask-step recognition and matching.
        check(ChecklistResolution.isAskStep("Confirm with the user before submitting"), "confirm-with-user is an ask step")
        check(!ChecklistResolution.isAskStep("Check the order total"), "checking a page is not an ask step")
        check(ChecklistResolution.answers(step: "Get the user's approval", question: "Should I continue?"), "generic approval step: any answer")
        check(!ChecklistResolution.answers(step: "Ask user if blue design is OK", question: "Which shipping speed?"), "unrelated question doesn't settle it")
        check(!ChecklistResolution.isApprovalGatedAction("Click Save"), "plain click is not approval-gated")
        check(ChecklistResolution.resolve(["Click Save"], answers: [], declined: declined) == [.open], "unrelated click stays open")
    }

    static func declinedSteps() {
        var d = DeclinedActions()
        check(d.isEmpty && d.matching(kind: .payment, label: "Pay now", scope: "127.0.0.1:64868") == nil, "nothing declined")
        d.record(kind: .payment, label: "Pay now", scope: "127.0.0.1:64868", timedOut: true)
        check(d.matching(kind: .payment, label: "Pay now", scope: "127.0.0.1:64868") != nil, "same step refused without asking")
        check(d.matching(kind: .payment, label: "Pay ₹500", scope: "127.0.0.1:64868") != nil, "same payment, other label")
        check(d.matching(kind: .payment, label: "Pay now", scope: "127.0.0.1:1") == nil, "other site asks")
        check(d.matching(kind: .message, label: "Send", scope: "127.0.0.1:64868") == nil, "other kind asks")
        check(DeclinedActions.refusal(d.entries[0]).contains("Don't try it again or ask again"), "refusal tells the model to report it")
        d.record(kind: .deletion, label: "Delete account", scope: "x.com", timedOut: false)
        check(d.matching(kind: .deletion, label: "Delete photo", scope: "x.com") == nil, "different object is a different step")
        check(d.matching(kind: .deletion, label: "Delete account", scope: "x.com") != nil, "same object")
        check(d.resolves("Pay for the order") != nil, "payment outcome resolved as skipped")
        check(d.resolves("Click Pay now") != nil, "outcome naming the control resolved")
        check(d.resolves("Fill name and email") == nil, "unrelated outcome stays open")
        check(d.summary.contains("Pay now"), "summary names the skipped step")
        d.clear(kinds: [.payment])
        check(d.matching(kind: .payment, label: "Pay now", scope: "127.0.0.1:64868") == nil, "a later yes lifts it")
        // Model's own questions.
        check(AskApproval.declinedKind(question: "Should I pay now?", reply: "No", timedOut: false) == .payment, "explicit No declines")
        check(AskApproval.declinedKind(question: "Should I pay now?", reply: nil, timedOut: true) == .payment, "timeout declines")
        check(AskApproval.declinedKind(question: "Should I pay now?", reply: "Yes", timedOut: false) == nil, "yes isn't a decline")
        check(AskApproval.declinedKind(question: "Should I pay now?", reply: "use the other card", timedOut: false) == nil, "free text isn't a decline")
        check(AskApproval.declinedKind(question: "Is the blue design OK?", reply: "No", timedOut: false) == nil, "unrelated question")
        // "msg X hello on whatsapp" pre-authorises sending that message.
        check(PreAuthorization.covers(label: "Send message", kind: .message, request: "msg amrit nigam hello on whatsapp"), "msg pre-authorises the send")
        check(!PreAuthorization.covers(label: "Send message", kind: .message, request: "read my whatsapp messages"), "reading isn't sending")
        check(RiskClassifier.isMessagingSurface("Compose message\nWhatsApp") && !RiskClassifier.isMessagingSurface("Search\nNotes"), "messaging surface")
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

/// QuestionPolicy lives in RunSupervisor.swift (not compiled here): the same "declining option first" rule for the
/// plan question's options, mirrors QuestionPolicy.declining.
enum PlanDefaultStub {
    static func safeDefault(_ options: [String]) -> String? {
        for pattern in [#"(?i)^\s*skip\b"#, #"(?i)^\s*(not now|later|don'?t|do not)\b"#, #"(?i)^\s*no\b"#, #"(?i)^\s*keep\b"#, #"(?i)^\s*(cancel|stop)\b"#] {
            if let o = options.first(where: { $0.range(of: pattern, options: .regularExpression) != nil }) { return o }
        }
        return nil
    }
}

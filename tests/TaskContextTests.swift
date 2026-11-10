import Foundation

enum Secrets { static func mask(_ text: String) -> String { text } }
@MainActor final class Probe { var marker = "" }

@main struct TaskContextTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        let contexts = (0..<3).map { _ in TaskExecutionContext() }
        let outputs = await withTaskGroup(of: String.self) { group in
            for (index, context) in contexts.enumerated() {
                group.addTask { @MainActor in
                    await TaskExecution.$current.withValue(context) {
                        let probe = context.service(Probe.self, make: Probe.init)
                        probe.marker = "worker-\(index)"
                        try? await Task.sleep(for: .milliseconds(30))
                        let nested = Task { @MainActor in TaskExecution.current?.service(Probe.self, make: Probe.init).marker ?? "lost" }
                        return await nested.value
                    }
                }
            }
            var result: [String] = []
            for await value in group { result.append(value) }
            return result.sorted()
        }
        check(outputs == ["worker-0", "worker-1", "worker-2"], "three suspended jobs retain their own observations and nested task identity")
        check(TaskExecution.current == nil, "background contexts never leak onto the foreground controller")
        check(CursorVisibility.suppressPrimary(browserCursor: true, backgroundIndicators: 0, foregroundRunning: true), "page cursor replaces native companion during browser actions")
        check(CursorVisibility.suppressPrimary(browserCursor: false, backgroundIndicators: 3, foregroundRunning: false), "corner cursors replace idle companion during background jobs")
        check(!CursorVisibility.suppressPrimary(browserCursor: false, backgroundIndicators: 3, foregroundRunning: true), "independent native task keeps its own companion")
        check(CursorVisibility.suppressPrimary(browserCursor: true, backgroundIndicators: 3, foregroundRunning: true), "browser cursor ownership stays exclusive alongside background indicators")
        check(CursorVisibility.suppressPrimary(browserCursor: true, backgroundIndicators: 0, foregroundRunning: false), "companion stays hidden until page overlay cleanup completes")
        check(!CursorVisibility.suppressPrimary(browserCursor: false, backgroundIndicators: 0, foregroundRunning: false), "ordinary companion returns after browser feedback is cleared")
        check(CursorVisibility.suppressPrimary(browserCursor: false, backgroundIndicators: 0, foregroundRunning: true, inputPanelVisible: true), "new-task composer owns input without a duplicate desktop companion")
        check(contexts[0].service(Probe.self, make: Probe.init) !== contexts[1].service(Probe.self, make: Probe.init), "services are distinct instances")
        let stopped = Task { await TaskExecution.$current.withValue(contexts[0]) { try? await Task.sleep(for: .seconds(10)) } }
        stopped.cancel(); await stopped.value
        check(contexts[1].service(Probe.self, make: Probe.init).marker == "worker-1", "canceling one job doesn't reset another")
        check(BrowserTaskRouting.isBrowserTask("On Chrome open 3 tabs and work simultaneously"), "Chrome tasks default to browser workers")
        check(BrowserTaskRouting.requestsParallel("Open three tabs"), "explicit tab fanout detected")
        check(BrowserTaskRouting.requestsExistingTabs("Read the three already open Chrome tabs"), "already-open tab request enables discovery")
        check(BrowserTaskRouting.requestsExistingTabs("The assignment tabs are open already"), "trailing existing-tab wording enables discovery")
        check(BrowserTaskRouting.requestsExistingTabs("Do these tabs in parallel"), "referenced current tabs enable discovery")
        check(!BrowserTaskRouting.requestsExistingTabs("Open three new tabs about Pokemon"), "new-tab task does not discover personal tabs")
        check(!BrowserTaskRouting.requestsParallel("Open a tab and then log in"), "dependent single workflow is not split")
        check(BrowserTaskRouting.browser(in: "On Chrome open YouTube") == "Google Chrome", "explicit browser overrides default")
        check(!BrowserTaskRouting.isBrowserTask("Open TextEdit and write a note"), "native task retains the main controller")
        check(!BrowserTaskRouting.isBrowserTask("Open WhatsApp and write a message"), "WhatsApp app uses the independent desktop slot")
        check(BrowserTaskRouting.isBrowserTask("Write a message in WhatsApp Web"), "explicit WhatsApp Web uses the browser pool")
        check(BrowserTaskRouting.isBrowserTask("Do this in Arc"), "explicit browser choice starts a browser job")
        check(TaskCapacity.canStart(background: false, foregroundRunning: false, backgroundRunning: 3, limit: 3), "native task can start alongside browser workers")
        check(!TaskCapacity.canStart(background: true, foregroundRunning: false, backgroundRunning: 3, limit: 3), "excess browser jobs queue")
        check(TaskCapacity.canStart(background: true, foregroundRunning: true, backgroundRunning: 2, limit: 3), "new browser task can start during native work")
        // Phase 5: requests about a tab the user already has open adopt it instead of re-opening the site.
        for phrase in ["Summarize this tab", "Fill the form on the current page", "In my open github tab, star the repo",
                       "Use the tab I have open to reply", "Reply in the gmail tab I have open", "Check the page I'm on",
                       "In the already open gmail, archive the newsletter", "Work in my existing jira tab"] {
            check(TabAdoptionRouting.requestsAdoption(phrase), "adoption phrase: \(phrase)")
        }
        for phrase in ["Open github and star the repo", "Open three new tabs about Pokemon", "Read the three already open Chrome tabs",
                       "Summarize the tabs I already have open", "Open a new tab and search flights"] {
            check(!TabAdoptionRouting.requestsAdoption(phrase), "not adoption: \(phrase)")
        }
        check(TabAdoptionRouting.siteHint("In my open github tab, star it") == "github", "site named before 'tab'")
        check(TabAdoptionRouting.siteHint("In the already open gmail, archive it") == "gmail", "site after 'already open'")
        check(TabAdoptionRouting.siteHint("Summarize this tab") == nil, "'this tab' names no site")
        check(TabAdoptionRouting.siteHint("Use my open tab for https://www.example.com/x") == "example.com", "explicit URL names the site")
        let open: [TabAdoptionRouting.Candidate] = [
            .init(id: 1, title: "repo · GitHub", url: "https://github.com/me/repo", active: true, lastFocusedWindow: true),
            .init(id: 2, title: "Inbox - me@gmail.com - Gmail", url: "https://mail.google.com/mail/u/0", active: false, lastFocusedWindow: true),
            .init(id: 3, title: "Issues · GitHub", url: "https://github.com/me/repo/issues", active: true, lastFocusedWindow: false),
            .init(id: 4, title: "New Tab", url: "chrome://newtab/", active: true, lastFocusedWindow: false),
            .init(id: 5, title: "Docs", url: "https://docs.test", active: false, lastFocusedWindow: false),
            .init(id: 6, title: "Docs two", url: "https://docs.test/2", active: false, lastFocusedWindow: true),
        ]
        check(TabAdoptionRouting.choose("Summarize this tab", candidates: open) == .adopt(1), "'this tab' = active tab of last-focused window")
        check(TabAdoptionRouting.choose("archive it in the already open gmail", candidates: open) == .adopt(2), "title match finds Gmail")
        check(TabAdoptionRouting.choose("In my open github tab, star it", candidates: open) == .adopt(1), "several matches: active tab of last-focused window wins")
        check(TabAdoptionRouting.choose("Edit my open docs.test tab", candidates: open) == .ask([5, 6]), "several matches and none in front: ask once")
        check(TabAdoptionRouting.choose("In my open jira tab, file it", candidates: open) == .none, "no match: open a task tab as usual")
        check(TabAdoptionRouting.choose("Summarize this tab", candidates: [open[3]]) == .none, "browser pages are never adopted")
        check(TabAdoptionRouting.consent("Yes") == .adopt && TabAdoptionRouting.consent("Yes, always on github.com") == .adoptAlways,
              "consent yes / always")
        check(TabAdoptionRouting.consent("Open a new tab instead") == .newTab && TabAdoptionRouting.consent(nil) == .newTab
              && TabAdoptionRouting.consent("[No reply after 10 min] Skip this step") == .newTab, "anything else (incl. timeout) opens a new tab")
        check(TabAdoptionRouting.consentOptions(site: "github.com") == ["Yes", "Yes, always on github.com", "Open a new tab instead"], "consent options")
        check(TabAdoptionRouting.lane(extensionConnected: true, nativeLaneEnabled: true) == .extensionAdopt, "extension adopts")
        // Live report C2/W1: background app requests run on the main agent's native lane, not in isolated browser jobs.
        let apps: Set<String> = ["textedit", "whatsapp", "notes", "slack", "google chrome", "github desktop"]
        let installed = { (name: String) in apps.contains(name) }
        let lane = { (text: String) in BackgroundRouting.lane(for: text, isApp: installed) }
        check(lane("In TextEdit, type hello world and make it bold.") == .mainAgent, "TextEdit request stays native")
        check(lane("In TextEdit, paste the youtube link from https://example.com") == .mainAgent, "TextEdit names the target even with a URL")
        check(lane("in WhatsApp, send mom the youtube link") == .mainAgent, "WhatsApp app target beats a browser word")
        check(lane("msg mom hi on whatsapp") == .mainAgent, "Telegram-style msg on whatsapp is native")
        check(lane("add the gmail summary on Notes") == .mainAgent, "on Notes names the Notes app")
        check(lane("open whatsapp web and read my chats") == .browserJob, "WhatsApp Web is the site")
        check(lane("open github in chrome") == .browserJob, "open github in chrome is a browser job")
        check(lane("search google for flights on the website") == .browserJob, "search on a website is a browser job")
        check(lane("open https://github.com/notes in chrome") == .browserJob, "a URL in Chrome is a browser job")
        check(lane("open the notes tab in chrome") == .browserJob, "lowercase notes is not the Notes app")
        check(lane("book a cab for tonight") == .mainAgent, "ambiguous non-browser request runs on the main agent")
        check(lane("search google for the weather") == .mainAgent, "no browser word: main agent decides")
        check(BackgroundRouting.namedNativeApp(in: "In TextEdit, type hi", isApp: installed) == "textedit", "app name extracted")
        check(BackgroundRouting.namedNativeApp(in: "check github in Google Chrome", isApp: installed) == nil, "browsers are not native targets")
        check(TabAdoptionRouting.lane(extensionConnected: false, nativeLaneEnabled: true) == .nativeWindow, "no extension: native window lane")
        check(TabAdoptionRouting.lane(extensionConnected: false, nativeLaneEnabled: false) == .unavailable, "neither: unavailable")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TaskStore(file: folder.appendingPathComponent("tasks.json"))
        store.backgroundLimit = 3
        let ids = (0..<4).map { store.enqueue("Browser \($0)", source: .mac, background: true)! }
        for id in ids.prefix(3) { check(store.start(id), "three durable jobs can run together") }
        check(!store.start(ids[3]), "fourth durable browser job waits")
        let native = store.enqueue("Native", source: .mac, background: false)!
        check(store.start(native), "foreground starts while three background records are running")
        let another = store.enqueue("Other native", source: .mac, background: false)!
        check(!store.start(another), "two native controllers cannot fight for input")
        store.coordinate(ids[0])
        check(store.start(ids[3]), "coordinator waiting for children frees its browser slot")
        check(store.record(ids[0])?.coordinating == true, "parent coordination state is durable")
        check(store.activeBackground.count == 3 && store.activeForeground?.id == native, "separate foreground and background ownership")
        // A final answer may not claim an action whose latest result failed.
        let failedUpload: [FailedClaimGuard.Attempt] = [.init(step: "Type “Amrit”", failed: false), .init(step: "Upload Amrit_Resume_C.pdf", failed: true)]
        let claimed = "Form filled but not submitted: the consent checkbox has no clickable element in background mode, so I couldn't tick it. Filled and checked: name Amrit Nigam, a@b.com, +91 93267-70790, and Amrit_Resume_C.pdf uploaded. The consent box is still unticked."
        check(FailedClaimGuard.correction(answer: claimed, attempts: failedUpload)?.contains("upload of Amrit_Resume_C.pdf failed") == true, "false upload claim gets a correction")
        check(FailedClaimGuard.correction(answer: "Not submitted: the form is filled (Amrit Nigam, Amrit_Resume_C.pdf uploaded), but the consent box can't be ticked.", attempts: failedUpload) != nil, "claim inside parentheses is caught")
        check(FailedClaimGuard.correction(answer: "Filled the form. I couldn't upload Amrit_Resume_C.pdf: the page didn't take the file.", attempts: failedUpload) == nil, "an honest failure report is left alone")
        check(FailedClaimGuard.correction(answer: "Filled and the resume uploaded.", attempts: failedUpload) != nil, "an upload claim without the file name is caught")
        check(FailedClaimGuard.correction(answer: claimed, attempts: failedUpload + [.init(step: "Upload Amrit_Resume_C.pdf", failed: false)]) == nil, "a later successful retry clears it")
        check(FailedClaimGuard.correction(answer: "Clicked Apply and submitted.", attempts: [.init(step: "Click Apply", failed: true)])?.contains("clicking “Apply” failed") == true, "false click claim gets a correction")
        check(FailedClaimGuard.correction(answer: "Searched and opened the page.", attempts: [.init(step: "Click Apply", failed: true)]) == nil, "unrelated answers are left alone")
        // Round 5 J2: a not-ok run always names the failed action, even when its answer was already honest.
        let j2: [FailedClaimGuard.Attempt] = [.init(step: "Type “Test”", failed: false), .init(step: "Upload test-resume.pdf", failed: true),
                                              .init(step: "Verify outcome", failed: true), .init(step: "Upload test-resume.pdf", failed: true)]
        check(FailedClaimGuard.failureNote(attempts: j2) == "Note: the upload of test-resume.pdf failed.", "failed upload is noted once; failed checks are not actions")
        check(FailedClaimGuard.failureNote(attempts: j2 + [.init(step: "Upload test-resume.pdf", failed: false)]) == nil, "a later successful retry clears the note")
        check(FailedClaimGuard.failureNote(attempts: [.init(step: "Click Apply", failed: true), .init(step: "Press cmd+s", failed: true)]) == "Note: clicking “Apply” failed; “Press cmd+s” failed.", "every failed action is named")
        check(FailedClaimGuard.failureNote(attempts: [.init(step: "Verify outcome", failed: true)]) == nil, "only failed checks: no note")

        // Round 5 J4: a plain follow-up inherits the prior task's mode, lane and browser before the mode is chosen.
        let chrome = FollowUpInheritance.prior(historyRequest: "In the background: In Google Chrome, open http://127.0.0.1:58834/?key=k and fill it. Fill but do not submit.", task: nil)
        check(chrome.background && chrome.request.hasPrefix("In Google Chrome"), "history's background prefix is the prior mode")
        let submit = FollowUpInheritance.route(followUp: "submit it", prior: chrome, explicitBackground: nil, isApp: { _ in false })
        check(submit == .init(background: true, lane: .browserJob, browser: "Google Chrome"), "“submit it” stays a background Chrome browser job")
        check(FollowUpInheritance.route(followUp: "submit it", prior: chrome, explicitBackground: false, isApp: { _ in false }) == .init(background: false, lane: .mainAgent, browser: "Google Chrome"), "an explicit foreground follow-up runs in front")
        let front = FollowUpInheritance.prior(historyRequest: "In Google Chrome, open https://example.com", task: nil)
        check(FollowUpInheritance.route(followUp: "submit it", prior: front, explicitBackground: nil, isApp: { _ in false }).background == false, "a foreground prior stays foreground")
        let nativePrior = FollowUpInheritance.prior(historyRequest: "In the background: In TextEdit, type hello", task: nil)
        check(FollowUpInheritance.route(followUp: "make it bold", prior: nativePrior, explicitBackground: nil, isApp: { _ in false }) == .init(background: true, lane: .mainAgent, browser: nil), "a native background prior stays on the main agent in the background")
        let chained = FollowUpInheritance.prior(historyRequest: "In the background: continue", task: "In the background: In Google Chrome, open https://jobs.test/apply")
        check(FollowUpInheritance.route(followUp: "submit it", prior: chained, explicitBackground: nil, isApp: { _ in false }).lane == .browserJob, "the chain's first request names the lane")
        check(FollowUpInheritance.route(followUp: "paste it in TextEdit", prior: chrome, explicitBackground: nil, isApp: { _ in false }).lane == .mainAgent, "a follow-up naming its own app takes the native lane")
        print("PASS \(checks) parallel task ownership, capacity, routing and cancellation checks")
    }
}

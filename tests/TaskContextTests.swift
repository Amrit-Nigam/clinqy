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
        print("PASS \(checks) parallel task ownership, capacity, routing and cancellation checks")
    }
}

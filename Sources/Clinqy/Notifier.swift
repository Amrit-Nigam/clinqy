import AppKit
@preconcurrency import UserNotifications

/// How a background run reaches the user, who isn't watching it: a notification when it's done, and one when it
/// needs them, answerable right there (a button per option, or a typed reply). Tapping either opens Clinqy.
@MainActor
enum Notifier {
    /// The user answered the question from the notification (`run`: the browser job that asked, nil = main agent).
    static var onAnswer: (_ text: String, _ run: UUID?) -> Void = { _, _ in }
    /// The user tapped a notification (true: the question one): show them Clinqy, or the work.
    static var onOpen: (_ question: Bool, _ run: UUID?) -> Void = { _, _ in }

    private static let delegate = Delegate()
    /// Which question is on show and the options it was issued with; responses resolve through it by notification id.
    private static var ledger = NotificationLedger()

    static func start() {
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Every category in use: setting them replaces the whole set, so a question's never drops "Done"'s.
    private static var categories: [String: UNNotificationCategory] = [:]

    /// The run has finished (or given up). The result's first items ride along (prices, places, links), and the
    /// notification can show the work, bring its window over, or open the first link. Several stack as one group.
    /// `needsLook`: a consequential item finished unconfirmed (not ok, but not a failure either).
    static func finished(request: String, answer: String, ok: Bool, result: ResultCard? = nil, needsLook: Bool = false) {
        guard NotificationPolicy.enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = finishedTitle(ok: ok, answer: answer, needsLook: needsLook)
        content.subtitle = String(request.prefix(80))
        let items = (result?.items ?? []).prefix(3).map { "• " + $0.title + ($0.subtitle.map { " — " + $0 } ?? "") }
        content.body = ([String(answer.prefix(items.isEmpty ? 240 : 140))] + items).joined(separator: "\n")
        content.sound = .default
        content.threadIdentifier = "clinqy.done"
        // The link rides with its own notification, so a later "Done" can't redirect this one's Open button.
        let link = result?.items.lazy.compactMap { $0.link.flatMap(URL.init(string:)) }.first
        if let link { content.userInfo = ["link": link.absoluteString] }
        var actions = [UNNotificationAction(identifier: "show", title: "Show me", options: [.foreground]),
                       UNNotificationAction(identifier: "bring", title: "Bring it here", options: [.foreground])]
        if link != nil { actions.append(UNNotificationAction(identifier: "link", title: "Open link", options: [.foreground])) }
        let category = UNNotificationCategory(identifier: link == nil ? "clinqy.done" : "clinqy.done.link", actions: actions,
                                              intentIdentifiers: [], options: [])
        register(category)
        content.categoryIdentifier = category.identifier
        post("clinqy.done.\(UUID().uuidString)", content)
    }

    static func finishedTitle(ok: Bool, answer: String, needsLook: Bool) -> String {
        ok ? "Done" : needsLook ? "Needs a look" : answer == "Stopped" ? "Stopped" : "Couldn't finish"
    }

    private static var questionCategories: [String] = []
    private static func register(_ category: UNNotificationCategory) {
        // Parallel jobs can each have a live question: keep the newest few question categories.
        if category.identifier.hasPrefix("clinqy.q.") {
            questionCategories.append(category.identifier)
            while questionCategories.count > 8 { categories[questionCategories.removeFirst()] = nil }
        }
        categories[category.identifier] = category
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
    }

    /// The run is waiting on the user. A private answer (a password, a code) is never typed into a notification:
    /// that one only opens Clinqy. `run` is nil for the main agent; a browser job passes its task ID so the answer goes
    /// back to it. `note` says what happens with no answer ("No answer in 10 min → I'll skip this step").
    static func ask(_ text: String, options: [String], sensitive: Bool, run: UUID? = nil, note: String? = nil, title: String? = nil) {
        // Notifications off: no banner. The question stays answerable in Clinqy's panel/bar/badge and Telegram.
        guard NotificationPolicy.enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Clinqy needs you"
        if let title, !title.isEmpty { content.subtitle = String(title.prefix(80)) }
        let limit = note == nil ? 240 : 190
        content.body = String(text.prefix(limit)) + (note.map { "\n" + $0 } ?? "")
        content.sound = .default
        let issued = ledger.issue(options: options, sensitive: sensitive, run: run)
        var actions = issued.actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: []) as UNNotificationAction }
        if !sensitive {
            actions.append(UNTextInputNotificationAction(identifier: "reply", title: options.isEmpty ? "Reply" : "Something else…",
                                                         options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"))
        }
        // A category per question: its buttons are the question's own options.
        let category = UNNotificationCategory(identifier: "clinqy.q.\(UUID().uuidString)", actions: actions, intentIdentifiers: [], options: [])
        register(category)
        content.categoryIdentifier = category.identifier
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: issued.replaced.map { [$0] } ?? [])
        post(issued.id, content)
    }

    /// The question was answered (here or in Clinqy): its notification goes. nil = the main agent's question.
    static func clearQuestion(run: UUID? = nil) {
        guard let live = ledger.clear(run: run) else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [live])
        center.removePendingNotificationRequests(withIdentifiers: [live])
    }

    private static func post(_ id: String, _ content: UNMutableNotificationContent) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                let why = error?.localizedDescription ?? "notifications are off for Clinqy"
                DispatchQueue.main.async { Agent.writeLog("notification not shown: \(why)") }
                return
            }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    fileprivate static func respond(notificationID: String, action: String, typed: String?, link: String?) {
        switch action {
        case "bring":
            AgentScreen.bringHere()
            Task { await Background.showLast() }
        case "link":
            if let link, let url = URL(string: link) { NSWorkspace.shared.open(url) }
        default:
            switch ledger.resolve(notificationID: notificationID, action: action, typed: typed) {
            case .answer(let text, let run): onAnswer(text, run)
            case .open(let question, let run): onOpen(question, run)
            case .stale: Agent.writeLog("notification response ignored: its question is no longer open")
            }
        }
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        // Clinqy is a menu-bar app, often "in front" while its bar is up: show the banner anyway.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
            done([.banner, .sound])
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler done: @escaping () -> Void) {
            let action = response.actionIdentifier
            let typed = (response as? UNTextInputNotificationResponse)?.userText
            let id = response.notification.request.identifier
            let link = response.notification.request.content.userInfo["link"] as? String
            DispatchQueue.main.async {
                Notifier.respond(notificationID: id, action: action, typed: typed, link: link)
                done()
            }
        }
    }
}

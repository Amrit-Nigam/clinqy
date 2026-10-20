import AppKit
@preconcurrency import UserNotifications

/// How a background run reaches the user, who isn't watching it: a notification when it's done, and one when it
/// needs them, answerable right there (a button per option, or a typed reply). Tapping either opens Clinqy.
@MainActor
enum Notifier {
    /// The user answered the question from the notification.
    static var onAnswer: (String) -> Void = { _ in }
    /// The user tapped a notification (true: the question one): show them Clinqy, or the work.
    static var onOpen: (_ question: Bool) -> Void = { _ in }

    private static let delegate = Delegate()
    nonisolated fileprivate static let questionID = "clinqy.question"
    /// The options of the question on show, by action id.
    private static var options: [String: String] = [:]

    static func start() {
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// The link of the last "Done" notification's result, for its Open button.
    private static var link: URL?
    /// Every category in use: setting them replaces the whole set, so a question's never drops "Done"'s.
    private static var categories: [String: UNNotificationCategory] = [:]

    /// The run has finished (or given up). The result's first items ride along (prices, places, links), and the
    /// notification can show the work, bring its window over, or open the first link. Several stack as one group.
    static func finished(request: String, answer: String, ok: Bool, result: ResultCard? = nil) {
        let content = UNMutableNotificationContent()
        content.title = ok ? "Done" : answer == "Stopped" ? "Stopped" : "Couldn't finish"
        content.subtitle = String(request.prefix(80))
        let items = (result?.items ?? []).prefix(3).map { "• " + $0.title + ($0.subtitle.map { " — " + $0 } ?? "") }
        content.body = ([String(answer.prefix(items.isEmpty ? 240 : 140))] + items).joined(separator: "\n")
        content.sound = .default
        content.threadIdentifier = "clinqy.done"
        link = result?.items.lazy.compactMap { $0.link.flatMap(URL.init(string:)) }.first
        var actions = [UNNotificationAction(identifier: "show", title: "Show me", options: [.foreground]),
                       UNNotificationAction(identifier: "bring", title: "Bring it here", options: [.foreground])]
        if link != nil { actions.append(UNNotificationAction(identifier: "link", title: "Open link", options: [.foreground])) }
        let category = UNNotificationCategory(identifier: link == nil ? "clinqy.done" : "clinqy.done.link", actions: actions,
                                              intentIdentifiers: [], options: [])
        register(category)
        content.categoryIdentifier = category.identifier
        post("clinqy.done.\(UUID().uuidString)", content)
    }

    private static func register(_ category: UNNotificationCategory) {
        // Only the newest question's buttons are needed.
        if category.identifier.hasPrefix("clinqy.q.") { categories = categories.filter { !$0.key.hasPrefix("clinqy.q.") } }
        categories[category.identifier] = category
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
    }

    /// The run is waiting on the user. A private answer (a password, a code) is never typed into a notification:
    /// that one only opens Clinqy.
    static func ask(_ text: String, options: [String], sensitive: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Clinqy needs you"
        content.body = String(text.prefix(240))
        content.sound = .default
        self.options = [:]
        var actions: [UNNotificationAction] = []
        if !sensitive {
            for (i, option) in options.prefix(4).enumerated() {
                let id = "option.\(i)"
                self.options[id] = option
                actions.append(UNNotificationAction(identifier: id, title: String(option.prefix(40)), options: []))
            }
            actions.append(UNTextInputNotificationAction(identifier: "reply", title: options.isEmpty ? "Reply" : "Something else…",
                                                         options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"))
        }
        // A category per question: its buttons are the question's own options.
        let category = UNNotificationCategory(identifier: "clinqy.q.\(UUID().uuidString)", actions: actions, intentIdentifiers: [], options: [])
        register(category)
        content.categoryIdentifier = category.identifier
        post(questionID, content)
    }

    /// The question was answered (here or in Clinqy): its notification goes.
    static func clearQuestion() {
        options = [:]
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [questionID])
        center.removePendingNotificationRequests(withIdentifiers: [questionID])
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

    fileprivate static func respond(action: String, typed: String?, question: Bool) {
        switch action {
        case "reply":
            if let typed, !typed.trimmingCharacters(in: .whitespaces).isEmpty { onAnswer(typed) } else { onOpen(true) }
        case let id where options[id] != nil:
            onAnswer(options[id]!)
        case "bring":
            AgentScreen.bringHere()
            Task { await Background.showLast() }
        case "link":
            if let link { NSWorkspace.shared.open(link) }
        default:
            onOpen(question)
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
            let question = response.notification.request.identifier == Notifier.questionID
            DispatchQueue.main.async {
                Notifier.respond(action: action, typed: typed, question: question)
                done()
            }
        }
    }
}

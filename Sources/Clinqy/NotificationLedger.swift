import Foundation

/// Which question a notification response belongs to. Every question notification carries its own identifier and
/// the run it came from; a response is honoured only while that question is still live, and it resolves through the
/// options that notification was issued with, never through whatever question was asked last. Each run has at most
/// one live question (a newer one from the same run retires the older), so parallel browser jobs can each ask.
struct NotificationLedger {
    static let questionPrefix = "clinqy.question."

    enum Resolution: Equatable {
        /// `run` is nil for the main agent's own question.
        case answer(String, run: UUID?)
        case open(question: Bool, run: UUID?)
        /// The response belongs to a question that has been answered, cleared or replaced.
        case stale
    }

    private struct Live { var run: UUID?; var options: [String: String]; var order: Int }
    private var live: [String: Live] = [:]
    private var counter = 0

    /// The most recently issued live question.
    var liveID: String? { live.max { $0.value.order < $1.value.order }?.key }
    var liveIDs: Set<String> { Set(live.keys) }
    func liveID(run: UUID?) -> String? { live.first { $0.value.run == run }?.key }

    /// A new question: the same run's previous one is retired. Returns the identifier to post it under, its actions
    /// and the identifier it replaced (to remove from Notification Center).
    mutating func issue(options list: [String], sensitive: Bool, run: UUID? = nil)
        -> (id: String, actions: [(id: String, title: String)], replaced: String?) {
        let replaced = clear(run: run)
        let id = Self.questionPrefix + UUID().uuidString
        var options: [String: String] = [:]
        var actions: [(String, String)] = []
        if !sensitive {
            for (i, option) in list.prefix(4).enumerated() {
                let action = "option.\(i)"
                options[action] = option
                actions.append((action, String(option.prefix(40))))
            }
        }
        counter += 1
        live[id] = Live(run: run, options: options, order: counter)
        return (id, actions, replaced)
    }

    /// Retires one run's question. Returns its identifier, if one was live.
    @discardableResult
    mutating func clear(run: UUID?) -> String? {
        guard let id = liveID(run: run) else { return nil }
        live[id] = nil
        return id
    }

    mutating func clear() { live = [:] }

    static func isQuestion(_ notificationID: String) -> Bool { notificationID.hasPrefix(questionPrefix) }

    func resolve(notificationID: String, action: String, typed: String?) -> Resolution {
        guard Self.isQuestion(notificationID) else { return .open(question: false, run: nil) }
        guard let question = live[notificationID] else { return .stale }
        switch action {
        case "reply":
            if let typed, !typed.trimmingCharacters(in: .whitespaces).isEmpty { return .answer(typed, run: question.run) }
            return .open(question: true, run: question.run)
        case let id where question.options[id] != nil:
            return .answer(question.options[id]!, run: question.run)
        default:
            return .open(question: true, run: question.run)
        }
    }
}

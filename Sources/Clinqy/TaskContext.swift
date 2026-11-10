import Foundation

/// Each browser job gets independent singleton-backed services. Swift task-local inheritance keeps
/// observations, tabs and undo/replay state with the job across suspension and child tasks.
final class TaskExecutionContext: @unchecked Sendable {
    let id: UUID
    @MainActor private var services: [ObjectIdentifier: AnyObject] = [:]
    init(id: UUID = UUID()) { self.id = id }
    @MainActor func service<T: AnyObject>(_ type: T.Type, make: () -> T) -> T {
        let key = ObjectIdentifier(type)
        if let existing = services[key] as? T { return existing }
        let created = make(); services[key] = created; return created
    }
}

enum TaskExecution {
    @TaskLocal static var current: TaskExecutionContext?
}

enum BrowserTaskRouting {
    static func browser(in text: String) -> String? {
        let value = text.lowercased()
        for (pattern, name) in [(#"\b(chrome|google chrome)\b"#, "Google Chrome"), (#"\barc\b"#, "Arc"),
                                (#"\bbrave\b"#, "Brave Browser"), (#"\b(edge|microsoft edge)\b"#, "Microsoft Edge")] {
            if value.range(of: pattern, options: .regularExpression) != nil { return name }
        }
        return nil
    }
    static func isBrowserTask(_ text: String) -> Bool {
        text.range(of: #"(?i)https?://|\b(chrome|browser|website|webpage|youtube|spotify|wikipedia|linkedin|gmail)\b|\bwhatsapp\s+web\b|\b(in|on|using)\s+(arc|brave|edge)\b|\b(open|use|search|work).{0,30}\b(tabs?|arc|brave|edge)\b"#, options: .regularExpression) != nil
    }
    static func requestsExistingTabs(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(already\s+open|existing|current|active|these|those)\b.{0,100}\btabs?\b|\btabs?\b.{0,80}\b(already\s+open|open\s+already)\b"#, options: .regularExpression) != nil
    }
    static func requestsParallel(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(parallel|simultaneously|concurrently|separate tasks)\b|\b([2-9]|[1-9][0-9]|two|three|four|five)\s+(browser\s+)?tabs?\b"#, options: .regularExpression) != nil
    }
}

/// "Work in the tab I have open": requests that point at a tab the user already has are routed to adopting that
/// tab (the extension's adoptTab) instead of re-opening its URL in a new task tab. Pure, so it is unit tested.
enum TabAdoptionRouting {
    struct Candidate: Equatable {
        let id: Int
        let title: String
        let url: String
        let active: Bool
        let lastFocusedWindow: Bool
    }
    enum Decision: Equatable {
        case adopt(Int)
        /// Several tabs fit and none is the active tab of the last-focused window: ask once which one.
        case ask([Int])
        /// Nothing fits: open a task tab as usual.
        case none
    }

    private static let phrases = [
        #"\b(this|current|the current|my current)\s+(browser\s+)?(tab|page|web\s*page|site)\b"#,
        #"\bmy\s+(already\s+)?(open|opened|existing)\s+([\w.-]+\s+){0,2}(tab|page|window)\b"#,
        #"\b(tab|page)\s+(that\s+)?i\s*(have|'ve|’ve|got)?\s*(got\s+)?(open|opened|up)\b"#,
        #"\b(tab|page)\s+i('m|’m|\s+am)\s+(on|in|viewing|looking at)\b"#,
        #"\balready[\s-]+open(ed)?\s+(in\s+(my\s+)?(browser|chrome)\s+)?(?!tabs\b)(?![\w.-]+\s+tabs\b)[\w.-]+"#,
        #"\b(the|my)\s+[\w.-]+\s+tab\s+(that\s+)?(is\s+|i\s+have\s+|i've\s+)?(already\s+)?open\b"#,
    ]

    /// The request refers to one tab the user already has open, rather than a site to open.
    static func requestsAdoption(_ text: String) -> Bool {
        phrases.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private static let filler: Set<String> = ["this", "that", "the", "my", "a", "an", "current", "open", "opened", "existing", "already",
        "tab", "tabs", "page", "pages", "window", "browser", "chrome", "in", "on", "i", "have", "is", "it", "site", "web", "webpage", "up", "got"]

    /// The site named with the tab ("my open github tab", "already open gmail", a URL), lowercased; nil = "this tab".
    static func siteHint(_ text: String) -> String? {
        if let range = text.range(of: #"https?://[^\s"'<>]+"#, options: .regularExpression),
           let host = URL(string: String(text[range]))?.host?.lowercased() {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        let patterns = [
            #"(?i)\balready[\s-]+open(?:ed)?\s+(?:in\s+(?:my\s+)?(?:browser|chrome)\s+)?([\w.-]+)"#,
            #"(?i)\bmy\s+(?:already\s+)?(?:open|opened|existing)\s+([\w.-]+)\s+(?:tab|page|window)\b"#,
            #"(?i)\b(?:the|my)\s+([\w.-]+)\s+tab\b"#,
            #"(?i)\b(?:tab|page)\s+(?:for|with|of)\s+([\w.-]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let word = text[range].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            if !word.isEmpty, !filler.contains(word) { return word }
        }
        return nil
    }

    private static func host(_ url: String) -> String {
        let host = URL(string: url)?.host?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func matches(_ candidate: Candidate, hint: String) -> Bool {
        let key = hint.lowercased().replacingOccurrences(of: " ", with: "")
        let site = host(candidate.url)
        guard !site.isEmpty else { return false }
        if site == key || site.hasSuffix("." + key) || site.contains(key) { return true }
        return candidate.title.lowercased().contains(hint.lowercased())
    }

    /// Which tab to adopt. "this tab" means the active tab of the last-focused window; a named site picks the tab
    /// whose address or title names it, preferring that active tab when several do; otherwise the user is asked once.
    static func choose(_ text: String, candidates: [Candidate]) -> Decision {
        let pages = candidates.filter { $0.url.lowercased().hasPrefix("http://") || $0.url.lowercased().hasPrefix("https://") || $0.url.lowercased().hasPrefix("file://") }
        guard let hint = siteHint(text) else {
            return pages.first(where: { $0.active && $0.lastFocusedWindow }).map { .adopt($0.id) } ?? .none
        }
        let fits = pages.filter { matches($0, hint: hint) }
        if fits.count == 1 { return .adopt(fits[0].id) }
        if fits.isEmpty { return .none }
        if let front = fits.first(where: { $0.active && $0.lastFocusedWindow }) { return .adopt(front.id) }
        return .ask(fits.map(\.id))
    }

    /// The consent question's options; the answer decides whether to adopt, remember, or open a new tab instead.
    static func consentOptions(site: String) -> [String] { ["Yes", "Yes, always on \(site)", "Open a new tab instead"] }
    enum Consent: Equatable { case adopt, adoptAlways, newTab }
    /// Anything but a yes (including a timeout's default text) opens a new tab instead: the safe choice.
    static func consent(_ reply: String?) -> Consent {
        guard let reply = reply?.trimmingCharacters(in: .whitespacesAndNewlines), reply.lowercased().hasPrefix("yes") else { return .newTab }
        return reply.range(of: #"(?i)^yes,?\s+always\b"#, options: .regularExpression) != nil ? .adoptAlways : .adopt
    }
    /// How the run reaches the tab: the extension adopts it; without one the browser is driven as a native window.
    enum Lane: Equatable { case extensionAdopt, nativeWindow, unavailable }
    static func lane(extensionConnected: Bool, nativeLaneEnabled: Bool) -> Lane {
        extensionConnected ? .extensionAdopt : nativeLaneEnabled ? .nativeWindow : .unavailable
    }
}

/// Background jobs consume their own bounded slots; one foreground controller is independent.
/// Coordinators waiting for their children consume no browser execution slot.
enum TaskCapacity {
    static func canStart(background: Bool, foregroundRunning: Bool, backgroundRunning: Int, limit: Int) -> Bool {
        background ? backgroundRunning < max(1, limit) : !foregroundRunning
    }
}

enum CursorVisibility {
    static func suppressPrimary(browserCursor: Bool, backgroundIndicators: Int, foregroundRunning: Bool, inputPanelVisible: Bool = false) -> Bool {
        inputPanelVisible || browserCursor || (backgroundIndicators > 0 && !foregroundRunning)
    }
}

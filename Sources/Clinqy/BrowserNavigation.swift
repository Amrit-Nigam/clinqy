import Foundation

/// Normalize only equivalent address spellings. Paths and query values remain case-sensitive.
enum BrowserNavigation {
    static func key(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URLComponents(string: text.contains("://") ? text : "https://" + text) else { return text }
        url.scheme = url.scheme?.lowercased()
        url.host = url.host?.lowercased()
        if url.host?.hasPrefix("www.") == true { url.host = String(url.host!.dropFirst(4)) }
        if url.path == "/" { url.path = "" }
        if (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80) { url.port = nil }
        return url.string ?? text
    }

    /// DOM interactive is sufficient to inspect a page even while subframes/resources keep tab status loading.
    static func isReady(info: [String: Any], requested: String, previous: String?) -> Bool {
        let url = info["url"] as? String ?? ""
        let ready = info["ready"] as? String ?? info["status"] as? String ?? "loading"
        let arrived = key(url) == key(requested)
            || (!url.isEmpty && url != previous && url != "about:blank" && (url.hasPrefix("http://") || url.hasPrefix("https://")))
        return arrived && (ready == "complete" || ready == "interactive")
    }

    static func normalizedAction(_ action: [String: Any]) -> [String: Any] {
        guard (action["do"] as? String)?.lowercased() == "open_url", let raw = action["url"] as? String else { return action }
        var normalized = action
        normalized["do"] = "open_url"
        normalized["url"] = key(raw)
        return normalized
    }
}

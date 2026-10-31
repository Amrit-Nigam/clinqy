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

    static func normalizedAction(_ action: [String: Any]) -> [String: Any] {
        guard (action["do"] as? String)?.lowercased() == "open_url", let raw = action["url"] as? String else { return action }
        var normalized = action
        normalized["do"] = "open_url"
        normalized["url"] = key(raw)
        return normalized
    }
}

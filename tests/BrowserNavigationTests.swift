import Foundation

@main struct BrowserNavigationTests {
    static func main() {
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError(label) }
        }
        let expected = BrowserNavigation.key("https://youtube.com")
        for url in ["youtube.com", "https://www.youtube.com/", " HTTPS://YouTube.com:443/ "] {
            check(BrowserNavigation.key(url) == expected, "Equivalent root address: \(url)")
        }
        check(BrowserNavigation.key("https://youtube.com/results?search_query=pokemon") != expected, "Search navigation differs from home")
        check(BrowserNavigation.key("https://example.com/Path?q=A") != BrowserNavigation.key("https://example.com/path?q=a"), "Path and query case are significant")
        check(BrowserNavigation.key("http://example.com") != BrowserNavigation.key("https://example.com"), "Protocol changes are preserved")
        let early = BrowserNavigation.normalizedAction(["do":"open_url", "url":"youtube.com"])
        let final = BrowserNavigation.normalizedAction(["do":"open_url", "url":"https://www.youtube.com/"])
        check(NSDictionary(dictionary: early).isEqual(to: final), "Streamed and final opens match")
        let click: [String: Any] = ["do":"click", "id":"w2"]
        check(NSDictionary(dictionary: BrowserNavigation.normalizedAction(click)).isEqual(to: click), "Other actions remain exact")
        print("PASS: 8 browser navigation identity checks")
    }
}

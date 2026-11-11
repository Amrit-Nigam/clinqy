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
        check(BrowserNavigation.isReady(info: ["url":"https://example.com/form", "status":"loading", "ready":"interactive"], requested: "https://example.com/form", previous: "about:blank"), "interactive DOM usable while subresources load")
        check(!BrowserNavigation.isReady(info: ["url":"https://example.com/form", "status":"complete", "ready":"loading"], requested: "https://example.com/form", previous: nil), "DOM loading overrides stale tab complete")
        check(!BrowserNavigation.isReady(info: ["url":"about:blank", "status":"complete"], requested: "https://example.com/form", previous: nil), "blank page not destination")
        check(!BrowserNavigation.isReady(info: ["url":"https://example.com/old", "ready":"complete"], requested: "https://example.com/form", previous: "https://example.com/old"), "old document not arrival")
        check(BrowserNavigation.isReady(info: ["url":"https://example.com/form", "status":"complete"], requested: "https://example.com/form", previous: nil), "older extension readiness supported")
        check(BrowserNavigation.isReady(info: ["url":"https://example.com/redirect", "ready":"interactive"], requested: "https://example.com/form", previous: "about:blank"), "redirected interactive destination accepted")
        print("PASS: 14 browser navigation identity and readiness checks")
    }
}

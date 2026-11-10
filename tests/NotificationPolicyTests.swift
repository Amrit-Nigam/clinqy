import Foundation

@main struct NotificationPolicyTests {
    static func main() {
        var failed = 0
        func check(_ ok: Bool, _ name: String) { if !ok { print("FAIL \(name)"); failed += 1 } }
        check(NotificationPolicy.shouldPost(stored: nil, env: nil), "default on")
        check(NotificationPolicy.shouldPost(stored: true, env: nil), "stored on")
        check(!NotificationPolicy.shouldPost(stored: false, env: nil), "stored off")
        check(!NotificationPolicy.shouldPost(stored: true, env: "0"), "env 0 forces off")
        check(!NotificationPolicy.shouldPost(stored: nil, env: " OFF "), "env off")
        check(NotificationPolicy.shouldPost(stored: true, env: "1"), "env 1 no effect")
        check(NotificationPolicy.shouldPost(stored: true, env: ""), "empty env no effect")
        if failed > 0 { exit(1) }
        print("notification policy tests passed")
    }
}

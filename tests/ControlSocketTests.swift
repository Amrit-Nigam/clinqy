import Foundation

@main struct ControlSocketTests {
    static var checks = 0
    static func check(_ c: Bool, _ m: String) { checks += 1; if !c { print("FAIL: \(m)"); exit(1) } }

    static func main() {
        // Framing
        let data = ControlSocket.frame(["op": "observe", "n": 1])!
        check(ControlSocket.length(of: data.prefix(4)) == data.count - 4, "length prefix matches body")
        check(ControlSocket.decode(data.dropFirst(4)) as? [String: Int] != nil || ControlSocket.decode(data.dropFirst(4))?["op"] as? String == "observe", "body round-trips")
        check(ControlSocket.length(of: Data([0, 0, 0, 0])) == nil, "empty frame rejected")
        check(ControlSocket.length(of: Data([0xff, 0xff, 0xff, 0xff])) == nil, "oversized frame rejected")
        check(ControlSocket.length(of: Data([0, 1])) == nil, "short header rejected")
        check(ControlSocket.decode(Data("[1,2]".utf8)) == nil, "non-object rejected")

        // Loopback server/client
        let dir = "/tmp/cs-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/control.sock"
        let cancelled = Cancelled()
        check(ControlSocket.serve(path: path, handler: { box in
            let op = box.value["op"] as? String ?? "?"
            if op == "slow" { try? await Task.sleep(for: .milliseconds(300)) }
            return UncheckedBox(["content": [["type": "text", "text": "echo \(op)"]], "isError": false])
        }, cancel: { cancelled.value = $0 }), "server starts")
        var st = stat()
        check(stat(path, &st) == 0 && (st.st_mode & 0o777) == 0o600, "socket mode 0600")
        let deadline = Date().addingTimeInterval(30).timeIntervalSince1970
        if case .response(let r) = ControlSocket.request(["op": "observe", "deadline": deadline], timeout: 5, path: path) {
            check(((r["content"] as? [[String: Any]])?.first?["text"] as? String) == "echo observe", "response echoed")
        } else { check(false, "expected response") }
        if case .response(let r) = ControlSocket.request(["op": "slow", "deadline": deadline], timeout: 5, path: path) {
            check(r["isError"] as? Bool == false, "slow response delivered")
        } else { check(false, "expected slow response") }
        // Expired deadlines are not executed.
        if case .noAnswer = ControlSocket.request(["op": "observe", "deadline": 1.0], timeout: 5, path: path) {} else { check(false, "expired deadline must not run") }
        // Cancel frames reach the cancel hook.
        _ = ControlSocket.request(["cancel": "s1"], timeout: 5, path: path)
        check(cancelled.value == "s1", "cancel delivered")
        // Client timeout and cancellation do not hang.
        let t0 = Date()
        if case .noAnswer = ControlSocket.request(["op": "slow", "deadline": deadline], timeout: 0.1, path: path) {} else { check(false, "short timeout") }
        check(Date().timeIntervalSince(t0) < 2, "timeout returns promptly")
        ControlSocket.stop(path: path)
        if case .unavailable = ControlSocket.request(["op": "observe"], timeout: 1, path: path) {} else { check(false, "stopped server -> unavailable") }
        // Restart: the old accept thread must not serve on a reused descriptor; only the new handler answers.
        for round in 0..<3 {
            check(ControlSocket.serve(path: path, handler: { box in
                UncheckedBox(["content": [["type": "text", "text": "round \(round) \(box.value["op"] as? String ?? "?")"]], "isError": false])
            }, cancel: { _ in }), "server restarts (\(round))")
            for _ in 0..<4 {
                if case .response(let r) = ControlSocket.request(["op": "observe", "deadline": deadline], timeout: 5, path: path) {
                    check(((r["content"] as? [[String: Any]])?.first?["text"] as? String) == "round \(round) observe", "only the current server answers (\(round))")
                } else { check(false, "restarted server responds (\(round))") }
            }
            ControlSocket.stop(path: path)
            if case .unavailable = ControlSocket.request(["op": "observe"], timeout: 1, path: path) {} else { check(false, "stopped again -> unavailable") }
        }
        print("PASS: \(checks) control socket checks")
    }
}

final class Cancelled: @unchecked Sendable {
    private let l = NSLock(); private var v: String?
    var value: String? { get { l.withLock { v } } set { l.withLock { v = newValue } } }
}

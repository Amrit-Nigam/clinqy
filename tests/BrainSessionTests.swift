import Foundation

@main struct BrainSessionTests {
    static func main() async throws {
        setenv("AGY_PATH", URL(fileURLWithPath: "tests/fake-agy.py").standardizedFileURL.path, 1)
        let image = Data([1, 2, 3]).base64EncodedString()
        var checks = 0
        for mode in ["skip", "error", "stale", "drop"] {
            let session = try AgySession(system: "Test agent", model: "default")
            if mode == "stale" { _ = try await session.send("CASE:ok", image: image) }
            do {
                _ = try await session.send("CASE:" + mode, image: image)
                preconditionFailure("Accepted unobserved final response: " + mode)
            } catch {
                if mode != "drop" {
                    guard case AgySession.BrainError.observation = error else { preconditionFailure("untyped observation error") }
                }
                checks += 1
            }
            session.close()
        }
        let session = try AgySession(system: "Test agent", model: "default")
        let observed = try await session.send("CASE:ok", image: image)
        precondition(observed.contains("click"))
        checks += 1
        let readImage = try await session.send("CASE:read", image: image)
        precondition(readImage.contains("click"))
        checks += 1
        let textOnly = try await session.send("CASE:ok")
        precondition(textOnly.contains("click"))
        checks += 1
        do { _ = try await session.send("CASE:ok", image: "invalid-base64"); preconditionFailure("invalid image accepted") }
        catch { checks += 1 }
        session.close()
        let waiting = try AgySession(system: "Test agent", model: "default")
        let pending = Task { try await waiting.send("CASE:wait") }
        try await Task.sleep(for: .milliseconds(100))
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("cancellation did not interrupt pending turn") }
        catch { checks += 1 }
        let slow = try AgySession(system: "Test agent", model: "default", timeout: 0.1)
        let slowStart = Date()
        do { _ = try await slow.send("CASE:wait"); preconditionFailure("deadline ignored") }
        catch {
            guard case AgySession.BrainError.timeout = error else { preconditionFailure("untyped timeout") }
            precondition(Date().timeIntervalSince(slowStart) < 2)
            checks += 1
        }
        do { _ = try await slow.send("CASE:ok"); preconditionFailure("timed-out session reused") }
        catch { checks += 1 }
        slow.close()
        for cancel in [false, true] {
            let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("brain-test-pid-" + UUID().uuidString)
            setenv("BRAIN_TEST_PID", pidFile.path, 1)
            let blocked = try AgySession(system: "Test agent", model: "stop-reading", timeout: cancel ? 10 : 0.2)
            let huge = String(repeating: "x", count: 2 * 1024 * 1024)
            let blockedTask = Task { try await blocked.send(huge) }
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: pidFile.path) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
            let start = Date()
            if cancel { blockedTask.cancel() }
            do { _ = try await blockedTask.value; preconditionFailure("blocked writer completed") }
            catch {
                if !cancel { guard case AgySession.BrainError.timeout = error else { preconditionFailure("blocked write lacked timeout") } }
                precondition(Date().timeIntervalSince(start) < 2)
                checks += 1
            }
            try await Task.sleep(for: .milliseconds(1300))
            precondition(kill(pid, 0) != 0, "uncooperative model child survived bounded cleanup")
            checks += 1
            blocked.close()
            try? FileManager.default.removeItem(at: pidFile)
        }
        print("Brain stream protocol: \(checks) checks passed")
    }
}

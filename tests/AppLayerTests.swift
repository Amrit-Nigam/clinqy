import Foundation

/// App-level checks that run the real `AgySession` (ACP wrapper) and `FastLane` routing code from the app module.
/// The fake ACP agent (`tests/fake-acp-server.py`) stands in for OpenCode/Cursor; no provider account is contacted.
@main struct AppLayerTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            checks += 1
            print("ok - \(label)")
        }
        guard let fake = ProcessInfo.processInfo.environment["CLINQY_FAKE_ACP"] else {
            fatalError("CLINQY_FAKE_ACP must point at fake-acp-server.py")
        }

        try await recoverableTimeoutKeepsWrapperAlive(fake: fake, check: check)
        try await closedSessionIsDead(fake: fake, check: check)
        await fastLaneRouting(check: check)

        print("PASS \(checks) app-layer checks")
    }

    /// A prompt that times out is reported as a failure of that call only: the wrapper must still report the
    /// session as alive, and the next turn must be served by the same session.
    static func recoverableTimeoutKeepsWrapperAlive(fake: String, check: (Bool, String) -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-app-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapper = root.appendingPathComponent("cursor-agent-fake")
        let log = root.appendingPathComponent("stall.jsonl")
        let body = "#!/bin/sh\nexec /usr/bin/python3 \"\(fake)\" \"cursor-cli\" \"\(log.path)\" stall\n"
        try body.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        // The app resolves the Cursor CLI from CURSOR_AGENT_PATH (Config reads the process environment first).
        setenv("CURSOR_AGENT_PATH", wrapper.path, 1)

        let session = try AgySession(system: "Do not use tools. Return plain text.", model: "vendor/model-test",
                                     provider: .cursorCLI, promptTimeout: 1)
        check(session.isAlive, "A fresh ACP wrapper reports alive")

        var timedOut = false
        do {
            _ = try await session.send("First")
        } catch {
            timedOut = error.localizedDescription.contains("Timed out")
        }
        check(timedOut, "The stalled turn fails with a timeout")
        check(session.isAlive, "A recoverable timeout leaves the wrapper reported alive")

        let answer = try await session.send("Second")
        check(answer == "Hello from ACP", "The next turn is served by the same session after the timeout")
        check(session.isAlive, "The wrapper stays alive after the recovered turn")
        session.close()
    }

    /// A session whose process has exited, or that was explicitly closed, must be reported dead so callers replace it.
    static func closedSessionIsDead(fake: String, check: (Bool, String) -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-app-dead-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Process exits as soon as it starts: the ACP session closes on its own.
        let exiting = root.appendingPathComponent("cursor-agent-exits")
        try "#!/bin/sh\nexit 0\n".write(to: exiting, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exiting.path)
        setenv("CURSOR_AGENT_PATH", exiting.path, 1)
        let exited = try AgySession(system: "Return plain text.", model: "vendor/model-test", provider: .cursorCLI, promptTimeout: 1)
        var failed = false
        do { _ = try await exited.send("Hello") } catch { failed = true }
        check(failed, "A session whose process exits fails the turn")
        check(await waitUntilDead(exited), "A session whose process exited is reported dead")

        // The process exits while the session is idle, after a good turn: no later send reports it, so the
        // session must still be reported dead on its own.
        let idleExit = root.appendingPathComponent("cursor-agent-idle-exit")
        try "#!/bin/sh\nexec /usr/bin/python3 \"\(fake)\" \"cursor-cli\" \"\(root.appendingPathComponent("idle.jsonl").path)\" exitidle\n"
            .write(to: idleExit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: idleExit.path)
        setenv("CURSOR_AGENT_PATH", idleExit.path, 1)
        let idle = try AgySession(system: "Return plain text.", model: "vendor/model-test", provider: .cursorCLI, promptTimeout: 1)
        check(try await idle.send("Hello") == "Hello from ACP", "A turn answered before the agent exits while idle")
        check(await waitUntilDead(idle), "A session whose agent exits while idle is reported dead without another send")

        // Explicit close of a healthy session.
        let healthy = root.appendingPathComponent("cursor-agent-healthy")
        let log = root.appendingPathComponent("healthy.jsonl")
        try "#!/bin/sh\nexec /usr/bin/python3 \"\(fake)\" \"cursor-cli\" \"\(log.path)\"\n"
            .write(to: healthy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: healthy.path)
        setenv("CURSOR_AGENT_PATH", healthy.path, 1)
        let closing = try AgySession(system: "Return plain text.", model: "vendor/model-test", provider: .cursorCLI, promptTimeout: 1)
        check(try await closing.send("Hello") == "Hello from ACP", "A healthy session answers before it is closed")
        closing.close()
        check(await waitUntilDead(closing), "An explicitly closed session is reported dead")
    }

    /// `AgySession.close()` and process exit both reach the ACP session asynchronously, so poll briefly.
    static func waitUntilDead(_ session: AgySession) async -> Bool {
        for _ in 0..<30 {
            if !session.isAlive { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !session.isAlive
    }

    /// FastLane's helper is off only when it would be the same provider on the same model.
    @MainActor static func fastLaneRouting(check: (Bool, String) -> Void) {
        // Empty values override the user's ~/.config/clinqy/env so the cases don't depend on local settings.
        setenv("FAST_PROVIDER", "", 1)
        setenv("FAST_MODEL", "sonnet", 1)

        let sameProviderSameModel = FastLane(intro: "test", leadModel: "sonnet", provider: .anthropic)
        check(sameProviderSameModel.helperRoute == nil,
              "Same provider and same model alias: helper is disabled")

        setenv("FAST_PROVIDER", "anthropic", 1)
        setenv("ANTHROPIC_API_KEY", "test-anthropic-key", 1)
        let differentProviderSameAlias = FastLane(intro: "test", leadModel: "sonnet", provider: .cursorCLI)
        check(differentProviderSameAlias.helperRoute?.contains("provider=anthropic") == true,
              "Different provider with the same model alias: helper stays enabled on the other provider")

        setenv("FAST_PROVIDER", "", 1)
        setenv("FAST_MODEL", "haiku", 1)
        let sameProviderDifferentModel = FastLane(intro: "test", leadModel: "sonnet", provider: .anthropic)
        check(sameProviderDifferentModel.helperRoute != nil,
              "Same provider with a different model: helper stays enabled")
    }
}

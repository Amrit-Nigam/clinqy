import Foundation

/// Runs the Antigravity CLI headlessly and streams its events.
final class AgyRunner {
    enum Event {
        case tool(String)
        case text(String)
        case finished(success: Bool, response: String)
        case failed(String)
    }

    private var process: Process?

    var isRunning: Bool { process?.isRunning ?? false }

    func run(prompt: String, onEvent: @escaping (Event) -> Void) {
        cancel()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Config.agyPath)
        process.arguments = ["-p", prompt, "--output-format", "stream-json", "--dangerously-skip-permissions"]
        process.currentDirectoryURL = URL(fileURLWithPath: Config.workDir)

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        var buffer = Data()
        var gotResult = false
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let event = Self.parse(line) {
                    if case .finished = event { gotResult = true }
                    DispatchQueue.main.async { onEvent(event) }
                }
            }
        }
        process.terminationHandler = { proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            if !gotResult {
                let status = proc.terminationStatus
                DispatchQueue.main.async {
                    onEvent(proc.terminationReason == .uncaughtSignal
                        ? .failed("Stopped")
                        : .failed("agy exited with status \(status)"))
                }
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            onEvent(.failed("Couldn't launch agy at \(Config.agyPath): \(error.localizedDescription)"))
        }
    }

    func cancel() {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private static func parse(_ line: Data) -> Event? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = json["event"] as? String else { return nil }

        if kind == "result", let result = json["result"] as? [String: Any] {
            let success = (result["status"] as? String) == "SUCCESS"
            return .finished(success: success, response: result["response"] as? String ?? "")
        }
        guard kind == "step_update", let step = json["step_update"] as? [String: Any] else { return nil }

        if let delta = step["text_delta"] as? String {
            return .text(delta)
        }
        if (step["step_type"] as? String) == "tool", (step["state"] as? String) == "ACTIVE",
           let name = step["tool_name"] as? String {
            let params = (step["tool_info"] as? [String: Any])?["parameters"] as? [String: Any]
            let detail = (params?["CommandLine"] ?? params?["Url"] ?? params?["AbsolutePath"] ?? params?["TargetFile"]) as? String
            return .tool(detail.map { "\(name): \($0.prefix(90))" } ?? name)
        }
        return nil
    }
}

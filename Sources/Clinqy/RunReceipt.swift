import Foundation

/// Each caller waits for its own result; interleaved agent.log lines are never a task protocol.
enum RunReceipt {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clinqy/cli")
    static func url(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return directory.appendingPathComponent(id + ".run.json")
    }
    /// `counts`: per-run numbers for benchmarks (model turns, UNVERIFIED results, questions to the user).
    /// `status`: a distinct terminal status ("unconfirmed": a consequential item finished without confirmation).
    static func write(id: String, ok: Bool, answer: String, steps: [String], timings: [String: Double] = [:], counts: [String: Int] = [:],
                      status: String? = nil) {
        let metrics = timings.filter { $0.value.isFinite && $0.value >= 0 }
        var body: [String: Any] = ["ok": ok, "answer": answer, "steps": steps, "phaseMilliseconds": metrics]
        if let status { body["status"] = status }
        if !counts.isEmpty { body["counts"] = counts.filter { $0.value >= 0 } }
        guard let file = url(id), let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Task history remains authoritative if the caller's result cannot be delivered. */ }
    }
}

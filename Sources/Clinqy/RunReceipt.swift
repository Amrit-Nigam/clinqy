import Foundation

/// Each caller waits for its own result; interleaved agent.log lines are never a task protocol.
enum RunReceipt {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clinqy/cli")
    static func url(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return directory.appendingPathComponent(id + ".run.json")
    }
    static func write(id: String, ok: Bool, answer: String, steps: [String]) {
        guard let file = url(id), let data = try? JSONSerialization.data(withJSONObject: ["ok": ok, "answer": answer, "steps": steps]) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Task history remains authoritative if the caller's result cannot be delivered. */ }
    }
}

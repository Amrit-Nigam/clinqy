import Foundation

/// Reads settings from the environment, falling back to ~/.config/clinqy/env (KEY=VALUE lines).
enum Config {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/clinqy/env")

    private static let lock = NSLock()
    private static var cached: [String: String]?

    private static var fileValues: [String: String] {
        lock.withLock {
            if let cached { return cached }
            let values = parse((try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
            cached = values
            return values
        }
    }

    private static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq])
            var value = String(trimmed[trimmed.index(after: eq)...])
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            values[key] = value
        }
        return values
    }

    static func value(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key] ?? fileValues[key]
    }

    /// Re-reads the file, after onboarding (or anything else) changed it.
    static func reload() {
        lock.withLock { cached = nil }
    }

    /// Sets (or, with nil, removes) keys in the env file, keeping every other line and comment as it was.
    /// The file holds API keys, so it stays readable by the user only.
    static func write(_ updates: [String: String?]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        var pending = updates
        var lines: [String] = []
        for line in old.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eq])
                if let change = pending.removeValue(forKey: key) {
                    if let value = change { lines.append("\(key)=\(value)") }
                    continue
                }
            }
            lines.append(line)
        }
        while lines.last == "" { lines.removeLast() }
        for (key, value) in pending.sorted(by: { $0.key < $1.key }) {
            if let value { lines.append("\(key)=\(value)") }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        reload()
    }
}

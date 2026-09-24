import Foundation

/// Reads settings from the environment, falling back to ~/.config/cursorboy/env (KEY=VALUE lines).
enum Config {
    private static let fileValues: [String: String] = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cursorboy/env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
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
    }()

    static func value(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key] ?? fileValues[key]
    }

    static var typesafeKey: String? { value("TYPESAFE_API_KEY") }

    /// Path to the Antigravity CLI. GUI apps don't inherit the shell PATH, so probe common spots.
    static var agyPath: String {
        if let explicit = value("AGY_PATH") { return explicit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "agy"
    }

    /// Working directory for agent tasks.
    static var workDir: String {
        value("CURSORBOY_WORKDIR") ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
}

import Foundation

/// Reads settings from the environment, falling back to ~/.config/clinqy/env (KEY=VALUE lines).
enum Config {
    private static let fileValues: [String: String] = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/clinqy/env")
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
}

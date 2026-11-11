import Foundation
// Only configuration/UI/usage dependencies are stubbed; HTTP provider implementation is real.
enum Config {
    static func value(_ key: String) -> String? {
        if key == "OPENAI_API_KEY" { return "local-test-only" }
        if key == "PROVIDER" { return "openai" }
        if key == "OPENAI_BASE_URL" { return ProcessInfo.processInfo.environment[key] }
        return nil
    }
}
enum Agent { static func writeLog(_ text: String) {} }
enum UsageStore { static func record(provider: Provider, model: String, inputTokens: Int? = nil, outputTokens: Int? = nil) {} }
enum AgySession {
    static let agyPath: String? = nil, claudePath: String? = nil
    enum BrainError: LocalizedError {
        case failed(String), died, busy, timeout, notInstalled
        var errorDescription: String? { if case .failed(let message) = self { return message }; return "test failure" }
    }
}
typealias ClaudeSession = AgySession

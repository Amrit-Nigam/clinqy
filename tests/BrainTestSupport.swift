// UI/API collaborators are stubbed; Brain.swift and its stream parser are production code.
import Foundation
enum Provider { case agyCLI, claudeCLI, codexCLI, anthropic, openai, gemini, openrouter, ollama, compatible
    static let current = Provider.agyCLI
    func model(_ model: String) -> String { model }
}
enum Config { static func value(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] } }
enum AgentPrompt { static let system = "Test agent" }
enum Agent { @MainActor static func writeLog(_ text: String) {} }
enum VisionPolicy { enum Delivery { case fileReference, embedded } }
enum UsageStore { static func record(provider: Provider, model: String, inputTokens: Int?, outputTokens: Int?) {} }
final class APIChat {
    init(provider: Provider, system: String, model: String, effort: String?) throws { fatalError("Not an API test") }
    var isAlive: Bool { false }
    func close() {}
    func send(_ text: String, image: String?, partial: (@Sendable (String) -> Void)?) async throws -> String { fatalError() }
}

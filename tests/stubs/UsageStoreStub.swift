// Test-build stand-in for the file-backed `UsageStore` in Sources/Clinqy/Usage.swift. The real store appends to
// ~/Library/Application Support/Clinqy/usage.jsonl, and HOME can't redirect that path, so app-layer tests compile
// this no-op store instead. The usage value types are taken unchanged from Usage.swift by tests/app-layer.sh.
// Keep the signatures in step with the real store.
enum UsageStore {
    static func record(provider: Provider, model: String, inputTokens: Int? = nil, outputTokens: Int? = nil) {}

    static func summary(range: UsageRange) -> UsageSummary {
        UsageSummary(requests: 0, inputTokens: 0, outputTokens: 0, meteredRequests: 0, providers: [], days: [])
    }
}

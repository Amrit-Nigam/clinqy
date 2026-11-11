import Foundation
@main struct HTTPProviderTests {
    static func main() async throws {
        let base = CommandLine.arguments[1]
        for mode in ["normal", "shrink", "compact", "oversize", "custom", "throttle", "header", "throttle-repeat", "quota"] {
            setenv("OPENAI_BASE_URL", base + "/" + mode, 1)
            let chat = try APIChat(provider: .openai, system: mode == "custom" ? "User-supplied instructions" : AgentPrompt.system, model: "gpt-test")
            let begun = Date()
            do {
                _ = try await chat.send("Preserve this exact task", image: "dGVzdA==")
                precondition(!["oversize", "custom", "throttle-repeat", "quota"].contains(mode), "unexpected success")
                if mode == "throttle" { precondition(Date().timeIntervalSince(begun) >= 0.29) }
                if mode == "header" { precondition(Date().timeIntervalSince(begun) >= 0.49) }
                if mode == "compact" { _ = try await chat.send("Next observation", image: nil) }
            } catch {
                precondition(["oversize", "custom", "throttle-repeat", "quota"].contains(mode), error.localizedDescription)
            }
            chat.close()
        }
        setenv("OPENAI_BASE_URL", base + "/cancel-wait", 1)
        let cancelChat = try APIChat(provider: .openai, system: AgentPrompt.system, model: "gpt-test")
        let waiting = Task { try await cancelChat.send("cancel delay", image: nil) }
        try await Task.sleep(for: .milliseconds(200))
        let cancelledAt = Date()
        waiting.cancel()
        do { _ = try await waiting.value; preconditionFailure("retry delay ignored cancellation") }
        catch { precondition(Date().timeIntervalSince(cancelledAt) < 1) }
        cancelChat.close()
        let (data, _) = try await URLSession.shared.data(from: URL(string: base)!)
        let records = try JSONSerialization.jsonObject(with: data) as! [String: [[String: Any]]]
        for mode in ["throttle", "header"] {
            let rows = records[mode]!
            precondition(rows.count == 2)
            precondition(NSDictionary(dictionary: rows[0]).isEqual(to: rows[1]), "retry changed the rejected request")
        }
        precondition(records["throttle-repeat"]!.count == 3, "at most two transient retries")
        precondition(records["cancel-wait"]!.count == 1, "cancelled delay must not send another request")
        precondition(records["quota"]!.count == 1, "quota errors must not be retried")
        precondition(abs(HTTPRequestBudget.rateLimitDelay(status: 429, message: "Rate limit reached. Please try again in 1.602s.", retryAfter: nil, attempt: 0)! - 1.702) < 0.000001)
        precondition(abs(HTTPRequestBudget.rateLimitDelay(status: 429, message: "Rate limit reached. Please try again in 47.256s.", retryAfter: nil, attempt: 0)! - 47.356) < 0.000001)
        precondition(HTTPRequestBudget.rateLimitDelay(status: 429, message: "Rate limit reached. Please try again in 61s.", retryAfter: nil, attempt: 0) == nil)
        precondition(HTTPRequestBudget.rateLimitDelay(status: 429, message: "Rate limit reached", retryAfter: "61", attempt: 0) == nil)
        precondition(records["normal"]!.count == 1)
        precondition(records["normal"]![0]["max_completion_tokens"] as? Int == 2048)
        let shrink = records["shrink"]!
        precondition(shrink.count == 2 && shrink[1]["max_completion_tokens"] as? Int == 920)
        let shrinkBefore = shrink[0]["messages"] as! [[String: Any]], shrinkAfter = shrink[1]["messages"] as! [[String: Any]]
        precondition(NSArray(array: shrinkBefore).isEqual(to: shrinkAfter))
        let compact = records["compact"]!
        precondition(compact.count == 3)
        let first = compact[0]["messages"] as! [[String: Any]], second = compact[1]["messages"] as! [[String: Any]]
        precondition(first[0]["content"] as? String == AgentPrompt.system)
        precondition(second[0]["content"] as? String == AgentPrompt.compactControl)
        precondition(NSDictionary(dictionary: first[1]).isEqual(to: second[1]), "task and image must be preserved exactly")
        precondition((compact[2]["messages"] as! [[String: Any]])[0]["content"] as? String == AgentPrompt.compactControl)
        precondition(records["oversize"]!.count == 2, "only one compact retry")
        precondition(records["custom"]!.count == 1, "never rewrite unknown system instructions")
        precondition(HTTPRequestBudget.reducedOutput(status: 429, message: "Request too large on tokens per min: Limit 10000, Requested 11000", current: 2048, alreadyReduced: true) == nil)
        precondition(HTTPRequestBudget.reducedOutput(status: 429, message: "Rate limit reached", current: 2048, alreadyReduced: false) == nil)
        print("HTTP provider mock: output bounds, one-shot shrinking, compact first-turn retry, preserved evidence, bounded failures, throttle delay/header precedence, and cancellation passed")
    }
}

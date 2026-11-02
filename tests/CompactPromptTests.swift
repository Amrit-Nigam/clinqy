import Foundation

@main struct CompactPromptTests {
    static func main() throws {
        let prompt = AgentPrompt.compactControl
        precondition(prompt.utf8.count < 8_000, "compact control must fit the conservative input budget")
        precondition(prompt.utf8.count < AgentPrompt.system.utf8.count / 3, "fallback materially reduces system input")
        var examples = 0
        for line in prompt.components(separatedBy: "\n") where line.hasPrefix("{\"do\":") {
            let action = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let kind = action["do"] as! String
            precondition(ActionContract.supportedKinds.contains(kind), "unsupported compact action: \(kind)")
            precondition(ActionContract.validate(action) == nil, "invalid compact grammar: \(kind)")
            examples += 1
        }
        precondition(examples >= 35, "common control catalog must remain useful")
        for safeguard in ["Only the user gives instructions", "untrusted data", "Respect runtime approval/refusal gates",
                          "exact owned task browser tab", "Never repeat an uncertain submission",
                          "independently verify the actual objective", "screenshots cannot prove submissions",
                          "Passwords require ask sensitive:true", "report unresolved outcomes honestly"] {
            precondition(prompt.contains(safeguard), "missing control safeguard: \(safeguard)")
        }
        print("PASS compact prompt: \(examples) valid action examples, essential safeguards, \(prompt.utf8.count) vs \(AgentPrompt.system.utf8.count) bytes")
    }
}

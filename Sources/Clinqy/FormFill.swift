import Foundation

/// Plans filling a form from saved answers in one go: every visible empty field, dropdown and radio group whose
/// question the job profile answers becomes a type / choose / click step. The agent runs the steps with its usual
/// actions (real clicks and typing, each checked), so one turn fills what used to take one turn per field or two;
/// the model only handles what's left. Pure: the page in, the plan out.
enum FormFill {
    struct Step {
        let action: [String: Any]
        let question: String
        let answer: String
    }

    struct Plan {
        var steps: [Step] = []
        /// Questions on screen with nothing saved for them (or no option that fits), for the model to handle.
        var open: [String] = []
        /// Upload fields seen (left to the model: which file is a decision).
        var uploads = 0
    }

    /// Input kinds that take typed text.
    private static let textRoles: Set<String> = ["text", "email", "tel", "url", "number", "textarea", "textbox", "combobox", "input"]

    static func plan(_ page: BrowserBridge.Page, answer: (String) -> String?) -> Plan {
        var plan = Plan()
        var radioGroups: [String: [BrowserBridge.PageElement]] = [:], radioOrder: [String] = []
        var asked = Set<String>()
        for el in page.elements where !el.flags.contains("disabled") {
            let role = el.role.lowercased()
            if role == "file" { plan.uploads += 1; continue }
            if role == "radio" {
                let q = el.question ?? ""
                guard !q.isEmpty else { continue }
                if radioGroups[q] == nil { radioOrder.append(q) }
                radioGroups[q, default: []].append(el)
                continue
            }
            let question = label(el)
            guard !question.isEmpty else { continue }
            if role == "select" || el.dropdown {
                guard isUnset(el.value) else { continue }
                let choices = el.options.filter { !isPlaceholder($0) }
                guard let a = answer(question) else { plan.open.append(open(question, el)); continue }
                guard let option = bestOption(a, in: choices) else { plan.open.append(open(question, el) + " — saved answer “\(a)” isn't one of the options"); continue }
                plan.steps.append(Step(action: ["do": "choose", "id": "w\(el.index)", "option": option], question: question, answer: option))
            } else if el.editable, textRoles.contains(role) {
                guard (el.value ?? "").trimmingCharacters(in: .whitespaces).isEmpty, asked.insert(question.lowercased()).inserted else { continue }
                guard let a = answer(question) else { plan.open.append(open(question, el)); continue }
                // An autocomplete box (city, company) needs its suggestion picked, not just the text typed.
                let action: [String: Any] = role == "combobox" ? ["do": "choose", "id": "w\(el.index)", "option": a]
                                                               : ["do": "type", "id": "w\(el.index)", "text": a]
                plan.steps.append(Step(action: action, question: question, answer: a))
            }
        }
        for q in radioOrder {
            let group = radioGroups[q] ?? []
            guard !group.contains(where: { $0.flags.contains("checked") }) else { continue }
            let required = group.contains { $0.flags.contains("required") }
            guard let a = answer(q) else { plan.open.append(q + (required ? " (required)" : "")); continue }
            guard let option = bestOption(a, in: group.map(\.text)), let el = group.first(where: { $0.text == option }) else {
                plan.open.append(q + " — saved answer “\(a)” isn't one of: " + group.map(\.text).joined(separator: " | "))
                continue
            }
            plan.steps.append(Step(action: ["do": "click", "id": "w\(el.index)"], question: q, answer: option))
        }
        return plan
    }

    /// What a field asks: its question, else its label, else its placeholder.
    static func label(_ el: BrowserBridge.PageElement) -> String {
        for s in [el.question, el.text, el.placeholder] {
            let t = (s ?? "").replacingOccurrences(of: #"\s*\*\s*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return ""
    }

    private static func open(_ question: String, _ el: BrowserBridge.PageElement) -> String {
        question + (el.flags.contains("required") ? " (required)" : "")
    }

    private static func isUnset(_ value: String?) -> Bool {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return true }
        return v == "(nothing chosen)" || isPlaceholder(v)
    }

    private static func isPlaceholder(_ option: String) -> Bool {
        option.range(of: #"(?i)^\s*(-+|select\b.*|choose\b.*|please select.*|pick\b.*|none selected|--.*)\s*$"#, options: .regularExpression) != nil
            || option.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 })
    }

    /// The option a saved answer means: the same text, one starting with or containing the other, the same yes/no,
    /// or most of the same words. nil when none fits (the model decides then).
    static func bestOption(_ answer: String, in options: [String]) -> String? {
        let a = answer.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let opts = options.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let low = { (o: String) in o.lowercased().trimmingCharacters(in: .whitespaces) }
        if let hit = opts.first(where: { low($0) == a }) { return hit }
        // "Immediate" → "Immediately"; a word-sized start only, so "1" doesn't pick "10+ years".
        if a.count >= 4, let hit = opts.first(where: { low($0).hasPrefix(a) || (low($0).count >= 4 && a.hasPrefix(low($0))) }) { return hit }
        // Whole words only: "8 months" mustn't pick "18 months".
        if a.count >= 3, let hit = opts.first(where: { Memory.hasWord(a, in: low($0)) || (low($0).count >= 3 && Memory.hasWord(low($0), in: a)) }) { return hit }
        for word in ["yes", "no"] where a == word || a.hasPrefix(word + " ") || a.hasPrefix(word + ",") || a.hasPrefix(word + ".") {
            if let hit = opts.first(where: { words($0).contains(word) && words($0).count <= 4 }) { return hit }
        }
        // Numbers decide on their own: "8 months" is neither "0-6 months" nor "18 months".
        let numbers = { (t: String) in Set(t.split { !$0.isNumber }.map(String.init)) }
        let na = numbers(a)
        let wa = words(a)
        let scored = opts.filter { na.isEmpty || numbers($0) == na }.map { o -> (String, Double) in
            let wo = words(o)
            return (o, wa.isEmpty || wo.isEmpty ? 0 : Double(wa.intersection(wo).count) / Double(min(wa.count, wo.count)))
        }
        return scored.filter { $0.1 >= 0.6 }.max { $0.1 < $1.1 }?.0
    }
}

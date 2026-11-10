import Foundation

/// One typed table of the model-facing actions: which arguments each action reads, which operations it supports and
/// how it is classified for completion evidence. The standalone executor validates against it before any checkpoint
/// or input, so an ignored argument can never change what an action means (for example `op` on a `type`).
enum ActionContract {
    struct Spec {
        /// Arguments the dispatcher reads (besides `do`). nil: not yet enumerated, only the global rules apply.
        let keys: Set<String>?
        /// Supported `op` values; nil when the action has no operation argument.
        let ops: Set<String>?
        init(keys: Set<String>? = nil, ops: Set<String>? = nil) { self.keys = keys; self.ops = ops }
    }

    /// Actions whose dispatcher reads `op`. Anywhere else an `op` is an ignored argument.
    static let opKinds: Set<String> = ["window", "tab", "pdf", "media", "application", "event", "reminder", "files"]

    static let specs: [String: Spec] = [
        "click": Spec(keys: ["id", "x", "y", "text", "nth", "button", "count", "modifiers", "duration_ms", "expect"]),
        "hover": Spec(keys: ["id", "x", "y"]),
        "right_click": Spec(keys: ["id", "x", "y"]),
        "double_click": Spec(keys: ["id", "x", "y"]),
        "drag": Spec(keys: ["id", "x", "y", "to_id", "to_x", "to_y"]),
        "type": Spec(keys: ["id", "text", "submit", "mode", "expect"]),
        "set_state": Spec(keys: ["id", "state", "text", "target"]),
        "set_value": Spec(keys: ["id", "value"]),
        "secondary_action": Spec(keys: ["id", "action"]),
        // plan:true marks the one ask that shows the plan at the plan autonomy level; only its yes approves the plan.
        "ask": Spec(keys: ["question", "options", "sensitive", "plan"]),
        "key": Spec(keys: ["keys", "expect"]),
        "scroll": Spec(keys: ["id", "dir", "direction", "unit", "amount"]),
        "open_app": Spec(keys: ["name"]),
        "open_url": Spec(keys: ["url"]),
        "menu": Spec(keys: ["path"]),
        "delegate": Spec(keys: ["jobs"]),
        "collect": Spec(keys: ["ids", "wait", "timeout"]),
        "look": Spec(keys: ["query", "role"]),
        "plan": Spec(keys: ["steps", "supersede"]),
        "capabilities": Spec(keys: ["query"]),
        "paste_snaps": Spec(keys: []),
        "verify": Spec(keys: ["text", "url", "value", "id", "path", "contains", "seconds", "visual", "user_confirms", "sha256", "min_bytes", "step"]),
        "shell": Spec(keys: ["cmd"]),
        "applescript": Spec(keys: ["script"]),
        "wait": Spec(keys: ["ms", "for", "gone", "timeout", "seconds", "condition"]),
        "application": Spec(keys: ["op", "query", "company", "role", "url", "status", "resume", "notes"],
                            ops: ["find", "check", "list", "show", "record", "update"]),
        "window": Spec(keys: ["op", "x", "y", "w", "h", "width", "height", "title", "on"],
                       ops: ["move", "resize", "minimize", "restore", "fullscreen", "close", "raise"]),
        "tab": Spec(keys: ["op", "id"], ops: ["list", "switch", "close", "look", "read"]),
    ]

    /// Every action name the Mac standalone dispatcher routes. The prompt, parser and dispatcher are checked against it.
    static let supportedKinds: Set<String> = [
        "open_app", "open_url", "click", "hover", "right_click", "double_click", "drag", "type", "key", "choose", "scroll",
        "menu", "window", "tab", "point", "mark", "read", "images", "image", "ask", "show", "verify", "assert", "snap",
        "paste_snaps", "pdf", "media", "upload", "review", "application", "email", "extract", "table", "event", "reminder",
        "files", "look", "wait", "recall", "remember", "remember_answer", "autofill", "think", "schedule", "dictionary",
        "applescript", "shell", "parallel_browser", "calendar", "set_state", "delegate", "collect", "plan", "capabilities",
        "set_value", "secondary_action",
    ]

    /// Operations that only read. Only these two actions have a read-only `info` operation; `op` on anything else
    /// does not change what the action does and must never lower its classification.
    static func readsOnly(kind: String, op: String) -> Bool {
        (kind == "pdf" || kind == "media") && op.lowercased() == "info"
    }

    static func matchingKinds(_ query: String) -> [String] {
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var ranked: [(kind: String, score: Int)] = []
        for kind in supportedKinds.sorted() {
            let spec = specs[kind]
            let aliases = kind == "set_state" ? "slider range checkbox switch numeric value" : kind == "look" ? "search filter observation role screenshot" : ""
            var searchable = [kind, aliases]
            searchable.append(contentsOf: spec?.keys ?? [])
            searchable.append(contentsOf: spec?.ops ?? [])
            let words = searchable.joined(separator: " ")
            var score = 0
            for term in terms where words.contains(term) { score += 1 }
            if terms.isEmpty || score > 0 { ranked.append((kind, score)) }
        }
        ranked.sort { left, right in
            left.score == right.score ? left.kind < right.kind : left.score > right.score
        }
        return ranked.prefix(12).map(\.kind)
    }

    static func describe(matching query: String) -> String {
        matchingKinds(query).map { kind in
            guard let spec = specs[kind] else { return kind + ": use the documented example below; unknown fields are not authorized." }
            return kind + " arguments: " + (spec.keys ?? []).sorted().joined(separator: ", ")
                + (spec.ops.map { "; operations: " + $0.sorted().joined(separator: ", ") } ?? "")
        }.joined(separator: "\n")
    }

    private static func isBool(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }
    private static func isNumber(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue.isFinite
    }

    /// nil when the action is well formed; otherwise why it was refused before any input.
    static func validate(_ action: [String: Any]) -> String? {
        let kind = (action["do"] as? String ?? "").lowercased()
        if action["op"] != nil, !opKinds.contains(kind) {
            return "\(kind) takes no op argument; it was not run. Send it without op"
        }
        guard let spec = specs[kind] else { return nil }
        if let allowed = spec.keys {
            let extra = Set(action.keys).subtracting(allowed.union(["do"]))
            if !extra.isEmpty {
                return "\(kind) does not use \(extra.sorted().joined(separator: ", ")); it was not run. Allowed: "
                    + (allowed.isEmpty ? "none" : allowed.sorted().joined(separator: ", "))
            }
        }
        if let why = ActionExpectation.problem(action["expect"]) { return why }
        if let ops = spec.ops, let raw = action["op"] {
            guard let op = raw as? String, ops.contains(op.lowercased()) else {
                return "\(kind) op must be one of: " + ops.sorted().joined(separator: ", ")
            }
        }
        switch kind {
        case "scroll":
            if action["dir"] != nil, action["direction"] != nil { return "scroll takes dir or direction, not both" }
            guard action["dir"] != nil || action["direction"] != nil else { return "scroll needs dir: up, down, left or right" }
            if case .failure(let error) = ScrollPlan.parse(action) { return error.message }
        case "window":
            if action["on"] != nil, !isBool(action["on"]) { return "window on must be true or false" }
            if action["on"] != nil, (action["op"] as? String)?.lowercased() != "fullscreen" { return "window on only applies to op fullscreen" }
        case "type":
            if action["submit"] != nil, !isBool(action["submit"]) { return "type submit must be true or false" }
            if let mode = action["mode"] {
                guard let name = (mode as? String)?.lowercased(), TextEditMode(rawValue: name) != nil else { return "type mode must be replace, insert or append" }
                if name != "replace", action["submit"] as? Bool == true { return "type mode \(name) cannot submit; press return in a separate key action" }
            }
        case "look":
            for key in ["query", "role"] where action[key] != nil {
                guard let text = action[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 200 else { return "look \(key) must be a nonempty string of at most 200 characters" }
            }
        case "set_value":
            guard let id = action["id"] as? String, id.hasPrefix("e") else { return "set_value needs a native element's e-id" }
            guard (action["value"] as? String).map({ !$0.isEmpty && $0.count <= 1000 }) == true || isNumber(action["value"]) else {
                return "set_value needs value: text or a finite number"
            }
        case "secondary_action":
            guard let id = action["id"] as? String, id.hasPrefix("e") else { return "secondary_action needs a native element's e-id" }
            guard let name = action["action"] as? String, name.hasPrefix("AX"), name.count <= 64 else {
                return "secondary_action needs action: one of the element's AX action names (e.g. AXShowMenu, AXIncrement)"
            }
        case "set_state":
            guard action["id"] is String else { return "set_state needs the control's id" }
            guard isBool(action["state"]) || isNumber(action["state"]) || (action["state"] as? String).map({ !$0.isEmpty && $0.count <= 128 }) == true else { return "set_state needs state: on, off or a finite number" }
            if (action["id"] as? String)?.hasPrefix("w") == true, !isNumber(action["state"]) { return "Browser set_state requires a finite numeric HTML range value" }
        case "wait":
            for key in ["ms", "seconds", "timeout"] where action[key] != nil {
                guard isNumber(action[key]), ((action[key] as? NSNumber)?.doubleValue ?? -1) >= 0 else { return "wait \(key) must be a finite non-negative number" }
            }
            if action["seconds"] != nil, action["timeout"] != nil { return "wait takes seconds or timeout, not both" }
            if action["gone"] != nil, !isBool(action["gone"]) { return "wait gone must be true or false" }
            if let raw = action["condition"] {
                guard action["for"] == nil, action["gone"] == nil, action["ms"] == nil,
                      let condition = raw as? [String: Any], let type = condition["kind"] as? String,
                      ["ready", "url", "element"].contains(type) else { return "wait condition needs kind ready, url or element; do not combine with for/gone/ms" }
                let allowed: Set<String> = type == "ready" ? ["kind"] : type == "url" ? ["kind", "text"] : ["kind", "id", "state"]
                guard Set(condition.keys).isSubset(of: allowed) else { return "wait condition contains unsupported arguments" }
                if type == "url", (condition["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    return "wait url condition needs a nonempty URL substring in text"
                }
                if type == "element" {
                    guard let id = condition["id"] as? String, id.hasPrefix("w"), let index = Int(id.dropFirst()), index >= 0,
                          let state = condition["state"] as? String, ["visible", "enabled", "gone"].contains(state) else {
                        return "wait element condition needs a current w-id and state visible, enabled or gone"
                    }
                }
            } else {
                if action["gone"] != nil, action["for"] == nil { return "wait gone needs a for text" }
                if let text = action["for"], (text as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return "wait for must be nonempty text" }
            }
        case "click", "hover", "right_click", "double_click", "drag":
            let byID = action["id"] != nil, byText = action["text"] != nil
            let byPoint = action["x"] != nil || action["y"] != nil
            if [byID, byText, byPoint].filter({ $0 }).count > 1 {
                return "\(kind) needs exactly one target: id, text or x+y; other target fields would be ignored"
            }
            if byPoint, !(isNumber(action["x"]) && isNumber(action["y"])) { return "\(kind) needs numeric x and y" }
            if kind == "click", case .failure(let error) = ClickOptions.parse(action) { return error.message }
            if kind == "drag", action["to_id"] != nil, action["to_x"] != nil || action["to_y"] != nil {
                return "drag needs one destination: to_id or to_x+to_y"
            }
        case "plan":
            guard let steps = action["steps"] as? [String], (!steps.isEmpty || action["supersede"] != nil), steps.count <= 32,
                  steps.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 500 }) else {
                return "plan needs 1–32 short outcome strings (at most 500 bytes each)"
            }
            if let supersede = action["supersede"], !(supersede is [String]) { return "plan supersede must contain checklist ids" }
        case "capabilities":
            if let query = action["query"], !(query is String) { return "capabilities query must be text" }
        case "verify":
            if let step = action["step"], !(step is String) { return "verify step must be a checklist id" }
            return verifyPredicate(action)
        default: break
        }
        return nil
    }

    /// A verify names exactly one postcondition. Several predicates would otherwise be resolved by a hidden priority,
    /// so a true one could stand in for the others: send one verify per condition instead.
    static func verifyPredicate(_ action: [String: Any]) -> String? {
        var present: [String] = []
        if action["path"] != nil { present.append("path") }
        if action["url"] != nil { present.append("url") }
        if action["value"] != nil { present.append("value") }
        if action["text"] != nil { present.append("text") }
        if action["visual"] != nil { present.append("visual") }
        if action["user_confirms"] != nil { present.append("user_confirms") }
        if present.count > 1 {
            return "verify checks one postcondition (\(present.joined(separator: " and ")) were both given); send one verify action per condition"
        }
        if present.isEmpty { return "verify requires text, an exact url, value with id, a saved-file path, visual (after a fresh look) or user_confirms" }
        if action["value"] != nil, action["id"] == nil { return "verify value needs the field's id" }
        if action["id"] != nil, action["value"] == nil { return "verify id only applies together with value" }
        if (action["sha256"] != nil || action["min_bytes"] != nil), action["path"] == nil { return "verify sha256/min_bytes only apply with path" }
        if action["contains"] != nil, action["path"] == nil { return "verify contains only applies with path" }
        for key in present where !(action[key] is String) { return "verify \(key) must be text" }
        if action["seconds"] != nil, !isNumber(action["seconds"]) { return "verify seconds must be a number" }
        return nil
    }
}

/// Before Return is pressed, the field must hold exactly what was typed. Submitting a changed value cannot be undone.
enum SubmitReadback {
    /// `actual` nil with `unreadable` set means the field cannot be read back (a secure field): the typing itself
    /// was already refused unless the field accepted it, so the submit is not blocked for lack of a value.
    /// `tolerant`: the text went in as the field's own AX value (set_value, or type's background value-write fallback);
    /// then a read-back differing only in whitespace (a trailing newline the app appends) still counts (TextReadback).
    static func allows(expected: String, actual: String?, unreadable: Bool = false, tolerant: Bool = false) -> Bool {
        if let actual { return tolerant ? TextReadback.matches(expected: expected, actual: actual) : actual == expected }
        return unreadable
    }
}

/// Reading back a value written through Accessibility: exactly the written text, or the same text differing only in
/// whitespace (runs collapsed, ends trimmed: a trailing newline, a non-breaking space). Shared by set_value and type's
/// background value-write fallback, so both accept exactly the same read-backs. Empty text never matches non-empty.
enum TextReadback {
    static func matches(expected: String, actual: String) -> Bool {
        if actual == expected { return true }
        let want = normalized(expected)
        return !want.isEmpty && normalized(actual) == want
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

/// An action's own postcondition, checked locally right after it ran (no model turn): {"expect":{"text":"Added"}},
/// {"expect":{"url":"/cart"}}, {"expect":{"value":"Pune"}}, or {"expect":"Added"} for text.
struct ActionExpectation: Equatable {
    enum Kind: String { case text, url, value }
    let kind: Kind
    let value: String

    /// nil for a well-formed (or absent) expectation; otherwise why it is refused.
    static func problem(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let text = raw as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 300 ? "expect text must be 1–300 characters" : nil }
        guard let object = raw as? [String: Any], object.count == 1, let key = object.keys.first, Kind(rawValue: key) != nil else {
            return "expect takes exactly one of text, url or value (e.g. {\"expect\":{\"text\":\"Added to cart\"}})"
        }
        guard let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 300 else {
            return "expect \(key) must be 1–300 characters of text"
        }
        return nil
    }

    static func parse(_ raw: Any?) -> ActionExpectation? {
        guard problem(raw) == nil else { return nil }
        if let text = raw as? String { return .init(kind: .text, value: text) }
        guard let object = raw as? [String: Any], let key = object.keys.first, let kind = Kind(rawValue: key),
              let value = object[key] as? String else { return nil }
        return .init(kind: kind, value: value)
    }
}

import Foundation

/// One concrete, replayable step: what was done and how to find its target again — no model needed.
struct WorkflowStep: Codable, Equatable {
    /// open_app, open_url, click, type, key, scroll, applescript, wait, expect
    var action: String
    var name: String?
    var url: String?
    var text: String?
    var keys: String?
    var dir: String?
    var script: String?
    var ms: Int?
    var submit: Bool?
    var target: Target?

    /// How to find an element again: in a web page (role + visible text) or an app (AX role + label).
    struct Target: Codable, Equatable {
        var kind: String   // "web" | "ax"
        var role: String
        var label: String
    }

    var summary: String {
        let t = target.map { "\($0.role) “\($0.label.prefix(50))”" } ?? ""
        switch action {
        case "open_app": return "Open \(name ?? "?")"
        case "open_url": return "Go to \(url ?? "?")"
        case "click": return "Click \(t)"
        case "type": return "Type “\((text ?? "").prefix(40))”\(t.isEmpty ? "" : " into \(t)")\(submit == true ? " ⏎" : "")"
        case "key": return "Press \(keys ?? "?")"
        case "scroll": return "Scroll \(dir ?? "down")"
        case "applescript": return "Run a script"
        case "wait": return "Wait \(ms ?? 0) ms"
        case "expect": return "Expect “\((text ?? "").prefix(60))”"
        default: return action
        }
    }

    /// The step as an agent action, with {parameters} filled in; the target is resolved to an id by the caller.
    func action(params: [String: String], id: String?) -> [String: Any] {
        func fill(_ s: String?) -> String? {
            guard var s else { return nil }
            for (k, v) in params { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
            return s
        }
        var a: [String: Any] = ["do": action]
        if let v = fill(name) { a["name"] = v }
        if let v = fill(url) { a["url"] = v }
        if let v = fill(text) { a["text"] = v }
        if let v = keys { a["keys"] = v }
        if let v = dir { a["dir"] = v }
        if let v = fill(script) { a["script"] = v }
        if let v = ms { a["ms"] = v }
        if let v = submit { a["submit"] = v }
        if let id { a["id"] = id }
        return a
    }
}

/// A saved, deterministic workflow (replayed without a model; healed by the model only when a step breaks).
struct Workflow: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var summary: String
    var params: [String]
    var steps: [WorkflowStep]
    var created: Date
    /// "HH:mm" to run every day, or nil.
    var schedule: String?
    var lastScheduledRun: Date?
    var healedAt: Date?
    var runs: Int = 0
    /// Values used when a parameter isn't given (the ones from the original run).
    var defaults: [String: String]? = nil

    /// Builds a workflow from a finished run: typed text becomes a named parameter (the field's label),
    /// defaulting to what was typed, so `cursorboy workflow <name> "Your name=Priya"` works.
    static func from(_ entry: History.Entry) -> Workflow? {
        guard var steps = entry.trace, !steps.isEmpty else { return nil }
        var params: [String] = []
        var defaults: [String: String] = [:]
        for i in steps.indices where steps[i].action == "type" {
            guard let text = steps[i].text, !text.isEmpty else { continue }
            var key = (steps[i].target?.label ?? "text").trimmingCharacters(in: .whitespaces)
            if key.isEmpty { key = "text" }
            var unique = key, n = 2
            while params.contains(unique) { unique = "\(key) \(n)"; n += 1 }
            params.append(unique)
            defaults[unique] = text
            steps[i].text = "{\(unique)}"
        }
        return Workflow(name: String(entry.request.prefix(60)), summary: entry.answer, params: params, steps: steps,
                        created: Date(), defaults: defaults)
    }
}

@MainActor
final class Workflows: ObservableObject {
    static let shared = Workflows()
    @Published private(set) var all: [Workflow] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CursorBoy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workflows.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder.iso8601.decode([Workflow].self, from: data) { all = saved }
    }

    func add(_ w: Workflow) { all.insert(w, at: 0); save() }
    func remove(_ w: Workflow) { all.removeAll { $0.id == w.id }; save() }
    func update(_ w: Workflow) {
        guard let i = all.firstIndex(where: { $0.id == w.id }) else { return }
        all[i] = w
        save()
    }
    func named(_ name: String) -> Workflow? {
        all.first { $0.name.lowercased() == name.lowercased() } ?? all.first { $0.name.lowercased().contains(name.lowercased()) }
    }

    private func save() {
        if let data = try? JSONEncoder.iso8601.encode(all) { try? data.write(to: url, options: .atomic) }
    }
}

extension JSONDecoder {
    static let iso8601: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}

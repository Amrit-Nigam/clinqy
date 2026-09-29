import Foundation

/// Offline replay of recorded runs: page snapshots (exactly what the extension sent) plus the model's replies,
/// checked against the pure decision code: reply parsing, which clicks need confirmation, element-id stability
/// between snapshots, what changed, and which field has focus. No browser, no model, no screen.
///
/// Fixture (tests/replay/*.json):
///   { "name": "…", "request": "what the user asked",
///     "turns": [ { "page": {<raw extension snapshot: url, title, elements [{i, role, text, value, focused, …}]>},
///                  "reply": "<model reply text>", "ms": 1380,
///                  "expect": { "actions": ["click w20"], "confirm": ["w20"], "focused": 3 | null,
///                              "drift": ["button “Next”: w8 → w9"],
///                              "added": ["button “Dismiss”"], "removed": [], "changed": ["text “Mobile”"] } } ] }
/// "expect" keys are optional; `clinqy replay --bless <file>` writes the current results in as the expectations.
@MainActor
enum Replay {
    struct Element: Equatable {
        let i: Int, role: String, text: String, q: String, frame: String, value: String?
        let focused: Bool, covered: Bool
        /// Identity across snapshots: the same control keeps its role, name, question and frame.
        var key: String { "\(role)|\(text)|\(q)|\(frame)" }
        /// A form control's question says more than its text ("Select an option").
        var name: String { "\(role) “\(q.isEmpty ? text : q)”" }
    }

    struct Snapshot {
        let url: String, title: String, elements: [Element]
        init(_ raw: [String: Any]) {
            url = raw["url"] as? String ?? ""
            title = raw["title"] as? String ?? ""
            elements = (raw["elements"] as? [[String: Any]] ?? []).map { e in
                Element(i: (e["i"] as? NSNumber)?.intValue ?? -1, role: e["role"] as? String ?? "?", text: e["text"] as? String ?? "",
                        q: e["q"] as? String ?? "", frame: e["frame"] as? String ?? "", value: e["value"] as? String,
                        focused: e["focused"] as? Bool == true, covered: e["covered"] as? Bool == true)
            }
        }
        func element(_ id: String) -> Element? {
            guard let n = Int(id.drop { !$0.isNumber }) else { return nil }
            return elements.first { $0.i == n }
        }
    }

    /// Pairs up elements with the same identity key, in order (so two “Remove” buttons pair first-with-first).
    private static func pairs(_ a: Snapshot, _ b: Snapshot) -> (matched: [(Element, Element)], added: [Element], removed: [Element]) {
        var pool = Dictionary(grouping: b.elements, by: \.key)
        var matched: [(Element, Element)] = [], removed: [Element] = []
        for el in a.elements {
            if var same = pool[el.key], !same.isEmpty {
                matched.append((el, same.removeFirst()))
                pool[el.key] = same
            } else {
                removed.append(el)
            }
        }
        let used = Set(matched.map(\.1.i))
        return (matched, b.elements.filter { !used.contains($0.i) }, removed)
    }

    /// Controls that are still there but answer to a different w-id: every one is a click the model may aim wrong.
    static func drift(_ a: Snapshot, _ b: Snapshot) -> [String] {
        pairs(a, b).matched.filter { $0.0.i != $0.1.i }.map { "\($0.0.name): w\($0.0.i) → w\($0.1.i)" }
    }

    /// What appeared, disappeared, and changed value between two snapshots.
    static func diff(_ a: Snapshot, _ b: Snapshot) -> (added: [String], removed: [String], changed: [String]) {
        let p = pairs(a, b)
        return (p.added.map(\.name), p.removed.map(\.name), p.matched.filter { $0.0.value != $0.1.value }.map(\.1.name))
    }

    /// The w-id of the element with keyboard focus, if the page reported one.
    static func focused(_ s: Snapshot) -> Int? { s.elements.first(where: \.focused)?.i }

    /// The reply's actions as the agent reads them, e.g. "click w20", "type w3", "scroll down", "look".
    static func actions(_ reply: String) -> [[String: Any]] { (Brain.json(from: reply)?["actions"] as? [[String: Any]]) ?? [] }

    static func describe(_ action: [String: Any]) -> String {
        let verb = action["do"] as? String ?? "?"
        if let id = action["id"] as? String { return "\(verb) \(id)" }
        if let dir = action["dir"] as? String { return "\(verb) \(dir)" }
        if let keys = action["keys"] as? String { return "\(verb) \(keys)" }
        if let url = action["url"] as? String { return "\(verb) \(url)" }
        return verb
    }

    /// Clicks in this turn that the safety rules would stop to confirm, by w-id.
    static func confirmations(_ actions: [[String: Any]], on page: Snapshot, request: String) -> [String] {
        actions.compactMap { a in
            guard a["do"] as? String == "click", let id = a["id"] as? String, let el = page.element(id) else { return nil }
            return Safety.needsConfirmation(label: el.text.isEmpty ? el.q : el.text, request: request) == nil ? nil : id
        }
    }

    /// Everything the checks compute for one turn, in the fixture's "expect" shape.
    static func results(turn: [String: Any], previous: Snapshot?, request: String) -> [String: Any] {
        let page = Snapshot(turn["page"] as? [String: Any] ?? [:])
        let acts = actions(turn["reply"] as? String ?? "")
        var r: [String: Any] = ["actions": acts.map(describe), "confirm": confirmations(acts, on: page, request: request),
                                "focused": focused(page).map { $0 as Any } ?? NSNull()]
        if let previous {
            let d = diff(previous, page)
            r["drift"] = drift(previous, page)
            r["added"] = d.added
            r["removed"] = d.removed
            r["changed"] = d.changed
        }
        return r
    }

    /// Replays one fixture. Returns one line per mismatch (empty = pass). With `bless`, rewrites its expectations.
    static func run(_ url: URL, bless: Bool = false) -> (checks: Int, failures: [String]) {
        guard let data = try? Data(contentsOf: url),
              var fixture = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var turns = fixture["turns"] as? [[String: Any]] else { return (1, ["\(url.lastPathComponent): not a replay fixture"]) }
        let request = fixture["request"] as? String ?? ""
        var previous: Snapshot?
        var checks = 0, failures: [String] = []
        for (n, turn) in turns.enumerated() {
            let got = results(turn: turn, previous: previous, request: request)
            if bless {
                turns[n]["expect"] = got
            } else if let want = turn["expect"] as? [String: Any] {
                for (key, expected) in want.sorted(by: { $0.key < $1.key }) {
                    checks += 1
                    let have = got[key] ?? NSNull()
                    if !(expected as AnyObject).isEqual(have) {
                        failures.append("turn \(n) \(key): expected \(flat(expected)), got \(flat(have))")
                    }
                }
            }
            previous = Snapshot(turn["page"] as? [String: Any] ?? [:])
        }
        if bless {
            fixture["turns"] = turns
            if let out = try? JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                try? out.write(to: url)
            }
        }
        return (checks, failures)
    }

    private static func flat(_ v: Any) -> String {
        if let a = v as? [Any] { return "[" + a.map { "\($0)" }.joined(separator: ", ") + "]" }
        return v is NSNull ? "none" : "\(v)"
    }

    /// Fixture files under a file or folder path.
    nonisolated static func fixtures(at path: String) -> [URL] {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return [url] }
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    /// tests/replay in the repo: next to the working directory, or found from a .build/<config>/Clinqy binary.
    static var repoFixtures: String? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [FileManager.default.currentDirectoryPath + "/tests/replay",
                          exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path + "/tests/replay"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Records a live run as a fixture when REPLAY_RECORD=on (env or ~/.config/clinqy/env), into
    /// ~/Library/Logs/Clinqy/replays/. Off by default: snapshots hold whatever the page showed.
    final class Recorder {
        static let shared = Recorder()
        var enabled: Bool { Config.value("REPLAY_RECORD")?.lowercased() == "on" }
        private var fixture: [String: Any]?
        private var turns: [[String: Any]] = []
        private var page: [String: Any]?

        /// A run starts.
        func begin(request: String) {
            guard enabled else { return }
            fixture = ["name": String(request.prefix(80)), "request": request, "recorded": ISO8601DateFormatter().string(from: Date())]
            turns = []
            page = nil
        }
        /// The raw snapshot dictionary the extension answered with (before BrowserBridge parses it).
        func page(_ raw: [String: Any]) {
            guard fixture != nil else { return }
            var copy = raw
            copy.removeValue(forKey: "screen")   // window geometry: machine-specific, not needed for replay
            page = copy
        }
        /// The model answered; pairs the reply with the latest page seen.
        func turn(reply: String, ms: Int) {
            guard fixture != nil, let page else { return }
            turns.append(["page": page, "reply": reply, "ms": ms])
        }
        /// The run ended: writes the fixture (only if any turn had a page).
        func end(ok: Bool) {
            guard var fixture, !turns.isEmpty else { self.fixture = nil; return }
            self.fixture = nil
            fixture["ok"] = ok
            fixture["turns"] = turns
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clinqy/replays")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".json"
            if let data = try? JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                try? data.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}

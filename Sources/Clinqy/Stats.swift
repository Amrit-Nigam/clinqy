import Foundation

/// `clinqy stats`: how runs went (runs.jsonl) and where each turn's time went (agent.log).
enum Stats {
    /// One run as agent.log tells it. Times are seconds since the run started.
    struct LogRun {
        struct Turn { let n: Int; let at: Double; let modelMs: Int; var actMs = 0 }
        var request: String
        var turns: [Turn] = []
        var steps: [(at: Double, text: String)] = []
        var stepFailures: [String] = []
        /// "click: …" lines (see Clicks.line): kind, place, method, ok/nochange, tries.
        var clicks: [String] = []
        var end: Double?
        var ok: Bool?
        var answer = ""
        /// Time before the first model call (observing, workflow matching, warming up).
        var setupMs: Int { turns.first.map { max(0, Int($0.at * 1000) - $0.modelMs) } ?? 0 }
    }

    private static let stamp = try! NSRegularExpression(pattern: #"^\[ *([0-9.]+)s\] (.*)$"#)
    private static let turnLine = try! NSRegularExpression(pattern: #"^turn (\d+) · (\d+) ms"#)

    /// Splits agent.log into runs ("=== request" starts one) and fills in each turn's action time: from its reply
    /// to the next model call (next turn's time minus its model ms), or to the end of the run for the last turn.
    static func parse(_ log: String) -> [LogRun] {
        var runs: [LogRun] = []
        for raw in log.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("=== ") {
                runs.append(LogRun(request: String(line.dropFirst(4))))
                continue
            }
            guard !runs.isEmpty, let m = stamp.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let at = Double(line[Range(m.range(at: 1), in: line)!]) else { continue }
            let text = String(line[Range(m.range(at: 2), in: line)!])
            var run = runs.removeLast()
            if let t = turnLine.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let n = Int(text[Range(t.range(at: 1), in: text)!]), let ms = Int(text[Range(t.range(at: 2), in: text)!]) {
                run.turns.append(.init(n: n, at: at, modelMs: ms))
            } else if text.hasPrefix("✓ ") || text.hasPrefix("✗ ") {
                run.ok = text.hasPrefix("✓")
                run.answer = String(text.dropFirst(2))
                run.end = at
            } else if text.hasPrefix("  → ") {
                run.steps.append((at, String(text.dropFirst(4))))
            } else if text.hasPrefix("    ✗ ") {
                run.stepFailures.append(String(text.dropFirst(6)))
            } else if text.hasPrefix("    click: ") {
                run.clicks.append(String(text.dropFirst(11)))
            }
            runs.append(run)
        }
        for r in runs.indices {
            let turns = runs[r].turns
            for i in turns.indices {
                let next = i + 1 < turns.count ? turns[i + 1].at - Double(turns[i + 1].modelMs) / 1000 : runs[r].end ?? turns[i].at
                runs[r].turns[i].actMs = max(0, Int(((next - turns[i].at) * 1000).rounded()))
            }
        }
        return runs
    }

    /// Groups similar messages: quoted text, numbers and ids don't make a different reason.
    static func reason(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"^FAILED: "#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"“[^”]*(”|$)|"[^"]*("|$)"#, with: "“…”", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b([we]?\d+(\.\d+)?|[0-9a-f]{16,})\b"#, with: "#", options: .regularExpression)
        return String(s.prefix(90))
    }

    private static func top(_ items: [String], _ n: Int) -> [(String, Int)] {
        let counts: [String: Int] = Dictionary(items.map { (reason($0), 1) }, uniquingKeysWith: +)
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(n).map { ($0.key, $0.value) }
    }

    private static func avg(_ xs: [Int]) -> Int { xs.isEmpty ? 0 : xs.reduce(0, +) / xs.count }
    private static func pct(_ xs: [Int], _ p: Double) -> Int {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }

    /// The report `clinqy stats [days] [--last]` prints.
    static func report(days: Double, last: Bool = false) -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clinqy")
        let logText = ["agent.log.1", "agent.log"].compactMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        let logRuns = parse(logText)
        if last {
            guard let run = logRuns.last(where: { $0.end != nil }) else { return "No finished runs in agent.log." }
            return lastRun(run)
        }
        var out: [String] = []
        // runs.jsonl: every real run (test runs aren't recorded) with its date.
        let iso = ISO8601DateFormatter()
        let cut = Date().addingTimeInterval(-days * 86_400)
        let rows = ((try? String(contentsOf: dir.appendingPathComponent("runs.jsonl"), encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { ($0["date"] as? String).flatMap(iso.date(from:)).map { $0 >= cut } ?? false }
        let d = days.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(days)) : String(days)
        if rows.isEmpty {
            out.append("No runs recorded in the last \(d) days.")
        } else {
            let num = { (r: [String: Any], k: String) in (r[k] as? NSNumber)?.doubleValue ?? 0 }
            let done = rows.filter { $0["stopped"] as? Bool != true }
            let ok = done.filter { $0["ok"] as? Bool == true }.count
            let mean = { (k: String) in rows.map { num($0, k) }.reduce(0, +) / Double(rows.count) }
            out.append("Last \(d) days: \(rows.count) runs · \(ok)/\(done.count) succeeded (\(done.isEmpty ? 0 : 100 * ok / done.count)%) · \(rows.count - done.count) stopped by you")
            out.append(String(format: "Per run: %.0f s · %.1f turns (%.1f by the fast helper) · %.1f screenshots · %.1f failed steps",
                              mean("seconds"), mean("turns"), mean("fast_turns"), mean("screenshots"), mean("failed_steps")))
            // Success rate per app: which apps Clinqy struggles in.
            let byApp = Dictionary(grouping: done) { ($0["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(no app)" }
            if byApp.count > 1 {
                out.append("By app: " + byApp.sorted { $0.value.count > $1.value.count }.prefix(6).map { app, rs in
                    "\(app) \(rs.filter { $0["ok"] as? Bool == true }.count)/\(rs.count)"
                }.joined(separator: " · "))
            }
            out.append("Slowest:")
            for r in rows.sorted(by: { num($0, "seconds") > num($1, "seconds") }).prefix(5) {
                out.append(String(format: "  %6.0f s  %3d turns  %@  %@", num(r, "seconds"), Int(num(r, "turns")),
                                  r["ok"] as? Bool == true ? "✓" : "✗", String(((r["request"] as? String) ?? "").prefix(70))))
            }
        }
        // The same runs in agent.log, matched newest-first by request, for per-turn timings and failure reasons.
        var pool = logRuns.filter { $0.end != nil }
        var matched: [LogRun] = []
        for row in rows.reversed() {
            let req = (row["request"] as? String) ?? ""
            if let i = pool.lastIndex(where: { $0.request.hasPrefix(req) || $0.request.hasPrefix("[dry run] " + req) }) {
                matched.append(pool.remove(at: i))
                pool = Array(pool[..<i])   // log order matches run order: older runs only from here
            }
        }
        let source = matched.isEmpty ? Array(logRuns.filter { $0.end != nil }.suffix(50)) : matched
        let label = matched.isEmpty ? "last \(source.count) runs in agent.log" : "\(source.count) of these runs found in agent.log"
        out += breakdown(source, label: label)
        return out.joined(separator: "\n")
    }

    /// Model vs action time per turn index, and what went wrong most.
    static func breakdown(_ runs: [LogRun], label: String) -> [String] {
        let turns = runs.flatMap(\.turns)
        guard !turns.isEmpty else { return ["", "Per turn: no turns in agent.log yet."] }
        var out = ["", "Per turn (\(label)): \(turns.count) turns"]
        let model = turns.map(\.modelMs), act = turns.map(\.actMs)
        let total = max(1, model.reduce(0, +) + act.reduce(0, +))
        out.append("  model  avg \(avg(model)) ms · p50 \(pct(model, 0.5)) · p90 \(pct(model, 0.9))  (\(100 * model.reduce(0, +) / total)% of turn time)")
        out.append("  action avg \(avg(act)) ms · p50 \(pct(act, 0.5)) · p90 \(pct(act, 0.9))  (acting + observing the result)")
        out.append("  setup before the first model call: avg \(avg(runs.filter { !$0.turns.isEmpty }.map(\.setupMs))) ms")
        out.append("  turn    runs   model ms   action ms")
        let byIndex = Dictionary(grouping: turns) { min($0.n, 10) }
        for n in byIndex.keys.sorted() {
            let ts = byIndex[n]!
            out.append("  " + (n == 10 ? "10+" : String(n)).padding(toLength: 6, withPad: " ", startingAt: 0) + String(format: " %5d  %9d  %10d", ts.count, avg(ts.map(\.modelMs)), avg(ts.map(\.actMs))))
        }
        let finished = runs.filter { $0.ok != nil && $0.answer != "Stopped" }
        let failed = finished.filter { $0.ok == false }
        out.append("")
        out.append("Success: \(finished.count - failed.count)/\(finished.count) finished runs in the log (\(finished.isEmpty ? 0 : 100 * (finished.count - failed.count) / finished.count)%)")
        if !failed.isEmpty {
            out.append("Top failure reasons:")
            for (why, n) in top(failed.map(\.answer), 5) { out.append("  \(n)×  \(why)") }
        }
        let stepFails = runs.flatMap(\.stepFailures)
        if !stepFails.isEmpty {
            out.append("Top failed steps:")
            for (why, n) in top(stepFails, 5) { out.append("  \(n)×  \(why)") }
        }
        out += clickReport(runs.flatMap(\.clicks))
        return out
    }

    /// How clicks went: how often the first way worked, which ways ended up working, and where clicks do nothing.
    static func clickReport(_ lines: [String]) -> [String] {
        struct Click { let kind, place, method: String; let ok: Bool; let tries: Int }
        let clicks = lines.compactMap { line -> Click? in
            let p = line.split(separator: " ").map(String.init)
            guard p.count >= 5, let tries = Int(p[4]) else { return nil }
            return Click(kind: p[0], place: p[1] == "-" ? "" : p[1].replacingOccurrences(of: "_", with: " "), method: p[2], ok: p[3] == "ok", tries: tries)
        }
        guard !clicks.isEmpty else { return [] }
        let pc = { (n: Int) in "\(100 * n / clicks.count)%" }
        let first = clicks.filter { $0.ok && $0.tries == 1 }.count
        let rescued = clicks.filter { $0.ok && $0.tries > 1 }.count
        let none = clicks.filter { !$0.ok }.count
        var out = ["", "Clicks: \(clicks.count) · worked first try \(pc(first)) · needed another way \(pc(rescued)) · no visible change \(pc(none))"]
        let kinds = Dictionary(grouping: clicks, by: \.kind).sorted { $0.value.count > $1.value.count }
        out.append("  by kind: " + kinds.map { k, cs in "\(k) \(cs.filter(\.ok).count)/\(cs.count)" }.joined(separator: " · "))
        let methods = Dictionary(grouping: clicks.filter(\.ok), by: \.method).sorted { $0.value.count > $1.value.count }
        if !methods.isEmpty { out.append("  what worked: " + methods.map { "\($0.key) \($0.value.count)" }.joined(separator: " · ")) }
        // Where clicks most often needed another way or did nothing (at least 3 clicks there).
        struct Place { let name: String; let total: Int; let bad: Int; var share: Double { Double(bad) / Double(total) } }
        let grouped: [String: [Click]] = Dictionary(grouping: clicks.filter { !$0.place.isEmpty }, by: \.place)
        var places: [Place] = []
        for (name, cs) in grouped {
            let bad = cs.filter { !$0.ok || $0.tries > 1 }.count
            if cs.count >= 3, bad > 0 { places.append(Place(name: name, total: cs.count, bad: bad)) }
        }
        places.sort { $0.share > $1.share }
        if !places.isEmpty {
            out.append("  hardest places: " + places.prefix(5).map { "\($0.name) \($0.bad)/\($0.total)" }.joined(separator: " · "))
        }
        return out
    }

    /// `clinqy stats --last`: the most recent run turn by turn.
    static func lastRun(_ run: LogRun) -> String {
        var out = ["\(run.ok == true ? "✓" : "✗") \(run.request.prefix(80))  (\(String(format: "%.1f", run.end ?? 0)) s, \(run.turns.count) turns, setup \(run.setupMs) ms)"]
        for (i, t) in run.turns.enumerated() {
            let until = i + 1 < run.turns.count ? run.turns[i + 1].at : .infinity
            let did = run.steps.filter { $0.at >= t.at && $0.at < until }.map(\.text)
            out.append(String(format: "  turn %2d  model %5d ms  action %5d ms  %@", t.n, t.modelMs, t.actMs,
                              did.isEmpty ? "(look)" : did.joined(separator: " · ").prefix(90).description))
        }
        out.append("  → \(run.answer.prefix(160))")
        return out.joined(separator: "\n")
    }
}

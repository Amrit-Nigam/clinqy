import Foundation

/// What changed on screen between two scans, keyed by stable ref, so after an action the model can read
/// "+ e12 Button 'Send'" instead of a whole new element list.
struct ScreenDiff {
    struct Change {
        let before: UIElementInfo
        let after: UIElementInfo
        /// "label" and/or "value".
        let fields: [String]
    }

    let added: [UIElementInfo]
    let removed: [UIElementInfo]
    let changed: [Change]

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

    /// Pure: compares two element lists. Elements without a ref fall back to role + label. Moves alone don't count
    /// (scrolling would drown out everything else).
    static func between(_ before: [UIElementInfo], _ after: [UIElementInfo]) -> ScreenDiff {
        let key = { (e: UIElementInfo) in e.ref.isEmpty ? "\(e.role)|\(e.label)" : e.ref }
        let old = Dictionary(before.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let new = Set(after.map(key))
        var changed: [Change] = []
        var added: [UIElementInfo] = []
        for e in after {
            guard let was = old[key(e)] else { added.append(e); continue }
            // An unlabeled field shows its value as its label; that's one change, not two.
            let echoesValue = e.value.map { !$0.isEmpty && e.label.hasPrefix($0.prefix(40).replacingOccurrences(of: "\n", with: " ")) } ?? false
            let labelChanged = was.label != e.label && !(was.value != e.value && (echoesValue || was.label.hasPrefix("(unlabeled")))
            let fields = (labelChanged ? ["label"] : []) + (was.value != e.value ? ["value"] : [])
            if !fields.isEmpty { changed.append(Change(before: was, after: e, fields: fields)) }
        }
        let removed = before.filter { !new.contains(key($0)) }
        return ScreenDiff(added: added, removed: removed, changed: changed)
    }

    /// Compact lines for the model: "+ e12 Button 'Send'", "- e4 Button 'Old'" (its id from the earlier list),
    /// "~ e3 TextField value 'a'→'ab'". At most `limit` lines, then a count of the rest.
    func text(limit: Int = 30) -> String {
        guard !isEmpty else { return "no visible change" }
        let q = { (s: String?) in "'\((s ?? "").prefix(50))'" }
        let name = { (e: UIElementInfo) in "\(e.id) \(e.role.dropFirst(2))" }
        var lines = changed.map { c in
            "~ \(name(c.after)) " + c.fields.map { f in
                f == "label" ? "label \(q(c.before.label))→\(q(c.after.label))" : "value \(q(c.before.value))→\(q(c.after.value))"
            }.joined(separator: ", ")
        }
        lines += added.map { "+ \(name($0)) \(q($0.label))" }
        lines += removed.map { "- \(name($0)) \(q($0.label))" }
        let shown = lines.prefix(limit).joined(separator: "\n")
        return lines.count > limit ? shown + "\n… and \(lines.count - limit) more changes" : shown
    }
}

extension ScreenDiff {
    /// The changes as a stand-in for a fresh element list, or nil when the full list must go out instead: e-ids are
    /// positional, so if any control that's still there now answers to another id (something appeared above it),
    /// a diff would send the model's clicks to the wrong place. Also nil when most of the screen changed or the
    /// changes wouldn't fit in `limit` lines. "" = nothing changed.
    static func listingUpdate(from before: [UIElementInfo], to after: [UIElementInfo], limit: Int = 40) -> String? {
        let key = { (e: UIElementInfo) in e.ref.isEmpty ? "\(e.role)|\(e.label)" : e.ref }
        let ids = Dictionary(before.map { (key($0), $0.id) }, uniquingKeysWith: { first, _ in first })
        guard !after.contains(where: { e in ids[key(e)].map { $0 != e.id } ?? false }) else { return nil }
        let d = between(before, after)
        let count = d.added.count + d.removed.count + d.changed.count
        let total = max(before.count, after.count)
        guard count <= limit, total < 6 || Double(count) <= Double(total) * 0.5 else { return nil }
        return d.isEmpty ? "" : d.text(limit: limit)
    }
}

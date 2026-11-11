import Foundation

/// Pure node-budget and compaction logic for the Accessibility scan; kept free of AX types so it is unit-testable.
enum AXTreeBudget {
    struct Node {
        var visit: Int            // order in the walk
        var parent: Int           // visit index of the parent node (-1 for roots)
        var role: String
        var label: String
        var enabled: Bool?
        var visible: Bool
        var inCollection: Bool    // row/cell/item of a table, list, outline or browser
        var inDialog: Bool
        var isInput: Bool
    }

    struct Plan {
        /// Indices into the input, in original order.
        var keep: [Int]
        /// New labels for kept text nodes that absorbed adjacent text siblings.
        var mergedLabels: [Int: String]
        var droppedAny: Bool
    }

    private static let controlRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXTab", "AXComboBox", "AXMenuBarItem", "AXDisclosureTriangle", "AXSegmentedControl", "AXSlider",
        "AXIncrementor", "AXSwitch", "AXMenuItem",
    ]
    private static let textRoles: Set<String> = ["AXStaticText"]

    /// 0 = visible control, 1 = other visible, 2 = collection item, 3 = offscreen. Dialog content outranks all.
    static func tier(_ n: Node) -> Int {
        let base = !n.visible ? 3 : n.inCollection ? 2 : controlRoles.contains(n.role) ? 0 : 1
        return n.inDialog ? base - 4 : base
    }

    static func compact(_ nodes: [Node], limit: Int) -> Plan {
        var alive = Array(repeating: true, count: nodes.count)
        var merged: [Int: String] = [:]
        // Candidate children per parent visit index.
        var kids: [Int: [Int]] = [:]
        for (i, n) in nodes.enumerated() { kids[n.parent, default: []].append(i) }

        for (i, n) in nodes.enumerated() {
            // Prune empty disabled nodes.
            if n.enabled == false, !n.isInput, n.label.isEmpty || n.label.hasPrefix("(unlabeled") { alive[i] = false; continue }
            // Flatten a group whose only candidate child says the same thing (or nothing more).
            if n.role == "AXGroup", let c = kids[n.visit], c.count == 1, nodes[c[0]].label == n.label || n.label.hasPrefix("(unlabeled") {
                alive[i] = false
            }
        }
        // Merge runs of adjacent text-only siblings (consecutive in walk order, same parent).
        var runStart: Int?
        for i in nodes.indices {
            let n = nodes[i]
            guard alive[i], textRoles.contains(n.role), !n.isInput else { runStart = nil; continue }
            if let s = runStart, nodes[s].parent == n.parent, nodes[s].inDialog == n.inDialog {
                let base = merged[s] ?? nodes[s].label
                if base.count + n.label.count < 200 {
                    merged[s] = base + " " + n.label
                    alive[i] = false
                    continue
                }
            }
            runStart = i
        }

        var keep = nodes.indices.filter { alive[$0] }
        if keep.count > limit {
            let ranked = keep.sorted { (tier(nodes[$0]), $0) < (tier(nodes[$1]), $1) }
            keep = Array(ranked.prefix(limit)).sorted()
        }
        return Plan(keep: keep, mergedLabels: merged.filter { keep.contains($0.key) }, droppedAny: keep.count != nodes.count || !merged.isEmpty)
    }
}

import Foundation

@main struct AXTreeBudgetTests {
    static var checks = 0
    static func check(_ c: Bool, _ m: String) { checks += 1; if !c { print("FAIL: \(m)"); exit(1) } }
    static func node(_ v: Int, parent: Int = 0, _ role: String = "AXButton", _ label: String = "x", enabled: Bool? = nil,
                     visible: Bool = true, coll: Bool = false, dialog: Bool = false, input: Bool = false) -> AXTreeBudget.Node {
        .init(visit: v, parent: parent, role: role, label: label, enabled: enabled, visible: visible, inCollection: coll, inDialog: dialog, isInput: input)
    }
    static func main() {
        // Big list early, button late: the button survives the budget.
        var nodes = (0..<300).map { node($0 + 1, parent: 0, "AXRow", "row \($0)", coll: true) }
        nodes.append(node(999, parent: 0, "AXButton", "Send"))
        let plan = AXTreeBudget.compact(nodes, limit: 50)
        check(plan.keep.count == 50, "limit honoured")
        check(plan.keep.contains(300), "late button kept")
        check(plan.keep == plan.keep.sorted(), "original order preserved")
        check(plan.keep.first == 0, "earliest rows fill the remainder")
        // Offscreen loses to visible; dialog beats everything.
        let mixed = [node(1, "AXButton", "off", visible: false), node(2, "AXStaticText", "text"), node(3, "AXButton", "dlg", dialog: true), node(4, "AXButton", "ok")]
        check(AXTreeBudget.compact(mixed, limit: 2).keep == [2, 3], "dialog + visible control first")
        check(AXTreeBudget.compact(mixed, limit: 3).keep == [1, 2, 3], "offscreen dropped last")
        // Merge adjacent text siblings (same parent), not across a control or other parents.
        let texts = [node(1, parent: 0, "AXStaticText", "Hello"), node(2, parent: 0, "AXStaticText", "world"),
                     node(3, parent: 0, "AXButton", "Go"), node(4, parent: 0, "AXStaticText", "tail"), node(5, parent: 9, "AXStaticText", "other")]
        let t = AXTreeBudget.compact(texts, limit: 50)
        check(t.keep == [0, 2, 3, 4], "second text merged away: \(t.keep)")
        check(t.mergedLabels[0] == "Hello world", "merged label")
        // Flatten single-child redundant group; keep multi-child group.
        let groups = [node(1, parent: 0, "AXGroup", "Toolbar"), node(2, parent: 1, "AXButton", "Toolbar"),
                      node(3, parent: 0, "AXGroup", "Panel"), node(4, parent: 3, "AXButton", "A"), node(5, parent: 3, "AXButton", "B")]
        check(AXTreeBudget.compact(groups, limit: 50).keep == [1, 2, 3, 4], "redundant group flattened")
        // Prune empty disabled nodes, keep disabled labelled controls and disabled inputs.
        let dis = [node(1, "AXButton", "", enabled: false), node(2, "AXButton", "Save", enabled: false), node(3, "AXTextField", "", enabled: false, input: true)]
        check(AXTreeBudget.compact(dis, limit: 50).keep == [1, 2], "empty disabled pruned")
        print("PASS: \(checks) AX tree budget checks")
    }
}

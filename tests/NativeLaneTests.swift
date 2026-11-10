import Foundation
import CoreGraphics

// Pure native-lane logic: routing table, kill switch, refused app classes, timing knobs and click recipe.
@main struct NativeLaneTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        typealias Facts = BackgroundPolicy.NativeFacts
        func route(_ action: [String: Any], _ build: (inout Facts) -> Void = { _ in }) -> BackgroundPolicy.NativeDecision {
            var facts = Facts(); facts.hasWindow = true; facts.skyLightAvailable = true
            build(&facts)
            return BackgroundPolicy.nativeRoute(action, facts: facts)
        }
        func refused(_ d: BackgroundPolicy.NativeDecision) -> Bool { if case .refuse = d { return true }; return false }
        let element: (inout Facts) -> Void = { $0.elementInWindow = true }

        // Kill switch: on by default, only explicit off values disable it.
        check(NativeInputTiming.nativeEnabled(nil), "native lane on when unset")
        check(NativeInputTiming.nativeEnabled("1") && NativeInputTiming.nativeEnabled(""), "native lane on for 1 and empty")
        for off in ["0", "false", "OFF", " no "] { check(!NativeInputTiming.nativeEnabled(off), "kill switch value \(off)") }

        // Routing table.
        check(route(["do": "look"]) == .allow(.readOnly), "look is read-only")
        check(refused(BackgroundPolicy.nativeRoute(["do": "look"], facts: Facts())), "no pinned window refuses everything")
        check(route(["do": "click", "id": "e3"], element) == .allow(.semantic), "plain element click is AX first")
        check(refused(route(["do": "click", "id": "e3"])), "stale or foreign element refused")
        check(refused(route(["do": "click", "id": "e3"]) { $0.elementInWindow = true; $0.elementSecure = true }), "secure element refused")
        check(route(["do": "click", "x": 10, "y": 20]) { $0.pointInWindow = true } == .allow(.skyPointer), "in-window coordinate click allowed")
        check(refused(route(["do": "click", "x": 10, "y": 20]) { $0.pointInWindow = false }), "coordinates outside the window refused")
        check(refused(route(["do": "click", "x": 10, "y": 20])), "coordinates without a capture refused")
        check(route(["do": "click", "id": "e1", "button": "right"]) { $0.elementInWindow = true; $0.pointerOptionsSupported = true } == .allow(.skyPointer), "right click option allowed")
        check(refused(route(["do": "click", "id": "e1", "modifiers": ["cmd"]]) { $0.elementInWindow = true; $0.pointerOptionsSupported = false }), "modifier click refused")
        check(route(["do": "right_click", "id": "e1"]) { $0.elementInWindow = true; $0.pointerOptionsSupported = true } == .allow(.skyPointer), "right_click gesture allowed")
        check(route(["do": "double_click", "x": 1, "y": 1]) { $0.pointInWindow = true; $0.pointerOptionsSupported = true } == .allow(.skyPointer), "double_click at point allowed")
        check(refused(route(["do": "right_click", "id": "e1"]) { $0.elementInWindow = true; $0.skyLightAvailable = false }), "pointer lane fails closed without symbols")
        check(refused(route(["do": "drag", "id": "e1"], element)) && refused(route(["do": "hover", "id": "e1"], element)), "hover and drag stay foreground")
        check(route(["do": "scroll"]) == .allow(.wheel), "scroll allowed (AX page actions, then pid wheel)")
        check(route(["do": "choose", "id": "e2", "option": "Large"], element) == .allow(.semantic), "choose through AX menu")
        check(route(["do": "set_value", "id": "e2", "value": "5"]) { $0.elementInWindow = true; $0.valueSettable = true } == .allow(.semantic), "settable value")
        check(refused(route(["do": "set_value", "id": "e2", "value": "5"], element)), "unsettable value refused")
        check(route(["do": "type", "id": "e2", "text": "hi"]) { $0.elementInWindow = true; $0.textRole = true; $0.valueSettable = true } == .allow(.semantic), "type uses AX value first")
        check(route(["do": "type", "id": "e2", "text": "hi"]) { $0.elementInWindow = true; $0.textRole = true } == .allow(.keyboard), "type falls back to keyboard session")
        check(refused(route(["do": "type", "id": "e2", "text": "hi", "submit": true]) { $0.elementInWindow = true; $0.textRole = true }), "type+submit split")
        check(route(["do": "secondary_action", "id": "e2", "action": "AXShowMenu"]) { $0.elementInWindow = true; $0.elementActions = ["AXPress", "AXShowMenu"] } == .allow(.semantic), "advertised secondary action")
        check(refused(route(["do": "secondary_action", "id": "e2", "action": "AXPress"]) { $0.elementInWindow = true; $0.elementActions = ["AXPress"] }), "press is not a secondary action")
        check(refused(route(["do": "secondary_action", "id": "e2", "action": "AXIncrement"]) { $0.elementInWindow = true; $0.elementActions = ["AXPress"] }), "unadvertised action refused")
        check(route(["do": "key", "keys": "cmd+s"]) { $0.chordValid = true } == .allow(.keyboard), "scoped key chord")
        check(refused(route(["do": "key", "keys": "cmd+?"])), "invalid chord refused")
        check(refused(route(["do": "shell"])), "unknown native action refused")

        // Refused app classes.
        check(BackgroundPolicy.nativeAppRefusal(bundleID: "com.apple.Terminal", name: "Terminal", hidden: false, isSelf: false) != nil, "terminal refused")
        check(BackgroundPolicy.nativeAppRefusal(bundleID: "com.googlecode.iterm2", name: "iTerm", hidden: false, isSelf: false) != nil, "iTerm refused")
        check(BackgroundPolicy.nativeAppRefusal(bundleID: "com.apple.SecurityAgent", name: "SecurityAgent", hidden: false, isSelf: false) != nil, "security prompt refused")
        check(BackgroundPolicy.nativeAppRefusal(bundleID: "com.apple.TextEdit", name: "TextEdit", hidden: true, isSelf: false) != nil, "hidden app refused")
        check(BackgroundPolicy.nativeAppRefusal(bundleID: "com.apple.TextEdit", name: "TextEdit", hidden: false, isSelf: true) != nil, "self refused")
        check(BackgroundPolicy.nativeAppRefusal(bundleID: "com.apple.TextEdit", name: "TextEdit", hidden: false, isSelf: false) == nil, "ordinary visible app allowed")

        // Timing knobs.
        let defaults = NativeInputTiming.parse { _ in nil }
        check(defaults == .defaults && defaults.focusSettleMicros == 10_000 && defaults.clickDelayScale == 0.2, "tuned defaults")
        let tuned = NativeInputTiming.parse(["SKY_FOCUS_SETTLE_MS": "0", "SKY_CLICK_DELAY_SCALE": "0.5", "SKY_KEY_SETTLE_MS": "25", "SKY_KEY_RELEASE_MS": "3.5"].self.get)
        check(tuned.focusSettleMicros == 0 && tuned.clickDelayScale == 0.5 && tuned.keySettleMicros == 25_000 && tuned.keyReleaseMicros == 3_500, "knobs parsed")
        let clamped = NativeInputTiming.parse(["SKY_FOCUS_SETTLE_MS": "9999", "SKY_CLICK_DELAY_SCALE": "0", "SKY_KEY_SETTLE_MS": "-4"].self.get)
        check(clamped.focusSettleMicros == 200_000 && clamped.clickDelayScale == NativeInputTiming.minimumClickScale && clamped.keySettleMicros == 0, "knobs clamped; click scale never 0")
        let junk = NativeInputTiming.parse(["SKY_FOCUS_SETTLE_MS": "fast", "SKY_CLICK_DELAY_SCALE": "nan"].self.get)
        check(junk == .defaults, "unparseable knobs keep defaults")

        // Click recipe.
        let single = defaults.clickRecipe(count: 1)!, double = defaults.clickRecipe(count: 2)!
        check(single.count == 5 && double.count == 7, "move + primer pair + 1 or 2 target pairs")
        check(single.filter { !$0.onTarget }.allSatisfy { $0.kind != .move } && single[0].kind == .move, "primer is off-window down/up after the move")
        check(double[3].clickState == 1 && double[5].clickState == 2, "double click increments click state")
        check(defaults.clickRecipe(count: 0) == nil && defaults.clickRecipe(count: 3) == nil, "only single or double")
        check(single[2].delayMicros == 20_000 && defaults.rendererSettleMicros == 20_000, "primer and renderer settle are 20 ms at scale 0.2")
        let old = NativeInputTiming(focusSettleMicros: 40_000, clickDelayScale: 1, keySettleMicros: 10_000, keyReleaseMicros: 10_000)
        check(defaults.clickSleepMicros(count: 1) < 80_000 && old.clickSleepMicros(count: 1) > 250_000, "tuned click sleeps under 80 ms (was ~297 ms)")

        // Occlusion keep-alive geometry.
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        check(NativeWindowVisibility.looksUnoccluded(bounds: window, covering: []), "uncovered window is visible")
        check(NativeWindowVisibility.looksUnoccluded(bounds: window, covering: [CGRect(x: 0, y: 0, width: 90, height: 100)]), "partly covered window is visible")
        check(!NativeWindowVisibility.looksUnoccluded(bounds: window, covering: [CGRect(x: -10, y: -10, width: 200, height: 200)]), "fully covered window is not pinned")
        check(!NativeWindowVisibility.looksUnoccluded(bounds: .zero, covering: []), "empty window is never pinned")
        print("PASS: \(checks) native lane policy checks")
    }
}

private extension Dictionary where Key == String, Value == String {
    func get(_ key: String) -> String? { self[key] }
}

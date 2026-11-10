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
        // Native type with submit:true in a pinned window: the Return goes through the isolated keyboard session.
        check(route(["do": "type", "id": "e16", "text": "hello", "submit": true]) { $0.elementInWindow = true; $0.textRole = true } == .allow(.keyboard),
              "native type+submit allowed in background with a pinned window")
        check(route(["do": "type", "id": "e16", "text": "hello", "submit": true]) { $0.elementInWindow = true; $0.textRole = true; $0.valueSettable = true } == .allow(.keyboard),
              "submit uses the keyboard lane even when the value is settable")
        check(refused(route(["do": "type", "id": "e16", "text": "hello", "submit": true]) { $0.elementInWindow = true; $0.textRole = true; $0.skyLightAvailable = false }),
              "type+submit fails closed without background keyboard")
        check(refused(route(["do": "type", "id": "e16", "text": "hello", "submit": true]) { $0.textRole = true }), "type+submit still needs the element in the pinned window")
        check(route(["do": "key", "keys": "return"]) { $0.chordValid = true } == .allow(.keyboard), "Return to the pinned window allowed")
        // Refusal wording: a native target never claims a browser page is needed.
        let browserMsg = "No owned browser page target is available. I won't use your active window."
        let native = BackgroundPolicy.attentionReason(browser: browserMsg, nativeTarget: true, nativeRefusal: "The target is disabled or secure.")
        check(!native.contains("browser") && native.contains("pinned native window") && native.contains("disabled or secure"), "native refusal names the native reason")
        check(!BackgroundPolicy.attentionReason(browser: browserMsg, nativeTarget: true, nativeRefusal: nil).lowercased().contains("browser"), "native refusal without a reason never mentions a browser")
        check(BackgroundPolicy.attentionReason(browser: browserMsg, nativeTarget: false, nativeRefusal: nil) == browserMsg, "browser targets keep the browser message")
        // Text entry: insert into empty/unreadable fields, replace only readable text, refuse hidden existing text.
        check(BackgroundPolicy.textEntryPlan(value: nil, characterCount: nil) == .insert, "unreadable composer gets an insertion")
        check(BackgroundPolicy.textEntryPlan(value: nil, characterCount: 0) == .insert, "unreadable empty field gets an insertion")
        check(BackgroundPolicy.textEntryPlan(value: "", characterCount: 0) == .insert, "empty field gets an insertion")
        check(BackgroundPolicy.textEntryPlan(value: "old", characterCount: 3) == .replace, "readable text is replaced")
        if case .refuse = BackgroundPolicy.textEntryPlan(value: nil, characterCount: 5) {} else { check(false, "hidden existing text refused") }
        checks += 1
        // Id-less type: last clicked/typed field, else focused text field, else a clear failure.
        check(BackgroundPolicy.idlessTypeTarget(remembered: true, focusedTextField: true) == .remembered, "remembered field wins")
        check(BackgroundPolicy.idlessTypeTarget(remembered: false, focusedTextField: true) == .focused, "focused text field next")
        check(BackgroundPolicy.idlessTypeTarget(remembered: false, focusedTextField: false) == .none, "no target: no blind typing")
        // AX press with no change on a list row: select/click fallback, only once and only for delivered presses.
        check(BackgroundPolicy.rowFallbackApplies(role: "AXRow", changed: false, method: "axpress", uncertain: false), "nochange row falls back")
        check(BackgroundPolicy.rowFallbackApplies(role: "AXCell", changed: false, method: "axpress", uncertain: false), "nochange cell falls back")
        check(!BackgroundPolicy.rowFallbackApplies(role: "AXRow", changed: true, method: "axpress", uncertain: false), "changed row needs nothing")
        check(!BackgroundPolicy.rowFallbackApplies(role: "AXRow", changed: false, method: "axpress", uncertain: true), "ambiguous press never gets a second input")
        check(!BackgroundPolicy.rowFallbackApplies(role: "AXButton", changed: false, method: "axpress", uncertain: false), "buttons aren't re-clicked")
        check(!BackgroundPolicy.rowFallbackApplies(role: "AXRow", changed: false, method: "real", uncertain: false), "a real click isn't repeated")
        // Foreground switch keeps the task's own app; Telegram thumbnails fall back to the pinned native window.
        check(BackgroundPolicy.foregroundTarget(contextApp: "WhatsApp", pinnedApp: "Other") == "WhatsApp", "foreground keeps the pinned app")
        check(BackgroundPolicy.foregroundTarget(contextApp: nil as String?, pinnedApp: "WhatsApp") == "WhatsApp", "foreground falls back to the run's app")
        check(BackgroundPolicy.foregroundTarget(contextApp: nil as String?, pinnedApp: nil) == nil, "no app yet: nothing guessed")
        check(BackgroundPolicy.screenshotWindow(telegram: nil, pinnedApp: "WhatsApp", pinnedWindow: 42).map { $0.app == "WhatsApp" && $0.id == 42 } == true, "thumbnail falls back to the pinned window")
        check(BackgroundPolicy.screenshotWindow(telegram: (app: "Notes", id: 7), pinnedApp: "WhatsApp", pinnedWindow: 42)?.id == 7, "remembered Telegram window wins")
        check(BackgroundPolicy.screenshotWindow(telegram: nil, pinnedApp: "WhatsApp", pinnedWindow: nil) == nil, "no pinned window: no thumbnail")
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
        // Background composer focus (WhatsApp in the hidden lane): the app-wide focused element may never update.
        typealias FV = FocusVerification
        check(FV.accepts(app: .target, window: .unreadable, focusSet: false, background: false), "the app's focus on the field: accepted")
        check(FV.accepts(app: .inside, window: .unreadable, focusSet: false, background: true), "an editable descendant of the field: accepted")
        check(FV.accepts(app: .unreadable, window: .target, focusSet: true, background: true), "background: AXFocused set + the pinned window's focused element is the field")
        check(FV.accepts(app: .other, window: .inside, focusSet: true, background: true), "background: the window reports the field's editor")
        check(!FV.accepts(app: .unreadable, window: .target, focusSet: false, background: true), "the window alone, without a successful AXFocused set: refused")
        check(!FV.accepts(app: .unreadable, window: .target, focusSet: true, background: false), "foreground keeps requiring the app's own focus")
        check(!FV.accepts(app: .otherText, window: .target, focusSet: true, background: true), "another text field holding app focus is never overruled")
        check(!FV.accepts(app: .unreadable, window: .otherText, focusSet: true, background: true), "the window's focus on another field: refused")
        check(!FV.accepts(app: .unreadable, window: .unreadable, focusSet: true, background: true), "nothing reported: refused")
        check(FV.fallback(background: true, valueSettable: true, secure: false, focusInOtherField: false) == .setValue,
              "background, unverifiable focus: set the field's own value (as set_value) and read it back")
        check(FV.fallback(background: false, valueSettable: true, secure: false, focusInOtherField: false) != .setValue, "foreground: no fallback, refuse")
        check(FV.fallback(background: true, valueSettable: true, secure: true, focusInOtherField: false) != .setValue, "secure field: never")
        check(FV.fallback(background: true, valueSettable: true, secure: false, focusInOtherField: true) != .setValue, "another field focused: nothing typed")
        check(FV.fallback(background: true, valueSettable: false, secure: false, focusInOtherField: false) != .setValue,
              "no settable value: no blind keystrokes, refuse")
        // Round 10 regression: WhatsApp's empty composer reports no AXValue before the write (so the old "readable
        // before" gate refused), yet round 9's set_value wrote and read it back. The fallback must cover that case:
        // its inputs no longer include the pre-write readability at all, only settable/secure/other-field focus.
        check(FV.fallback(background: true, valueSettable: true, secure: false, focusInOtherField: false) == .setValue,
              "round 9 case (settable composer, empty value unreadable before the write): fallback writes it")
        // P3: the pointer restore keeps fractions; a whole-pixel landing gets one exact move.
        check(PointerRestore.needsExactMove(saved: CGPoint(x: 1389.59375, y: 591.515625), now: CGPoint(x: 1389, y: 591)),
              "1389.59,591.52 restored as 1389,591: move again to the exact point")
        check(!PointerRestore.needsExactMove(saved: CGPoint(x: 1389.59375, y: 591.515625), now: CGPoint(x: 1389.59375, y: 591.515625)),
              "exact restore: nothing more")

        // A pinned window that looks stale right before input is re-resolved once.
        check(StaleWindowRecovery.retries(reason: "the target window contents changed since the image was captured; look again"), "content change: retry")
        check(StaleWindowRecovery.retries(reason: "the target window moved or resized; look again"), "moved: retry")
        check(StaleWindowRecovery.retries(reason: "the target window identity or geometry cannot be verified; look again"), "unverifiable geometry: retry")
        for hard in ["the target application restarted; look again", "the target application is hidden; restore it and observe again",
                     "the target window is minimized; restore it and observe again", "a modal sheet is blocking the target window; observe the sheet before acting",
                     "the target window was closed or replaced; look again"] {
            check(!StaleWindowRecovery.retries(reason: hard), "no retry: \(hard)")
        }
        check(StaleWindowRecovery.accepts(sameProcess: true, sameWindowID: true, freshNow: true), "same process + window, fresh: proceed")
        check(!StaleWindowRecovery.accepts(sameProcess: false, sameWindowID: true, freshNow: true)
              && !StaleWindowRecovery.accepts(sameProcess: true, sameWindowID: false, freshNow: true)
              && !StaleWindowRecovery.accepts(sameProcess: true, sameWindowID: true, freshNow: false), "anything else still refuses")
        print("PASS: \(checks) native lane policy checks")
    }
}

private extension Dictionary where Key == String, Value == String {
    func get(_ key: String) -> String? { self[key] }
}

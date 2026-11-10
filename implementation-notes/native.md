# Native Mac background lane (Phase 0.2/0.3 + Phase 4)

## Default and kill switch

The native background lane is **on by default**. `BACKGROUND_NATIVE=0` (also `false`/`off`/`no`) turns it off; private SkyLight paths then fail closed to the existing foreground handoff. Every private symbol is resolved with `dlsym`; a missing symbol disables only its own capability (input, capture, occlusion keep-alive).

## Live probe (tests/focus-intrusion-probe.sh, macOS 27.0 build 26A428)

A disposable AppKit fixture is put in front (counts resign-active, resign-key, stray mouse-downs and keys in its first-responder field); Clinqy's production `SkyLight.click` and keyboard session drive TextEdit behind it, then both quit. Not in CI (needs Accessibility and a GUI session).

| | before | after |
| --- | --- | --- |
| front lost active / key | 0 / 0 | 0 / 0 |
| pointer moved / frontmost changed | no / no | no / no |
| click delivered (caret moved) / keys arrived | yes / yes | yes / yes |
| click fixed sleeps | ~257 ms (40 ms focus settle, 117 ms recipe, 100 ms renderer settle) | ~63 ms (10 ms focus settle in and out, scale 0.2) |

Runs where physical HID input happened during the probe are reported as inconclusive (the user clicking elsewhere is counted as lost-active). Under load (load avg ~12) the same-binary A/B gave click return 645 ms (old gaps) vs 131–195 ms (tuned).

Phase 0.3 go/no-go on this Mac: `SLEventPostToPid`, `SLEventSetIntegerValueField`, `CGEventSetWindowLocation`, `SLPSPostEventRecordTo`, `GetProcessForPID`, `SLSMainConnectionID`, `SLSHWCaptureWindowList`, `SLSPackagesEnableWindowOcclusionNotifications`, `_AXUIElementGetWindow`: present (go). `_AXObserverAddNotificationAndCheckRemote`: **absent** (no-go); Electron trees are instead requested once per process with `AXManualAccessibility`. HW capture of a covered window 10–45 ms idle vs ScreenCaptureKit enumerate+capture 56–96 ms.

## What the lane does

- **Focus:** synthetic activation and key-window records go to the target PSN only; nothing is posted to the real frontmost app.
- **Timing knobs** (`NativeInputTiming`, env or `~/.config/clinqy/env`): `SKY_FOCUS_SETTLE_MS` (10), `SKY_CLICK_DELAY_SCALE` (0.2, floor 0.05 — scale 0 failed every click in the OCU sweep), `SKY_KEY_SETTLE_MS` (10), `SKY_KEY_RELEASE_MS` (10).
- **Pointer:** left/right, single/double SkyLight clicks at elements or in-window coordinates (`Hand.click(at:options:)`, `Hand.gesture` for `right_click`/`double_click`). Modifiers, hold, middle button, triple click, hover and drag stay foreground.
- **Scroll:** AX `AXScroll*ByPage` on the scroll area under the anchor for page units, otherwise wheel events posted to the pid and tagged with the window id.
- **Semantic:** `Hand.choose` (AX popup/menu, exact single match, readback), `Hand.setValue` (AXValue with readback), `Hand.performSecondaryAction` (advertised non-press AX action, once).
- **Launch:** `Launcher.launchInBackground(named:)` opens with `activates=false, hides=false`, polls for a window, never uses the virtual screen. `focusBehind` no longer unhides apps.
- **Capture:** `SLSHWCaptureWindowList` is primary for native windows, ScreenCaptureKit is the fallback with its inventory cached ~1 s. Capture-path staleness checks collapsed from five to two per screenshot; `staleness()` queries one window instead of enumerating all.
- **Occlusion keep-alive:** in background runs a captured window that is still unoccluded has its occlusion notifications disabled (keeps Chromium/Electron rendering once covered). `Hand.endRun` and an `atexit` hook restore the previous state (`SKY_OCCLUSION_KEEPALIVE=0` disables).
- **Refused:** hidden (⌘H) apps, terminals, system security/authorization agents, Clinqy itself (`BackgroundPolicy.nativeAppRefusal`).

## Tests

`tests/native-lane.sh` (CI): routing table, kill switch, refused app classes, knob parsing/clamping, click recipe and sleep budget, keep-alive geometry.

## Limits

No symbol check proves behaviour on a future macOS; re-run the probe per release. Keep-alive cannot revive a window that was already covered when first seen. Canvas/GL surfaces that ignore both AX and window-targeted events still need foreground HID.

SkyLight record/ABI references were adapted from MIT-licensed open-codex-computer-use, Cua Driver and yabai; notices in `THIRD_PARTY_NOTICES.md`.

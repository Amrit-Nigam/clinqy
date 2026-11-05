# Native Mac implementation — testing deferred

No builds, test execution, app installation, live desktop input, commits, or pushes were performed for this work. This is source implementation, not a claim of runtime compatibility or Codex parity.

## Implemented

- **21–22:** Scoped target-only SkyLight keyboard sessions, including internal key-window record pair; exact process/window validation; unique enabled menu-equivalent lookup for background Command shortcuts; no physical-pointer fallback. Private mechanisms require symbol availability. Native Agent routing is opt-in through `BACKGROUND_NATIVE=1` and `NativeBackgroundCapability`; runtime integration is owned by the runtime implementation work.
- **23:** Exact-window ScreenCaptureKit enumeration includes other Spaces. Screenshot, OCR and visual coordinate revalidation share `Screenshot.rawImage`. An independently capability-gated backing-store capture fallback is available under `BACKGROUND_NATIVE=1`, respects Screen Recording permission, validates aspect/identity, and never activates a window. This does not force a suspended renderer to produce new content.
- **24:** Focused/attached sheets retain their own CGWindowID. New blocking sheets invalidate parent actions. Explicit `followAttachedSheet` follows only the pinned owner's child; it does not adopt an unrelated same-app window. Native window enumeration includes focused and attached sheets.
- **25–26:** Existing exact geometry, process lifetime, negative-coordinate and Retina mapping are preserved. Staleness also rejects hidden/minimized targets. Scroll chunks recheck target geometry. Multi-display/scaling execution is deferred to the test phase.
- **27:** Native text replacement first uses AX value semantics and exact readback. Unsupported setters permit one process-targeted delivery, with verified full selection before replacing nonempty content. Cancellation/focus/security checks run between Unicode character chunks. UTF-16 selection insertion rejects overflow and invalid Unicode ranges; insertion/appending verifies text and caret. Unknown write replies never become permission for a second mutation.
- **28:** Native text fallback no longer retries with a clipboard paste, clears uncertain text, or uses global keyboard delivery. Existing clipboard snapshot ownership restoration remains in foreground paste/copy routes. Native background pointer delivery no longer guesses helper-process windows or silently changes delivery method.
- **29–30:** Capability-specific refusal messages explain why foreground handoff is needed. Keyboard and SkyLight click operations share input ownership. Deactivation failures retain a retryable cleanup record and block new synthetic input until cleanup succeeds; identity is checked against process restart. End-of-run cleanup retries pending restoration. No synthetic active state is left by the legacy app-selection `focus` call.
- **41–44:** AX scans have candidate/time/depth limits, defer collections until ordinary controls have been visited, prefer visible rows even in short scrolled lists, include AXContents, and expose bounded-scan diagnostics with the observation. Batch attribute reads already existed and remain in use. Empty scans can report their notice through `AXEngine.listing(..., window:)`. Existing screenshot acquisition stays explicit; this native change does not add automatic screenshot deduplication.

## Interfaces for Agent integration

- `NativeBackgroundCapability.enabled`
- `NativeBackgroundCapability.canObserve(_:window:) -> String?`
- `NativeBackgroundCapability.canPerform(_:window:elements:) -> String?`
- `Background.nativeWindowID` is task-scoped and reset at run boundaries.
- `NativeWindowObservation.capture(_:windowID:followAttachedSheet:)`
- `Hand.press(_:in:window:) -> Bool`
- `Hand.type(_:in:window:) async -> Bool` should receive the original observed window.
- `AXEngine.listing(_:budget:refs:window:)`

## Deliberate compatibility limits

Native opt-in supports bounded observation, current-element plain clicks/text, and scoped shortcuts. Native drag/right-click/count/modifier gestures, native scrolling without a verified container, unknown popup ownership, hidden/minimized apps, and arbitrary application launch remain foreground handoffs. No private symbol availability check proves behavior across macOS releases. No universal background-native claim is made. Covered-window capture does not imply arbitrary occluded Chromium renderers remain live; an occlusion-notification mutator is not silently enabled.

The SkyLight record/ABI references were adapted from MIT-licensed open-computer-use, Cua Driver and yabai. Full notices are retained in `THIRD_PARTY_NOTICES.md`.

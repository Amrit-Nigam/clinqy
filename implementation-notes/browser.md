# Browser and visible-feedback implementation

Implementation only. No test suites, syntax checks, builds, installations, extension reloads, or live browser actions were run for this work. Source inspection is not runtime validation.

## Changes

- `BrowserBridge.swift`: per-background-run ownership token, extension installation/build/capability diagnostics, mismatch refusal and bounded reload, strict browser process selection (never treat unidentified Arc as Chrome), bounded owner-identification wait, status updates, targeted scroll and condition-wait APIs. Reconnection matches the original opaque installation identity and browser owner, verifies the run-owned tab still exists, and only then performs a fresh observation. It never replays input or migrates to a different profile.
- `BrowserProfiles.swift`: inspect preference JSON and unpacked extension manifests structurally; enumerate matches; return an automatic selection only when unambiguous. Removed silent last-used-profile fallback. An opaque extension installation ID is not a Chrome account or filesystem profile identity.
- `extension/bridge.js`: per-run work-tab ownership, cooperative cancellation between asynchronous dispatch stages, cancellation of page waits, key/button release cleanup, bounded cleanup before debugger detach, popup events and ownership inheritance only from an active owned opener action, bounded completed-download bookkeeping, command elapsed time, truthful activity prepare/delivered/error phases.
- Shared manifest/script version stays `1.9.16` for existing Windows version compatibility. Mac additionally checks `2026-11-browser-reliability-1`. Optional hello fields do not require Windows source changes.
- `extension/page.js`: scoped rich-text replacement instead of document-wide select-all, disabled/read-only guards, exact filename/size file-input readback, targeted nested/horizontal scrolling, cancellable text/URL/readiness/element waits, viewport geometry guard for raw coordinate clicks, control-prioritized bounded observations, no blanket autocomplete mutation.
- `ChromeWorker.swift`: matching targeted scrolling and condition-wait routing for the isolated worker, including conversion from global element IDs to frame-local IDs.
- `extension/activity.js`: viewport-sized 1px halo with restrained glow; dark/high-contrast styles; compact status badge moves away from the target; exact cursor tip position without the old +3 offset; bounded element tracking across movement/scroll/resize; click/type/drag/upload pulses only after delivery; phase labels; no document-title mutation; nested screenshot hiding; lifecycle cleanup; reduced motion.

## Backlog mapping

| Items | Implementation status |
| --- | --- |
| 11–13 | Strengthened existing browser/profile/tab pinning, strict owner filtering, per-run extension checks; existing CDP background operation does not use the physical pointer. |
| 14 | Existing navigation/reload handling retained; popups created during input to an owned opener inherit its run ownership and are exposed through task tabs. Selection remains explicit and logical, never activates the tab/window. Descendants join scoped cleanup. Other popups are reported without adoption. |
| 15 | Existing frame/document tokens retained; global-to-frame-local IDs used by new waits and scrolling. General cross-origin/custom-frame compatibility still requires later validation. |
| 16 | Rich-text selection is editor-scoped; disabled/read-only inputs fail explicitly; autocomplete is no longer altered across a form. Existing dropdown/code-editor handling retained. |
| 17 | Added explicit scroll target and horizontal movement, actual movement/boundary result. Existing modal/largest-panel selection retained for unscoped calls. |
| 18 | Existing CDP hover/right-click/double-click/drag retained; cancellation releases held buttons and drag feedback follows dispatch. Existing coordinate clicks and gestures remain available for observed canvas targets. Followup adds dedicated guarded HTML range set_state, bounds/step metadata and pending readback verification; arbitrary ARIA/canvas setters remain unsupported. See browser-review.md. |
| 19 | File-input attachment checks name and byte size and explicitly does not claim server acceptance. Existing download events retained with bounded bookkeeping. No filesystem download verification added here. |
| 20 | Added bounded cancellable ready/URL/element waits; strengthened existing text waits. |
| 31–40 | Implemented overlay changes above. Pause/error supported; stop/completion remove the overlay through existing task lifecycle. UI stop controls stay in the app. Screenshot exclusion retained. Visual quality is unverified until the requested later Chrome pass. |
| 41–42 | Existing DOM snapshot is separate from screenshot capture. No new automatic model vision-selection policy in this component. |
| 43 | Prioritize controls before long link/list collections; explicit truncation retained. |
| 44–47 | Existing values batch/frame reads retained. No new tool search or model-call policy in this component. |
| 48–49 | Added per-command elapsed milliseconds; no performance claims or delay tuning without measurements. |
| 51–53 | Per-run tab ownership, in-flight cancellation and exact connection pinning; version/build/capability diagnostics. Reconnection can recover the same installation and owned tab through fresh observation; interrupted actions are never replayed. |
| 56–57 | Existing cleanup ownership retained; waits/animation timers/download records cleaned up or bounded. |

## Follow-up validation and remaining work

Later Chrome testing must cover concurrent cleanup/dispatch, cancellation during drag and text waits, profile ambiguity/reconnection, stale raw coordinate input, narrow/zoomed viewports, dark/high-contrast/reduced-motion rendering, rich editors in nested frames, and upload controls that replace their input after change. Benchmarks must measure observed outcomes, not just elapsed dispatch time.

Not delivered by this component: universal canvas/slider semantics; filesystem-backed download verification; new tool-search/model observation policies; cross-provider or competitor benchmark results. Existing behavior is not labeled newly verified.

Background job receipts now include `agent.runtimeTimings` through the shared receipt writer.

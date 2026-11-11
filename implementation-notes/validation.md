# Build and test validation

Validation performed on 2026-11-03 on Apple Silicon (arm64), macOS 27.0 and Google Chrome **156.0.8078.80**, on branch `improve/computer-use-reliability`. This follows the earlier implementation-only pass. No commit or push was made.

Temporary validation logs, duplicate reports, backup app copies and the dummy download were removed after validation. Archived evidence linked below is retained.

## Build and installed components

- Debug build passed (`swift build --build-system native`).
- Signed release bundle build passed (`build/Clinqy.app`).
- The signed app was installed at `/Applications/Clinqy.app`, version **0.3.1**.
- The initial connected Google Chrome extension compatibility check used build **2026-11-browser-reliability-1**, shared extension version **1.9.16**. After the autocomplete and popup-recovery fixes, debug and signed release builds passed again, the signed app was installed, and the connected Chrome handshake confirmed **2026-11-browser-reliability-2**. Corrected live workflow results remain separate below.
- Debug and installed-app self-tests passed. Offline replay passed **34 checks** across two recorded fixtures.

Debug and signed release builds including closed-child routing recovery passed (`/tmp/clinqy-debug-popup-routing.log`, `/tmp/clinqy-release-popup-routing.log`). The subsequent explicit-reload correction also passed a signed release build (`/tmp/clinqy-final-reload-refresh-build.log`). That latest signed app was installed byte-identical to the built executable, and its installed self-test passed (`/tmp/clinqy-final-installed-selftest.log`). Final status showed no foreground run, no browser jobs and compatible Chrome build 2. Initial build logs are `/tmp/clinqy-debug-final.log` and `/tmp/clinqy-release-final.log`. Existing compiler warnings remain; a passing build is not a claim that the project is warning-free.

Latest installed executable SHA-256: `9632478cfd91af6d1afe7416be620790ed17bc99cd43c94e3bc91e3c32c515f3`.

## Automated validation

| Area | Result |
| --- | --- |
| Action contracts and prompt reference | 54 action names consistent across dispatcher, contract and prompt; 43 valid compact examples; default/progressive mode and capability discovery checks passed. |
| Task recovery, journals, checklists, deliverables | 160 checks passed, including actual SQLite reopen, dispatch deduplication, unknown-effect preservation, explicit resume, independent file requirements, completion-write failure, popup-provenance constraints and closed-child recovery. |
| Scheduling | 48 checks passed. |
| Extraction | 9 checks passed. |
| Persistent task memory / route memory | 45 / 12 checks passed. |
| Task context / power assertions | 35 / 14 checks passed. |
| Observation geometry / desktop input | 23 / 72 checks passed. |
| Browser navigation / correlation | 14 navigation checks and correlation suite passed. |
| Extension JavaScript | All seven suites passed: activity, background ownership, frames, gestures, images, transport and shared version. |
| Installed extension reload | CLI reload replaced a deliberately stale helper 6 with bundled helper 7 and verified byte-identical contents; [sanitized proof](validation-assets/reload-refresh-proof.json). |
| Real isolated Google Chrome | 101 checks passed, including frames, gestures, range constraints/readback, condition waits, overlay geometry, cancellation and lifecycle behavior. |
| Semantic DOM text boundaries | A 13-check real Chrome regression using the actual `VerificationEvidence` matcher failed before the fix and passed afterward; all seven extension suites passed again. |
| Direct computer control | 197 checks passed for ownership, replay refusal, gestures, vision and final-artifact evidence. |
| Native AppKit fixture | 23 checks passed. Desktop noninterference measurement was inconclusive because physical HID input occurred during the probe; do not infer zero interference. |
| Provider protocol | HTTP mock suite passed. Codex session suite passed 43 protocol/isolation checks, routing, 14 screenshot acknowledgment checks and 15 stream protocol checks. These offline protocol tests make no model calls. |
| Updater | Version/signature checks, successful scratch swap, denied-directory refusal and real competing-lock refusal passed; original bundle remained intact on refusal. No real release update was downloaded or installed by these tests. |
| Delegation / worker sessions / efficiency | 68 / 31 / 68 checks passed. |
| Other regression suites | Data stores, image assets, router, notifications, connection drafts and Telegram attachment/routing suites passed. |
| Python evaluation harness | 17 tests passed. |

Telegram tests use local fixtures/mocks; no message was sent to a real recipient.

## Installed-app model workflows

All live model tasks use throwaway local fixture pages in **Google Chrome**, in background mode with task-owned tabs and independent fixture scoring. A model's success statement alone does not count as success.

| Run | Status |
| --- | --- |
| Main installed-app 25-case suite, initial pass | **23/25 independently verified**, zero false task-completion claims, wrong-target actions or duplicate effects. Autocomplete and popup were the two failures; all other cases, including the full workflow and actual file download, passed. This initial run is retained as 23/25. |
| First corrected installed-app Claude cases: autocomplete, popup, workflow | Autocomplete **passed in approximately 17 seconds** and workflow **passed in approximately 56 seconds**, both independently verified with reported success. Popup's fixture result was verified, but its task was cancelled after closed-child recovery stalled and reported no success; it is **not a completed runtime flow**. |
| Claude popup after parent-observation recovery fix | **1/1 independently verified with normal finished status and reported success**, approximately **37.5 seconds**, zero false successes, wrong-target actions or duplicate effects. |
| Codex smoke: name entry and range control | **2/2 independently verified**, zero false successes, wrong-target actions or duplicate effects. |
| Codex multi-step workflow | **1/1 independently verified** in approximately 207 seconds, zero false successes, wrong-target actions or duplicate effects. |
| First corrected installed-app Codex popup | Cancelled after the closed-child recovery problem; **not a completed runtime flow**. |
| Codex popup after parent-observation recovery fix | Fixture effect was verified, but the task **reported failure after approximately 164 seconds**; this is **not a completed runtime pass**. DOM text flattened an inline control and result status together, preventing strict confirmation matching. |
| Latest Codex popup with byte-verified helper 7 | **1/1 independently verified with normal finished status and reported success**, **67.041 seconds**, zero false successes, wrong-target actions or duplicate effects. |
| Latest Claude cross-check with byte-verified helper 7 | **1/1 independently verified with normal finished status and reported success**, **23.039 seconds**, zero false successes, wrong-target actions or duplicate effects. |
| Stale-helper Codex attempt | Cancelled after approximately **14.8 seconds** when the loaded extension copy was found to contain helper 6 instead of bundled helper 7. Excluded from corrected acceptance. Bundled extension files were then copied and verified byte-identical before fresh runs. |
| Cancellation experiment | Cancellation confirmed; no submission, wrong-target action, duplicate effect or false-success claim. Two local text fields had been edited before cancellation. This is a cancellation result, not a completed workflow. |

Archived local-fixture reports: [initial 25-case Chrome run](validation-assets/initial-chrome.json), [first corrected Claude run](validation-assets/corrected-chrome.json), [Codex smoke](validation-assets/codex-smoke.json), [Codex workflow](validation-assets/codex-workflow.json), [cancelled first Codex popup](validation-assets/codex-popup-cancelled.json), [Claude popup after parent recovery](validation-assets/popup-final-claude.json), [Codex popup text-boundary failure](validation-assets/codex-popup-status-boundary.json), [cancelled stale-helper Codex attempt](validation-assets/codex-popup-stale-helper-cancelled.json), [successful helper-7 Codex popup](validation-assets/popup-helper7-codex.json), [successful helper-7 Claude popup](validation-assets/popup-helper7-claude.json), and [cancellation experiment](validation-assets/cancellation.json). Failed and cancelled runs are not counted as completed passes. These artifacts contain local dummy-fixture data, not account/profile diagnostics or general agent logs.

Across the initial and corrected Claude runs, **all 25 distinct Chrome cases have a normal, independently verified passing run**. This is **not** a clean 25/25 rerun of the complete suite against the final build: the initial run was 23/25, followed by targeted corrected runs.

The initial autocomplete task stalled because visible options were omitted from discovery. Its source fix passed an isolated nine-check reproduction, extension suites and the installed-app retest. The initial popup task stalled because the unresolved opener action correctly blocked input to the new tab, but the model narrated that blocked input as clicked and waited for the user. Both initial stalled tasks were cancelled by their specific receipt. Zero false task-completion claims does **not** mean all intermediate model narration was accurate.

The first corrected popup attempts exposed a second issue: after the child tab closed, routing refused verification before the owned-opener evidence helper could run. Those Claude and Codex attempts were cancelled by receipt. The Claude fixture independently confirmed its local parent result, but its agent task remained cancelled; this report does not label that a completed runtime flow. Popup acceptance requires independent result evidence **and** normal terminal completion on the corrected route. The source restores observation of the exact captured owned parent before routing while preserving the pending-input barrier; 160 recovery/provenance checks passed. The next Claude popup met both requirements. The corresponding Codex run still reported failure despite the fixture effect: inline control text and result status were flattened without a word boundary. The semantic DOM text-boundary fix passed a 13-check real Chrome regression with the actual verification matcher and all seven extension suites; the general word matcher was not loosened. The fresh helper-7 Codex run then passed normally with independent result evidence; the helper-7 Claude cross-check also passed normally.

The final explicit-reload fix passed its signed release build and installed self-test. A controlled stale-copy check then demonstrated that CLI reload replaces helper 6 with the installed bundle's helper 7 byte-for-byte; [proof](validation-assets/reload-refresh-proof.json). No full status dump, profile identifier or general agent log was archived. These last reload-only changes were validated by that focused check; the full 25-case model suite was not rerun after them.

## Overlay artifact

The isolated Chrome fixture checks viewport bounds, exact cursor placement, target avoidance, click-through behavior and an unchanged page title. Screenshot from the Chrome run:

![Clinqy activity overlay in a local Chrome fixture](validation-assets/chrome-overlay.png)

This demonstrates the captured fixture only. It does not certify every website, browser zoom, theme, display configuration or accessibility preference.

## Fixes made during validation

- Replaced obsolete CoreGraphics Swift API spelling with `CGImage.typeID`.
- Simplified action-capability ranking to avoid the compiler's expression type-check timeout; kept ranking semantics.
- Fixed compact prompt JSON example formatting and updated isolated test stubs for progressive prompting.
- Fixed a legacy journal completion path that could associate an unrelated readback with an uncertain mutation's dispatch record.
- Added missing background routing for browser range state and structured condition waits.
- Removed scaling from reduced-motion cursor feedback; updated overlay tests to check current geometry, delivery phases, anchors and cleanup instead of obsolete title/offset behavior.
- Updated stale restart and updater test expectations while retaining explicit unknown-effect and original-bundle preservation assertions.
- Fixed autocomplete option discovery: a visible listbox need not declare `aria-expanded="true"` to expose its options; explicit `aria-expanded="false"` remains excluded. The isolated nine-check reproduction failed before the fix and passed after it, followed by all seven extension suites and the installed-app autocomplete retest. The page helper version advanced to replace previously injected code.
- Added explicit verification for an ordinary click inside an owned popup whose result appears in its opener: fresh new text must appear in that same run's pre-observed owned opener, with the same connection, tab and document, compared against the opener's own pre-click text. This requires known delivery; unknown or restored delivery and consequential actions, including Save, remain excluded. Opening or closing a window alone never proves success, and no input is replayed. Fourteen provenance cases and normal installed Claude/Codex popup runs passed; the latest Claude helper-7 cross-check also passed normally.
- Restored observation of that exact captured owned parent when a popup closes, including before background routing, without clearing the pending-input verification barrier. This resolves the second popup stall in the installed Claude run; subsequent Codex testing exposed a separate DOM text-boundary problem.
- Preserved semantic boundaries around visible result/status text so adjacent inline controls cannot concatenate with confirmation text. The page helper advances to version 7; a 13-check real Chrome regression failed before and passed after this change using the actual unchanged word-boundary verifier. Seven extension suites, a signed bundle build and normal installed Codex and Claude popup runs passed.
- Explicit extension reload now refreshes the installed extension copy from the signed app bundle first. A real CLI reload changed a deliberately stale helper 6 to byte-identical bundled helper 7, avoiding the stale-resource failure observed during validation.

## Boundaries

These results do not establish superiority or parity with another computer-use product. Native background control remains experimental and opt-in. Arbitrary app/toolkit compatibility, multi-display and other-Space behavior, long-running soak tests, update launch-health rollback, provider-wide repeated performance comparisons, reconnect fault injection and attribution of desktop interference remain separate acceptance work. No measurements here establish general latency gains.

The [66-item coverage ledger](backlog.md) retains the implementation boundaries; the [evaluation guide](../tests/benchmarks/README.md) documents reproducible workflow commands.

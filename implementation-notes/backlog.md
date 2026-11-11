# Clinqy improvement coverage

This maps the agreed 66-item backlog to source implementation. **The initial implementation pass deferred all builds and testing; the subsequent [validation report](validation.md) records completed builds and tests, pending runs and remaining acceptance limits.** Rows below preserve the original source-coverage distinctions: “Implemented” means code is present, not that every runtime environment passed; “Existing” means the prior mechanism was retained. Consult the validation report for evidence rather than treating an implementation label as certification. Measurement-dependent work remains explicitly scoped.

Detailed component notes: [runtime](runtime.md), [browser](browser.md), [native](native.md), [app quality](app-quality.md). Deferred test tooling and commands: [evaluation guide](../tests/benchmarks/README.md).

| # | Improvement | Source coverage and current boundary |
| --- | --- | --- |
| 1 | Verify before completion | Existing scoped verifier plus implemented checklist completion gate. Natural-language relevance of a chosen predicate is still model-dependent. |
| 2 | Multi-step checklist | Implemented durable `plan`, stable outcome IDs, evidence and user-scope supersession. |
| 3 | Reobserve after transitions | Existing observation refresh; native exact-window/sheet refresh strengthened. |
| 4 | Reject stale targets | Existing document/frame/native identity guards plus new raw-coordinate viewport checks. |
| 5 | Cause-aware recovery | Implemented cause classification and bounded recovery guidance; existing loop limits remain. |
| 6 | Do not replay uncertain actions | Existing pending-effect barrier strengthened with persistent action identities. |
| 7 | Crash-safe action history | Implemented transactional action journal and unknown recovery; resolved-entry retention is bounded. |
| 8 | Resume from verified state | Implemented explicit “Inspect and continue” with retained journal/checklist and fresh observation. Unknown input requires independent artifact evidence or explicit review; no automatic replay. |
| 9 | Useful partial results | Implemented verified-so-far and still-required checklist summaries. |
| 10 | Prompt cancellation | Existing model cancellation plus extension cooperative cancellation and held-input cleanup. Actual cancellation latency not measured. |
| 11 | Persistent Chrome selection | Existing explicit Chrome default and run override; strict browser-owner filtering strengthened. |
| 12 | Correct profile/window/tab | Implemented per-run tab token, structural profile discovery, build/identity handshake. Ambiguous profiles are not guessed. |
| 13 | Preserve user's active work | Existing inactive owned tabs/CDP; native input is target-scoped. Noninterference still needs live acceptance. |
| 14 | Popups and tab transitions | Existing navigation plus owned-opener popup inheritance during active input; explicit logical selection and scoped descendant cleanup, without activating windows. |
| 15 | Frames/shadow/rerenders | Existing exact document and frame tokens retained; new scrolling/waits resolve frame-local IDs. |
| 16 | Rich editors/autocomplete | Implemented editor-scoped replacement and disabled/read-only guards; retained dropdown/editor handling. Fixtures added. |
| 17 | Nested/virtualized scrolling | Implemented explicit container IDs, axes and units with observed movement/boundary results. Virtualized-app coverage needs later runs. |
| 18 | Drag/sliders/canvas | Existing gestures retained with cancellation cleanup and dispatch feedback. Added guarded HTML range set_state with finite min/max/step validation, metadata and pending exact-value/outcome verification; no universal ARIA/canvas setter. See browser-review.md. |
| 19 | Upload/download evidence | Implemented exact file-input name/size readback; existing download events and file verifier; new benchmark checks actual downloaded bytes. Remote acceptance requires page evidence. |
| 20 | Condition waits | Implemented bounded cancellable text/URL/readiness/element waits. |
| 21 | Native background input | Implemented opt-in, exact-window `BACKGROUND_NATIVE=1` path. Defaults off pending validation; arbitrary apps are not promised. |
| 22 | Background menu shortcuts | Implemented unique enabled AX menu-equivalent routing. |
| 23 | Covered/off-Space observation | Implemented all-Space exact-window capture plus optional private fallback. It does not force suspended renderers to update. |
| 24 | Sheets/dialogs/file pickers | Implemented sheet IDs and owner-blocking checks; existing menu/file operations remain. Unknown helper ownership is refused. |
| 25 | Geometry revalidation | Existing geometry checks strengthened with per-chunk/native target validation. |
| 26 | Mixed displays/scaling | Existing mapping retained; acceptance matrix prepared. Physical display tests deferred. |
| 27 | Precise Unicode editing | Implemented UTF-16 range validation, single-delivery text editing, exact readback/caret checks. |
| 28 | Preserve shared input state | Implemented no uncertain global/clipboard retry; existing clipboard ownership restoration retained. |
| 29 | Unsupported-operation handoff | Implemented capability-specific refusal and existing explicit foreground handoff. |
| 30 | Restore temporary state | Implemented scoped synthetic focus and retryable cleanup; existing owned resource cleanup retained. |
| 31 | Viewport-correct halo | Implemented visual-viewport geometry, restrained thin border and corner radius. Rendering untested. |
| 32 | Light/dark legibility | Implemented theme and high-contrast styles. Visual acceptance deferred. |
| 33 | Target-attached cursor | Implemented document/element anchoring with bounded tracking and invalidation. |
| 34 | Distinct action feedback | Implemented click/type/drag/upload/wait/status phases. |
| 35 | Truthful animation | Implemented prepare/delivered/error stages; pulses follow dispatch acknowledgment, not queueing. |
| 36 | Accurate work status | Implemented runtime observing/planning/verifying/waiting/pause hooks; app-quality integration described separately. |
| 37 | Avoid important controls | Implemented badge relocation away from cursor target and compact labels. Arbitrary page occlusion still requires visual review. |
| 38 | Clear stop/pause/result | Implemented pause/error feedback and lifecycle removal; app task controls remain the action surface. |
| 39 | Reliable overlay cleanup | Implemented lifecycle/timer cleanup, bounded heartbeat and nested capture hiding. |
| 40 | Reduced motion/evidence exclusion | Implemented reduced-motion styling; existing screenshot exclusion strengthened. No title mutation. |
| 41 | Text-only observation | Existing DOM-first/vision policy preserved; no additional screenshot-only AX traversal suppression. |
| 42 | Images when needed | Existing vision policy plus pinned native screenshots retained. |
| 43 | Prioritize controls | Implemented bounded native/browser control prioritization and explicit truncation diagnostics. |
| 44 | Search observations | Added look(query, role) filtering of current bounded native/browser observation with stable existing IDs and bounded output. Explicitly excludes omitted/offscreen controls and does not count as fresh evidence. No general semantic index. |
| 45 | On-demand capability docs | Implemented query-filtered `capabilities` lookup and opt-in `PROGRESSIVE_TOOLS=1` compact control prompt with detailed action examples on demand. Default retains full prompt; provider tool schemas are not deferred. |
| 46 | Batch independent reads | Existing task contexts and batched/frame reads retained; dependent actions remain ordered. |
| 47 | Fewer deterministic model calls | Existing deterministic verification and fast routing retained. No unmeasured reduction claimed. |
| 48 | Phase timings | Implemented observation/action/verification/model/task metrics and receipt/report collection. |
| 49 | Tune observed latency | Timing collection and comparable benchmark tooling implemented; actual delay tuning deferred until measurements. |
| 50 | Provider failures/waits | Existing bounded typed recovery/timeouts/rate-limit handling retained; runtime cause guidance strengthened. |
| 51 | Session input ownership | Implemented per-run browser tokens and shared native synthetic-input ownership; existing external-control lease retained. |
| 52 | Reconnect without wrong target | Implemented same-installation/browser reconnection and owned-tab existence check followed by fresh observation. No migration to a different profile or mutation replay. |
| 53 | App/extension mismatch | Implemented separate build/capability handshake and actionable diagnostics; shared Windows version remains compatible. |
| 54 | Permission diagnostics | Implemented permission-purpose and native-capability diagnostics in app status/doctor. |
| 55 | Readable task history | Implemented task UI for requested outcomes, evidence, uncertainty/partial results, outputs and action history. |
| 56 | Cleanup only owned resources | Existing receipt/tab cleanup retained, run ownership strengthened, temporary input cleanup implemented. |
| 57 | Long-running stability | Bounded observer/animation/download/journal structures, updater timer cancellation, Efficiency/Clipboard shutdown and badge lifecycle cleanup implemented; soak measurement deferred. |
| 58 | Safe updates/settings | Existing external settings storage plus idle-only installs, bounded downloads, serialized swaps, and rollback on rename/open-command failure. No startup-health/schema rollback guarantee; no installation executed. |
| 59 | Complete Chrome workflows | Implemented workflow fixture and runner cases, independent scoring. Not run. |
| 60 | Slow/rerender/session/fault cases | Added delayed preview/rerender/local expired-session/popup cases and receipt-scoped cancellation experiment. Extension disconnect/restart fault injection remains operator-controlled. |
| 61 | User working elsewhere | Implemented optional passive desktop sampler and two-mode protocol. Observations are not automatic attribution to Clinqy. Not run. |
| 62 | Failure/interference metrics | Independent wrong-target/duplicate/false-success scoring retained; focus/pointer/clipboard sampling added. Permission-gated visible window-order changes are sampled without titles/content; attribution and sub-50ms changes remain unmeasured. |
| 63 | Cross-provider workflows | Implemented sequential matrix runner with identical templates/repetition counts. Not run. |
| 64 | Installed app + extension | Harness collects actual bundle metadata and supplied live status/build diagnostics. It never substitutes source version for installed version. Not run. |
| 65 | Capability matrix | Acceptance ledger implemented with explicit untested status for each surface/environment. No compatibility fabricated. |
| 66 | Like-for-like tool comparisons | Strict report comparator and external fixture-evidence importer implemented. No competing product executed or benchmark result invented. |

## Remaining implementation distinctions

This pass does not implement full provider-level lazy tool-schema loading, a general semantic observation index, a universal native/custom-canvas controller, or automatic attribution of user-versus-agent desktop interference. Native capability gates and handoffs are intentional. Performance tuning, visual approval, compatibility certification, and comparative claims require the testing phase the user deferred.

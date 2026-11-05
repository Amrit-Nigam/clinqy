# Runtime implementation — verification deferred

User requested implementation only. No tests, builds, installations, browser runs, or native UI interactions were executed for this change. Findings below are from source inspection, not demonstrated runtime results.

## Implemented

- **1–2, 9:** `plan` records up to 32 requested outcomes with stable `s1` identifiers. `verify` may carry `step`; an entry completes only after the existing verifier returns confirmed evidence. Completion is blocked while entries remain open. Failed tasks include verified partial results and outstanding outcomes. Simple tasks do not require a plan. Outcome-to-evidence semantic relevance still requires the model to choose the correct predicate; the runtime does not claim to prove natural-language equivalence.
- **2, 8:** Checklist entries, evidence, timestamps, and scope changes persist in TaskStore. A new user instruction allows one explicit `plan` supersession of changed outcomes; the actual redacted user instruction is retained as provenance. Models cannot silently delete outcomes. The task UI can show these optional backward-compatible fields.
- **6–8:** TaskStore persists action reservation and task checkpoint in the same SQLite transaction. Journal entries have task/run/action IDs, a keyed argument fingerprint and non-content target metadata (tab/document or PID/window). Arguments are not persisted. The fingerprint key is ephemeral; UUIDs, not fingerprints, are durable identity. Reusing a dispatch ID is refused. In-flight actions recover as unknown after restart; cancellation/failure also normalizes prepared journal entries to unknown. The existing pending-outcome barrier is the actual protection against semantic replay, not a claim of exactly-once external execution.
- **7:** Journal history is queryable per task and retained at bounded size/age for resolved entries on terminal tasks. Uncertain entries are never pruned by this policy.
- **8:** `Agent.prepare` reconstructs a pending barrier from either pre-dispatch or unverified checkpoints. A restart has no trustworthy live UI baseline; artifact verification or explicit user review is required, and no stored action is automatically replayed.
- **5:** Added cause-specific recovery guidance with per-target attempt counts for stale observations, loading and disconnection. Permission, unsupported capability and ambiguous targets get separate next steps. No recovery automatically repeats a mutation. Existing model-loop and completion limits remain enforced.
- **10, 36, 38:** Browser progress hooks now distinguish observing, planning, verification, waiting and user pauses. Existing cancellation still cancels model/control tasks, closes provider sessions and leaves uncertain actions auditable.
- **17–18:** Agent now exposes container-targeted browser scrolling via current `w` IDs, both axes and explicit lines/pixels/pages. It reads the actual scroll result and reports a boundary instead of claiming movement. Native container IDs are refused rather than ignored.
- **21–24, 28–30:** Integrated the native agent's capability-gated `BACKGROUND_NATIVE=1` APIs. Native mode selects only a uniquely named already-running nonbrowser app, pins one window, reobserves the same window (or its attached sheet), and rebinds only identical AX objects. It supports the capability helper's plain current-element click/type and scoped keyboard path. It does not launch/unhide/raise apps or fall through to system-pointer input. Native screenshot/read/wait paths remain pinned and do not write the clipboard. Browser sessions never enter this route. The default remains off pending live validation.
- **43–45:** Existing bounded observations now show the native scan's own truncation diagnostic. `capabilities` provides bounded, query-filtered argument metadata and action examples. With `PROGRESSIVE_TOOLS=1`, controlling sessions load the compact control contract and action catalog; detailed examples are retrieved on demand. Default sessions retain the full prompt. This defers prompt documentation, not provider tool schemas; token savings and behavior validation are deferred.
- **48–49:** Observation, action and verification timings are separated; task records store model and total timing too. CLI receipt writer supports optional `phaseMilliseconds`, and the foreground agent supplies them. Browser job completion must also pass `agent.runtimeTimings` to expose the same metrics there.
- Fixed a pre-existing replacement-only field-readback check incorrectly being applied to successful native insert/append edits. Those modes retain their own verified edit path.

## Existing mechanisms strengthened or retained

- **1, 3–4, 6:** Fresh-scoped verification, image provenance, native window identity, current browser document references, and input-delivery/outcome separation already existed. These remain the authoritative action gates.
- **10, 46–47, 50–52:** Existing single-use external-control observations, per-run task contexts, owned-tab routing, serialized control requests, bounded provider retries/timeouts, parallel independent reads, fast model routing, and deterministic checks remain in use. This change does not claim to replace them.
- **41–42:** Existing vision policy already suppresses unnecessary screenshots for readable DOM workflows and requests images for visual/native uncertainty. It was preserved while adding pinned native screenshots. Full screenshot-only accessibility-scan suppression was not introduced in this runtime patch.

## Static-review notes / validation to perform later

- Compile Swift, run task-store migration/journal crash fixtures, action-contract tests and provider tests.
- Test callback cancellation after dispatch, nested autofill actions, storage failures, restart recovery and same-action-ID rejection.
- Exercise checklist creation, evidence linkage, partial results, user scope changes, restored records and test-only in-memory runs.
- Test native mode per app/macOS release, especially focused sheets, covered/off-Space windows, cleanup on error, no foreground/focus/pointer/clipboard changes, and physical user typing during work. Private SkyLight behavior is not a universal background-control guarantee.
- Browser scrolling needs real Chrome validation on nested/virtualized containers and boundary conditions.
- Benchmark collection and comparisons are deliberately deferred; no performance or reliability improvement is claimed as measured.

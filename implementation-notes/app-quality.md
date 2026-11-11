# App, diagnostics and recovery UI implementation

Implementation only. No build, syntax/typecheck, test suite, update installation, or live UI/browser run was performed. The only mechanical check was `git diff --check` on owned changes; source review does not establish runtime compatibility.

## Implemented

- Task recovery UI uses lazy rows and search/filtering, displays the original request, current stage, outcome checklist, evidence, superseded outcomes, remaining requirements, unverified/pending actions, partial results, output paths, and expandable action journal/timing details. It labels generic step counts as completed, not independently verified.
- An explicit **Inspect and continue** action calls the runtime's `TaskStore.requestResume` for interrupted/failed/cancelled tasks. It keeps the same task and journal/checklist. The runtime observes afresh and retains uncertainty barriers; this is not replay. App dispatch distinguishes browser work from native background work when starting queued/recovered tasks.
- App status exposes app version, per-extension version/build compatibility and capabilities, native background availability, recovery-task count, storage errors, and permission purposes. Opaque extension installation IDs are not represented as account names or filesystem profiles.
- `doctor` explains each missing permission's purpose and each extension build mismatch, including the browser that must be reloaded. It reports recovery/storage issues and identifies enabled-but-unavailable native input.
- WorkingBadge supports meaningful runtime status text and waiting state, reduced-motion behavior, accessible text, and generation-guarded hide animations so a late hide cannot remove the next run's indicator.
- Stats reads actual `phase_ms` measurements rather than estimating all phases from log spacing. Missing measurements are omitted; the report explicitly says overlapping phases cannot be summed as total latency.
- Updater startup/scheduled checks are deduplicated and cancellable, automatic prompts do not interrupt running work, installation rechecks idleness after downloading, and the CLI checks running tasks before and after downloading. Download waiting is bounded.
- Update replacement is serialized using macOS `lockf` with a retained lock inode. A ready/accepted handshake is completed inside the acquired lock before the parent quits. A lock failure or handshake expiry leaves the running app open; a delayed unacknowledged helper cannot swap it. The helper bounds waiting for the old app, restores the backup on rename or launch-command failure, and cleans its staging/handshake artifacts.
- Settings/history remain outside the installed app as before. Efficiency observers and clipboard polling are stopped during shutdown, and retained clipboard context is cleared.

## Backlog coverage

| Items | Status |
| --- | --- |
| 8–9, 55 | Explicit continuation plus readable outcomes, uncertainty, partial results and evidence. Uncertain effects still require valid artifact evidence or user review; the UI does not invent pre-crash state. |
| 36, 38 | Native status API and waiting presentation; runtime wires phases. Existing task stop controls retained. No new execution pause/resume semantics claimed for an actively dispatched operation. |
| 48 | Direct phase measurement reporting and task-level timing details. No speed claims without later measurements. |
| 51–52 | Existing task capacity/ownership retained; runtime/browser implement the actual input/session coordination. Recovery UI preserves their barriers. |
| 53–54 | Build-aware extension diagnostics and permission-purpose explanations. |
| 56–57 | Updater-owned cleanup, bounded helpers, timer/observer lifecycle cleanup, lazy task history rendering and badge lifecycle fixes. No soak-test claim. |
| 58 | External settings/history preserved; serialized update swap, explicit lock acquisition, busy-task checks and failure cleanup/rollback implemented. |

## Explicit limits for later validation

- Successful `open` means LaunchServices accepted the launch. This is not a full startup-health check, and no rollback of a changed database schema is implemented.
- Native background availability is a capability report, not evidence that a particular app works on every OS release.
- Installed app/extension integration, task recovery, concurrent updater contention, rename/launch failure, missing permissions, rendering, and memory/CPU behavior remain untested in this implementation-only pass.
- Existing updater tests that assumed a lock/permission-refused swap always returns a Process need to accept the new immediate refusal error as an alternative. No tests were executed.

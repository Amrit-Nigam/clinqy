# Computer-use evaluation

This tooling was initially implemented without running it. The subsequent [build and test validation](../../implementation-notes/validation.md) records actual runs, initial failures, corrected retests and acceptance limits; the [capability matrix](capability-matrix.md) distinguishes measured fixture scope from untested environments. Commands below reproduce the evaluations. No general speedup, app compatibility or competitor superiority follows from a local fixture result.

## Local workflows

`run.py` defaults to Google Chrome and 18 control cases, including numeric HTML range control (0–100, step 5, from 25 to 65). The range case asks the installed agent to use `set_state`; independent fixture scoring requires the resulting value and exactly one change event. `--suite workflows` adds rich-editor scope, autocomplete, nested scrolling, an owned popup, an expired local session, a full multi-step workflow, and an actual downloaded-file check. Fixtures have their own random URLs and no external accounts. Local submission is explicitly authorized by each relevant task. A report counts an application result independently of the agent's final answer. Duplicate submissions/reviews and wrong-target clicks fail the result.

```sh
python3 tests/benchmarks/run.py --suite controls --provider claude --repeat 3 --out /tmp/clinqy-controls.json
python3 tests/benchmarks/run.py --suite workflows --provider codex --download-directory "$HOME/Downloads" --repeat 3 --out /tmp/clinqy-workflows.json
python3 tests/benchmarks/run.py --case workflow --monitor-desktop --out /tmp/clinqy-observed.json
```

The download directory must be Chrome's actual configured directory. The harness never changes Chrome settings. Each download has an unpredictable fixture-owned filename; scoring reads exact bytes from that regular file and rejects symlinks. Successful test downloads are left in that directory for inspection. Attachment files and the local fixture server are cleaned up. The fixture records attachment content, so it cannot confuse an unrelated filename with a correct upload. An upload result here proves local input handling, not remote server acceptance.

Each case uses its own receipt. Timeout, interrupt, or error cancels only that receipt, waits for a terminal acknowledgment, and stops the sequence if cancellation is unconfirmed. Partial results are persisted before dispatch. `--cancel-after 5` explicitly runs a cancellation experiment; it remains a cancelled/incomplete task, not a passing completion benchmark. Do not mix those reports with ordinary completion comparisons.

## Provider and implementation comparisons

```sh
python3 tests/benchmarks/matrix.py --provider claude --provider codex --provider agy --out /tmp/clinqy-matrix --case workflow --repeat 3
python3 tests/benchmarks/compare.py /tmp/clinqy-matrix/01-claude.json /tmp/clinqy-matrix/02-codex.json
```

Providers run sequentially. This measures Clinqy using each provider, **not** those providers' own computer-use products. No global provider setting is changed. The comparison rejects differences in fixture hash, case templates, repetition counts, browser, execution mode, and cancellation experiment. Environment metadata remains visible; it does not normalize hardware/model differences or imply statistical significance.

`import_results.py external.json --out normalized.json` accepts measurements gathered separately with another computer-use product using these same fixtures. Input must identify `tool`, `fixture_sha256`, `browser`, `mode`, `environment`, and `runs`. Each run supplies `name`, `seconds`, `reported_success`, and independently recorded `fixture_state`; the vision case also supplies its generated `visual_code`. It recomputes scores and does not trust imported pass/fail flags. Imported measurements remain labelled external and unaudited. This is a file format adapter, not an invented Codex/Claude automation API. Never hand-enter guessed results.

## Measurement provenance

- `phase_milliseconds` comes from the installed app's receipt when available. Missing receipt fields remain null; elapsed command time is not presented as observed outcome latency.
- Bundle versions come from the actual `--installed-app` bundle, not source files. A separately captured fresh app status JSON can be passed through `--diagnostics`; only version/build/compatibility fields are retained. Without it, connected extension state is unknown.
- `--monitor-desktop` launches the passive Swift sampler at test time. It counts changes in frontmost process, pointer samples, and clipboard change count. It does not read clipboard contents, titles, screenshots, or install an input event tap. Startup time is excluded from task duration. An unavailable compiler/sampler produces an explicit missing measurement.
- The sampler cannot attribute a change to Clinqy versus a person. For background noninterference checks, first run with the desktop idle, then repeat while the user works elsewhere and inspect events in context. Visible normal-layer window order is sampled by PID/window ID only when Screen Recording permission already exists (no permission prompt); its count includes creation/removal/reordering, is unattributed, and is null if any query is unavailable. Sub-50ms changes are not measured. Model cost, intervention counts, and recovery counts remain unavailable unless separately collected; null never means zero.

## Later failure and lifecycle checks

These are intentionally operator-controlled, because reloading an extension or closing a browser can disrupt unrelated tasks:

1. Start only a disposable local workflow and record its exact receipt/profile/tab. While it waits for the delayed preview, disconnect/reconnect the extension in that profile. Verify no input is replayed and that recovery requires a fresh snapshot of the same owned tab.
2. Repeat with a popup closing, a tab navigating, and a field rerendering between observation and dispatch. The harness includes the popup and rerender cases; timing-specific fault injection requires the operator or a dedicated isolated-browser driver.
3. Run the cancellation experiment during an unfinished workflow; inspect the terminal receipt, remaining fixture state, held keys/buttons, and overlay removal.
4. Exercise OS permissions, native windows, multiple displays, low-power mode, restart journals, update rollback, and provider disconnects in disposable fixtures. Use the [capability matrix](capability-matrix.md) to record exact environment and evidence.

Do not run fault injection against personal documents, signed-in production forms, or unrelated browser sessions. No such actions are part of this harness.

## Offline harness tests

```sh
python3 -m unittest discover -s tests/benchmarks -p 'test_*.py'
```

These tests cover result scoring, ownership cleanup, imports, comparable conditions, and exact-file evidence. They do not substitute for the installed-app and Chrome runs above.

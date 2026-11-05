# Static integration review

Implementation only. No tests, compiler checks, builds, installation, or live UI were run.

- Native inputs retain the original observed element/window. A refreshed native ID cannot silently bind to a replacement control or window. Keyboard delivery and type-submit now use scoped native targets; cleanup does not activate the former foreground application over a user's newer choice.
- Nested autofill fields each reserve their own action journal entry. Failed or uncertain fields stop the batch. A second mutation cannot overwrite an existing unresolved reservation. Completion receipts also check pending actions.
- TaskStore.requestResume queues the same interrupted/failed/cancelled task identity after explicit user request, preserving checklist, journal, and unknown-delivery barriers. It does not replay actions or claim recovery succeeded.
- Browser verification can migrate a retired connection only with the same extension installation/browser owner/run ownership, exact tab, and document. Screenshot provenance is not migrated: visual evidence must be captured again.
- Structured wait conditions are exposed as `wait.condition`: ready, URL substring, or observed element visible/enabled/gone. The dispatcher calls the existing browser wait primitive, refreshes afterward, and does not treat waiting as independent completion evidence.
- Startup browser cleanup checks active isolated background records as well as task-local state. Popup adoption, task-tab creation, removal bookkeeping, and task completion share an ownership-storage lane; completion blocks new adoption from ending roots and drains queued adoption work.
- `PROGRESSIVE_TOOLS=1` opts into a smaller control prompt plus action catalog. `capabilities` returns argument metadata and matching examples extracted from the established full action reference. The default remains the full prompt. Warm sessions are keyed by the actual selected prompt. This is real prompt deferral, not provider tool-schema loading. Token/behavior measurements remain deferred.
- Working status updates distinguish reading, planning, waiting, and verification.

Limits: predicate validation checks evidence shape and target provenance; it cannot prove a model-selected predicate semantically covers every requested objective. Native owned popovers outside the observed window still need independently established window identity rather than widening click bounds. Native capability support remains explicit opt-in with refusals for unsupported delivery paths. Prompt extraction and reconnect races require the deferred test phase.

## Completion follow-up

- Outstanding saved-file deliverables explicitly block success in Agent and TaskStore; failure is not inferred solely from response wording. Saved-file verification resolves only a requirement whose expanded, standardized, symlink-resolved path matches the inspected path. Other deliverables remain open. Persistence failures return an explicit failure.
- TaskStore.finish now returns its durable-write result. Agent persists completion before publishing history, callbacks, success notifications, or receipts, and downgrades failure to persist or a non-success stored state. Automatic continuation retains the existing nonterminal behavior.
- Browser range state actions participate in same-owned-tab recovery. Bounded observation search reports displayed and total matches.
- Static whitespace review only; runtime validation remains deferred.

# Parent-only rollout and allowed restoration

Tested foundation base: `45d527c0819bbd43dd579781e3b5a154184c4ead`.
Procedure only, not a claim of integration/deployment/live completion. Fresh lead and
parent own the remaining gates after worker submits its private commit.

1. Recheck current bootstrap generation/incarnation and exact proposal manifest; fresh
   review changed/adjacent production workflows at exact commit, rerun focused/full seed17
   with separate private build/deps/runtime/temp/tool roots.
2. Integrate serially at exact compatible current revision. Load Data, Scopes, Store,
   Bootstrap, Flywheel only after state-shape review. NanoAgent changed only by a docs
   pointer, no agent state-shape change. No Application auto-start/import was added.
   Parent explicitly supervises owner via Supervisor.start_child(Nano.Supervisor,
   {Nano.Flywheel, root: graph_root, repository: repository_root, owner: "altair"}).
   Supervisor startup contains a corrupt/unsupported-state refusal. Never fault/restart
   the shared node to activate this code.
3. Record exact deployed revision/modules; verify bounded read-only owner snapshot/readiness
   and harmless separate private disposable-project claim/release smoke. Never sabotage
   real claims. Source presence alone is not deployment or verification.
4. Close/announce serialized U03 bootstrap only after actual applicable code gates. Freeze
   dispatch; Bootstrap.capture finalized U01/U03 JSON records verbatim. Append full verified
   integrated commits without rewriting prior short-commit history. Validate whole candidate
   and canonical claims. Synced state.term rename is single durable cutover; old JSON remains
   immutable evidence, not parallel authority.
5. Import with %{bootstrap: records, freeze: evidence}; readiness freezes. Restart/reconcile
   owner to commit new owner generation. Manual units remain bootstrap-pending/not claimable.
   reconcile_bootstrap matches original done-record hash/unit/bytes and complete owner-verified
   stage evidence, original author/generation and full integrated commit. No fabricated graph
   worker token or auto-done. Parent closes in dependency order with real live evidence.
6. Publish exact landed API and ready/pull/claim -> parent prepare_dispatch -> verify full
   resolved unit/private exact base -> edits -> proposal handshake in each subsequent brief.
   U02 alone after U03 actually done; no larger swarm/dependents while only integrated.

## Formats and allowed restoration

Old: finalized serialized bootstrap JSON + attributed history. New: schema_version 1
coherent state.term + original JSON bytes/hash. Only fixed protocol atoms persist;
caller information becomes bounded inert strings, decoded with safe external-term decoder.
No durable PID authority or executable evidence. Monitors never reconstruct authority.

Allowed restoration is roll forward from latest coherent graph: preserve state.term,
restart compatible v1 owner in disposable rehearsal, read/reconcile before claims reopen,
persist new owner generation, adopt pending reservation under new integration generation
with actual Git diff validation, resume recorded integration/deployment stages rather than
repeat unsafe effects. Failed writes stay degraded/nonready. Reread uncertain persistence;
never overwrite newer authority on DOWN or source rollback. Preserve history, proposal
provenance, reservations, generations and applicable external blocker evidence.

Downgrade to pre-graph code is forbidden: it cannot honor v1 authority. Corruption requires
reviewed roll-forward repair/quarantine or external maintenance, not empty reconstruction
or an older authority checkpoint. No host power-loss/shared-node restart experiment claimed.

Disposable production-path tests rehearse forward claim/expansion/submission, failed writes
(including persist-before-error), worker/owner death, retained deployment stages, process
restart and a fresh OS VM restoring safe-decoded inert evidence, accounting/scopes/generations
and rejecting stale tokens. Original U01 migration checks archived Git commit/ancestry;
stage-proof fixtures are not fresh real-world deployment verification. Parent supplies
actual closure/live proof at cutover.

Integration repair: accept now persists a clean canonical-repository HEAD pin before cherry-pick; land validates candidate parent/diff and exact merge-tree result. Older pre-pinning accepted schema1 snapshots are retained but cannot land: reconcile/adopt to fence old reservation, then accept a compatible clean base. No pin inferred from monitor/history/evidence. Roll forward; no deployed graph downgrade allowed.

Attempt-proof repair: fresh claims/reopens archive prior evidence, clear active pointers, and require current prepared-attempt stage bindings. Completed pre-binding graph snapshots (never deployed by this worker) are semantically incompatible and quarantine rather than auto-done; parent must use a reviewed roll-forward evidence reconciliation, never strip newer authority. Explicit original bootstrap migration retains its separately verified seam. Reconcile and startup now share semantic validation; invalid disk stays untouched and claims degraded.

Crash after actual Git commit before durable land: reconcile latest graph, adopt pending proposal under new integration generation, use recover_land on existing clean current HEAD with preserved accepted pin. Exact historical-parent/proposal-tree/diff check, new attributed generations; no reset or repeat cherry-pick. Legacy accepted pins preserved in history but not active recovery receipts require explicit reviewed rollforward repair, never infer candidate/base. Already-durable same-revision land stages resume without replay.

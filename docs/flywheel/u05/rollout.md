# U05 owner gate and restoration

## APIs and failure behavior

`Nano.StateStore.register(name,id,self(),recovery_generation)` registers current logical
identity and process incarnation. Only the registered caller may checkpoint.
`checkpoint(token,revision,metadata,bindings_or_unchanged)` returns `{:ok, ack}` with
status, accepted_revision, durable_revision, dropped and persistent warning; errors
include stale, stale_revision, incoherent, bindings_unavailable, deleted,
retired_identity, degraded and unavailable. `:unchanged` never imports predecessor
bindings after replacement. Production NanoAgent uses this path, not legacy put/2.
`binding_status/1` distinguishes explicit empty from unavailable; `Nano.Ops.durability/0`
includes recovering live agents whose metadata is deliberately not exposed as current.
Legacy put/2 is retained for partial non-agent records, never unfenced full-agent saves.

Disk-only failure remains available in memory with API/operator and model-input warnings.
Registration/store absence holds new model/eval launches (including provider retries),
retains completed evidence and uses a bounded pending-event queue with overflow counts
logged. It is not a bound on an externally flooded BEAM mailbox or arbitrary eval effects.
The normal agent log can append completed evidence while ETS is absent. Crash formatting
redacts checkpoint metadata and binding values.

## Formats and restoration

See schema/migration.md. Old process StateStore state was a watched-pid map; new process
state contains lifecycle authority, registrations, recovery epoch and binding references.
Old disk files remain read-only. Coherent embedded legacy bindings migrate once; unversioned
split files cannot prove matching identity/revision and stay unavailable. New durable
lifecycles retain retired IDs and tombstones. Replacing source alone cannot revoke them.

Allowed restoration is roll-forward with compatible U05 code and the **entire latest**
coherent authority/envelope/blob directory. Preserve later tombstones, retired IDs,
accepted pending evidence and generations; do not overlay an old checkpoint on newer
same-name authority. The disposable migration test clones the latest coherent directory,
starts U05 in that copy, verifies revision/pending evidence/lifecycle identity, then commits
further mutation+tombstone and restarts again. Older pre-U05 source downgrade is forbidden.
Missing/corrupt selected blobs cannot be repaired by choosing an unrelated newer blob.

## Parent-only rollout

The bounded hot conversion seam is:

```
:sys.change_code(store_pid, Nano.StateStore, :pre_u05, {:u05_upgrade, max_agents}, 15_000)
```

Only use it on the legacy watched-map process state, after fresh exact-revision review.
Its bound counts both live named agents and saved metadata entries (1..10000 allowed).
It refuses nonquiescent agents, unavailable/malformed identities, invalid old process
state, unsupported/corrupt authority, or conflicts with newer lifecycles. It syncs the
whole lifecycle candidate before replacing legacy agent rows. Existing newer authority
is read and preserved, never regenerated from old bytes. It retains legacy files, log
sequence/token counters and monitor refs, restores only coherent v1 disk pairs and
asynchronously requests full live resaves under a new store epoch. Legacy dead split
records stay visibly unavailable, not silently paired or revived. Such unavailable
recovery outcomes require owner disposition; fixtures cannot make them current.

**Owner protocol (bounded cooperative rollout, not a sandbox):**

1. Pause cooperative new-agent launchers for the short upgrade lane. Inventory exact
   named live pids/identities, saved-entry count and existing authority; preserve all
   current bytes. Choose an explicit count bound and deadlines. If any actor cannot
   quiesce, or launchers cannot be paused, stay maintenance-blocked without loading.
2. Suspend every inventoried live agent at its callback boundary with bounded
   `:sys.suspend(pid, timeout)` calls **before** suspending StateStore. Eval/model tasks
   may complete while callbacks are suspended; their messages remain queued. Never
   kill/restart those agents or tasks. A coordinating eval Task can continue while its
   own parent agent is suspended, but must resume that parent before returning.
3. Suspend StateStore, verify the named live set has not changed and all actors are
   actually quiescent. Load the exact reviewed StateStore and NanoAgent modules once;
   do not purge the old NanoAgent code while old eval tasks may still execute it.
   New NanoAgent.start/1 now refuses launches until store availability is restored.
4. Invoke the exact change_code seam above. Failure means keep the lane suspended and
   preserve bytes; persistence uncertainty is not permission to resume incompatible
   old state or downgrade. Re-read latest authority and retry the same compatible
   conversion only after resolving the failure (the disposable test exercises an
   authority commit-before-ack error and safe retry). Never reset newer generations.
5. Resume Store **before** agents, then resume agents. Their lazy registration and
   coherent full resaves preserve identity/bindings and completed evidence irrespective
   of whether task-result or resave messages arrive first. Registration/store loss
   holds new launches; disk-only failures expose memory_only warnings.
6. With deadlines, verify each exact live pid/id has current store epoch/incarnation,
   expected lifecycle, coherent binding availability and accepted/durable revisions;
   inspect queued/completed evidence without printing bindings. Only then reopen
   launchers and record deployment/live evidence. Timeout/unavailable/degraded remains
   blocked and requires a reviewed roll-forward repair, not a fabricated pass.

`test/flywheel/u05/hot_upgrade.exs` is a standalone **disposable OS VM** driver.
It compiles exact base old Store/Agent source before application boot, seeds two live
agents, reproduces the old store-kill metadata-only resave losing its binding row while
the live agent still retains bindings (baseline failure), then keeps an old eval in flight across module load, rejects unquiescent/count-bound
conversion, completes that eval while agents are suspended, queues events and a store
caller, injects authority commit-before-ack failure/retries preserving exact bytes,
converts without changing Store/agent pids, verifies bindings/pending evidence, then
rehearses disposable Store and agent restart recovery. This is two-actor upgrade proof,
not measured proof for every live actor on this harness. Parent alone executes live gates.

Before accepting: verify exact dispatch claim/generation/hash, actual manifest/scopes and
compatible integration base; obtain fresh nonauthor workflow review. Before any rollout:
preserve latest authority and evidence, rehearse applicable migration in disposable VM,
verify effective private paths, and obtain the compatible conversion decision. Only parent
integrates/loads/verifies/announces/closes. No deployed/live/done claim is made here.

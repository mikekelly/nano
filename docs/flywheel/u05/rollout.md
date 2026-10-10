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

There is **no proven hot v0-to-v1 GenServer state conversion** in this proposal. Merely
loading StateStore onto its old running state is unsafe. Parent must independently prove
and review a bounded compatible state conversion plus registration/resave of every live
agent, or keep the integrated change **not deployed / maintenance blocked**. Do not restart
or fault the shared node/store to obtain evidence. Externally scheduled maintenance is a
separate operator outcome, not a worker permission or a fixture/live pass.

Before accepting: verify exact dispatch claim/generation/hash, actual manifest/scopes and
compatible integration base; obtain fresh nonauthor workflow review. Before any rollout:
preserve latest authority and evidence, rehearse applicable migration in disposable VM,
verify effective private paths, and obtain the compatible conversion decision. Only parent
integrates/loads/verifies/announces/closes. No deployed/live/done claim is made here.

# U05 lifecycle/envelope v1

Legacy `<name>.term` and `<name>.bindings` are read-only evidence. New authority is
`lifecycle-v1.term` (external term `%{version: 1, agents: %{name => %{id, generation,
status: :active | :deleted}}}`). Each active agent has `<name>.envelope-v1`,
containing version, name/id/lifecycle generation, monotonically increasing revision,
metadata and immutable binding blob basename. Blobs are SHA-256-addressed
`<name>.<digest>.bindings-v1`; their content includes identity, kept variables and
explicit dropped names. Empty is an explicit blob, not a missing file.

All mutations serialize in StateStore. Write a unique temporary file, sync the file,
rename, then sync its directory (`sync -f`). Blob publication precedes envelope;
envelope publication+directory sync is the durable checkpoint acknowledgment.
Lifecycle creation/replacement/tombstone uses the same durable protocol and fails
closed. Orphan blobs may remain; they are never independent recovery candidates.
Process incarnation and store recovery token fence saves in memory; lifecycle
generation fences disk recovery. State revisions are owned by the live agent.
A store restart marks live named agents recovering and requests asynchronous coherent
resaves; it never synchronously calls an agent or replaces live state with older disk.

Legacy migration requires matching name/id and bindings embedded in the same metadata
object. Unversioned split `.bindings` files cannot establish identity/revision coherence;
retain them degraded/unavailable, never infer empty or combine newest components.
Lifecycle authority retains retired logical IDs so predecessor registration cannot resurrect
a replaced name, even after the successor has stopped.
Retain legacy bytes. No legacy reload after authority is published. Corrupt authority
prevents registration. Envelope and blob must match exact active lifecycle identity.

Allowed restoration: preserve the entire latest state directory (including tombstones,
blobs, envelopes and authority), restart compatible v1 code in a disposable copy,
re-register/resave live agents or restore only complete committed dead-agent pairs.
Pre-v1 code downgrade is forbidden. A failed checkpoint can leave newer memory-only
state; simultaneous loss of agent/store/node can lose it. Deployment requires parent
bounded registration/resave of live agents; absent proof, block deployment rather than
restart this shared node. Arbitrary eval effects are not transactional.

### Missing lifecycle authority quarantine (R1-F2)
If lifecycle-v1.term is missing while v1 envelopes, binding blobs or authority temporary remnants remain, startup is degraded. No legacy import, registration or checkpoint is allowed and original bytes remain untouched. Repair requires the preserved latest coherent whole authority/checkpoint directory using compatible v1 code; do not infer tombstones/generations from surviving active envelopes or remigrate legacy predecessors. Loss of every initialization artifact cannot be distinguished from a genuinely fresh directory; external backups/operational authority must resolve that case.

During live Store recovery, hidden metadata/binding rows are noncurrent, but restored last-durable revision evidence is retained in the recovering acknowledgment and any subsequent memory_only acknowledgment (R1-F3).

### Recovery transition invariants (R2/R3 hostile review)

Lifecycle authority (active ID/generation or tombstone/retired ID), not ETS row visibility, controls identity. A hidden live recovery row is not a fresh identity. Current process ownership is retained by monitored watched pid until that pid is actually dead. Caller must match token pid; replacement tokens fence old incarnations and Store epochs. Recovery never manufactures an empty pair.

| Transition / entry | Required behavior |
|---|---|
| Store restart with live actor | Hide stale metadata/bindings; retain last-durable acknowledgment; monitor original actor; asynchronous full resave only. |
| Original live actor registers current epoch | Same watched pid may register and checkpoint its current full map; no synchronous Store-to-actor call. |
| Foreign same-name caller during recovery | Reject same-ID and replacement-ID registration and watch reassignment while incumbent watched pid lives, regardless of epoch knowledge. |
| Actor dies before resave; supervisor init registers | Restore only that dead actor's coherent disk pair under current active lifecycle, then register a new incarnation. Other live recovering rows remain hidden. |
| Supervisor dies; ordinary application revival | DOWN restores dead resaver's pair. Store.all is a serialized reconciliation barrier that checks actual pid liveness before returning rows, so revival does not depend on DOWN mailbox ordering. No forced Store restart. |
| Delete/recreate during recovery | Tombstone and lifecycle transition prevail; recovery set/registration are cleared on delete; old generation/retired ID cannot reload or checkpoint. |
| Missing/corrupt selected pair | Keep unavailable, never use orphan/newest blob or legacy predecessor; no invented empty binding. |
| Missing/corrupt lifecycle authority | Degrade/quarantine; no identity reconstruction or legacy reimport with prior v1 artifacts. |

Dead-resaver disk restoration is scoped to one name and validates ID, lifecycle generation, positive revision, metadata identity, exact referenced digest-bound blob and explicit kept/dropped contents. It does not rewrite disk or discard newer authority. A registration/read scan can precede DOWN; Process.alive? on the retained watched pid determines eligibility. Later DOWN may record predecessor exit but cannot undo the new incarnation registration or overwrite a live resave. Complete checkpoint revision/token checks remain required after restoration.

Initialization distinction: the production `NanoAgent.init/1` registration has no recovery epoch and no existing live map; lazy live `save/1` always supplies current epoch. A named pid inventoried immediately before init may therefore restore its current same-ID coherent pair when it is exactly the monitored incumbent, whereas the epoch-bearing live resave never reloads disk over its map. The scheduling adapter in fixtures blocks after actual Nano.Names registration immediately before actual NanoAgent.init, not an uninstrumented race claim. Identity mismatch/foreign pid, corrupt pair, tombstone and retired generation still refuse recovery.

Compatibility diagnostic watch replacement retains the attached predecessor monitor and waits at most5seconds for exact DOWN even when the predecessor is alive when replacement queues. This bounded wait can stall Store callbacks for a genuinely live diagnostic replacement; it is not lifecycle registration authorization. Recovering live incumbent foreign watch replacement is rejected before this wait. An unreceived dead predecessor reason may become unknown only after bound, never silently nil through an early demonitor race.

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

# Adjacent U05 foundation defect found during U06 restoration

Parent explicitly approved this narrow PR-16.2 expansion, event35. The original fresh-VM
restoration-final artifact had correct raw blob SHA `e4380df...`, but StateStore decoded
its small map and reserialized it in a new atom-table layout to hash `e4bcca...`. It
incorrectly rejected the coherent pair as unavailable, so no agent revived. This is an
actual U05 reader defect, not permission to discard/reseed older state or a U06 test pass.
Failing diagnostic log: background/700f37bb1e7269f99884864b/output.log in this dispatch's
private run root. Original bytes were retained; only later compatible restoration writes
advanced the coherent envelope normally.

Repair `a05223b471c324c7080de2b7664069c62943cfeb`: verify SHA of exact immutable raw binding
blob bytes BEFORE decoding. Retain envelope schema/name/ID/revision/generation and blob
schema/ID/generation/binding checks. No disk-schema migration or blob replacement. Related
writer hash sites serialize the same map in the same VM; the defective reader was the
only reserialization validation. Downgrade is still forbidden under the U06 protocol.

`test/flywheel/u06/binding_digest.exs` runs five serial disposable VMs against private
copies of this dispatch's seeded restoration state, deliberately writing an equivalent
valid ETF map in a different pair order. New reader restores valid bytes unchanged;
corrupt raw bytes, wrong blob ID/generation and envelope revision0 stay unavailable.
Log2d2d10961fdde75815b04c38 passes all five cases. Production boundary is startup
StateStore.coherent_disk -> NanoAgent.revive -> recovered durable binding23.
The actual original valid artifact now revives with all pending/image/evidence/binding
checks (log73e6efeddbecc5ddc7159cd2). Parent alone reviews and activates this repair.

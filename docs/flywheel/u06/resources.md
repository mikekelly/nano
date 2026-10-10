# Bounded pending admission and saturation

Envelope-v1 adds `admission_version=1`, `pending_backlog` v1 `{read_index,
write_index,count,bytes}`, and optional `pending_unavailable` identity range.
Live pending RAM admission target is 256 items / 1 MiB estimated text+image-reference
bytes. Excess is synchronously synced to immutable `spill_dir/<id>/pending-v1/<index>.term`;
active queue limits: 10,000 records / 64 MiB, each record at most 1 MiB. The record
contains text, immutable image references and relevant exact-evidence metadata. Pointer
advancement and delivered prefix live in the same coherent envelope. Reads do not delete
records; restart restores pointer and pending prefix before requesting the provider.
Old text-only live queues are staged and admitted in order; old unattributed image
bundles remain atomic, never guessed per-event attribution. A legacy bundle above the
RAM target is staged as one exact-text file retaining every original wrapper/order,
with an ordered event-ID manifest and its original images in one grouped pending item.
Migration runs before new unhalt/restart/event notices, preventing a later notice from
turning an ordinary old backlog into an unfit atomically admitted queue. Transcript/tool
pairs remain. Oversized/unavailable legacy bundles retain original state behind an
explicit recovery fence rather than partially spilling or associating images speculatively.

At publication failure, malformed/missing queue or finite capacity exhaustion, provider
requests are fenced by `pending_unavailable`. New arrivals are logged (event IDs and exact
bounded event/spill content) and aggregated into an undelivered identity range, not added
to an unbounded RAM list or silently called delivered/read/answered. Unhalt alone does
not clear this fence. Operator recovery preserves the envelope/queue files/logs and
reconstructs the logged undelivered range under enlarged/repaired private storage before
clearing the flag. Do not retry an uncertain index in place or discard newer authority.

Erlang mailbox sends have no upstream acceptance/backpressure protocol. This does not
promise unlimited reliable delivery against infinite senders or disk exhaustion. The
mailbox and original event logs/spill publication remain subject to OS/BEAM/storage limits;
log failure cannot fabricate durable receipt. Runtime queue bounds are not a total disk
quota: immutable historical records/evidence/logs require operator archival and deliberate
cleanup, never deletion merely because a prefix was admitted or a name was retired.

Actual isolated 1,100-event burst test took 9.6 seconds (seed17, logdb9aff...); 844 records
required synced publication after first256 RAM items. This is a measured single-run
callback latency cost, not a worst-case guarantee. Publication can delay responsiveness;
60-second test system-message timeout permits observing durability, not hiding loss.

Active exact-evidence validation is bounded to 4,096 handles /32MiB total referenced
bytes, each at most8MiB, and stops
at first error with one actionable diagnostic. Pruning retains handles referenced by
pending/current transcript/checkpoint only; archived files and logs stay immutable.
No claim of asynchronous publication, security sandbox or automatic quota management.

# R2 raw FIFO integrity repair

Fresh reviewer reproduced a real silent corruption at29e8a6a: after257 actual halted
mailbox events, replace same-size valid ETF spool text `original` with `tampered`, then
unhalt. The second actual provider request received tampered text; v1 only validated
size/ETF shape. Reviewer proof `/data/altair-flywheel/runs/u06-review-r2/queue_corruption.exs`
and jobs/965a96b6c67d0ed15f70da73/output.log were explicitly reported, not a passing
integrity test. Parent requested coherent authority binding in event55.

v2 active queue authority lives in the U05 coherent envelope: agent ID, actual registered
lifecycle generation, ordered indices/count/bytes, and index->expected raw SHA256/size.
The independently retained expected digest is NOT read from a replaceable spool record.
Each immutable record also states ID/generation/index; reader checks raw digest before
ETF decoding and these associations before admission. Removing a prefix publishes its
new pointer/remaining manifest coherently with delivered transcript. Files remain intact;
uncertain publication/collision cannot overwrite a newer/orphaned record.

v1 has no independently bound digest and is explicitly unavailable, not silently
upgraded from its current files. Preserve it and original event/spill logs for deliberate
operator reconstruction. v2 compatible roll-forward is the allowed restoration; never
load v1 readers that ignore the manifest or reset authority to an older envelope.

Production regression starts257 real mailbox events, changes same-size valid record
bytes, admits only the known-good RAM prefix, then detects unavailable FIFO before a
second provider request. Restart/unhalt retain original expected digest/index and fence,
not an invented delivery/read/answer. Helper tests additionally reject wrong ID/lifecycle/
index, legacy v1, collisions, missing files, finite saturation and uncertain directory sync.
Fresh-VM restoration checks original manifest entries and raw record identities survive.
These are deterministic disposable fixtures, not a filesystem security boundary or
unlimited mailbox/storage reliability guarantee; parent alone integrates and closes.

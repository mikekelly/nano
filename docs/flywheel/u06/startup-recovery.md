# Adjacent U05 startup-read fence

An additional audited exact29e8a6a full run passed615/616, with U05 recovery_test.exs547
failing its immediate Store.get==nil precondition after store restart, BEFORE deletion or
corruption stimulus. This did not prove tombstone resurrection; the isolated targeted
rerun passed (766a9d...). It exposed a real startup publication window, not a test to weaken:
init restored coherent disk rows and published availability ready, then only its resave
continuation cleared rows/bindings for still-live owners. Direct ETS reads can run before
that continuation. Parent explicitly approved narrow repair in event54.

A deterministic disposable VM driver `test/flywheel/u06/startup_fence.exs` instruments only
a scheduling pause after actual readiness publication in exact dispatch-base source and
candidate source. No recovery/read semantics are changed by the pause. Baseline publicly
exposes durable stale live-owner metadata/binding71. Fixed init synchronously fences live
owners before ready, so reads return nil/unavailable/recovering and old tokens are rejected.
Cold/dead owner retains coherent metadata/binding72, and after release/resave the live
original ID/binding71 become durable again. Loge98851a3bba27b10e0c59978 passes the baseline
DEFECT assertion first and then the fixed assertions. This is source-instrumented scheduling
proof in private VMs only, not live-node fault evidence or an independent review claim.

Repair factors the existing continuation recovery into `recover_live(s,resave?)` and calls
it synchronously before readiness with false (fence/watch only); continuation calls true
to discover late/preinit owners and request resaves. Existing initialization registration,
monitor/generation/lifecycle/tombstone and cold coherent-pair checks remain unchanged.
No state/disk-schema changes, no rollback of generations or binding evidence. Allowed
restoration remains compatible roll-forward with original envelope/blob authority kept.
The original failed run remains reported; a later pass must not erase its provenance.
Parent alone reviews/integrates/loads this separate immutable foundation delta.

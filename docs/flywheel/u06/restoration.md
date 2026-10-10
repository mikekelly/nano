# U06 admission/restoration protocol

## Readable formats and authority

Old: U05 coherent envelope-v1 metadata with string `pending`, flat `pending_images`,
transcript and optional checkpoint `{base, attempt, reason}`. Known missing admission
fields are migrated by compatible readers: text-only queues become attributed ordered
items, oversized old text is staged, legacy flat image bundles stay atomic; transcript
and existing tool-call/result pairs retain their identities.

New: the same envelope-v1 (no StateStore disk-schema change), with additive metadata:
`admission_evidence` SHA-256 keyed v1 handles (`path`, `bytes`, `position`),
`image_deliveries` keyed by exact event text (immutable canonical image references),
`admission_split`, `admission_compactions`, `admission_version`, optional grouped
`pending_item_ids`, bounded `pending_backlog` v2 identity+raw-digest manifest/pointer and explicit `pending_unavailable`
recovery range (see resources.md), and checkpoint `tail` plus original measured
context fields. Handles point to immutable UTF-8 files, at most 8 MiB, under configured
`spill_dir/<agent-id>/admission/<sha256>.txt`. Position zero denotes staged/not read;
explicit agent file paging does not fabricate harness read/answered acknowledgment.

The coherent envelope remains per-agent authority. Files/logs/image store are evidence,
not instructions. The checkpoint prefix ends at complete tool groups, and its suffix is
included in the same replacement envelope publication as the checkpoint. Restart drops
the in-flight checkpoint request note and restores the complete prefix/suffix before
resuming admission. Missing, malformed, oversized or hash-mismatched evidence halts
before provider calls and retains pending state.

## Allowed restoration

Preserve the latest coherent envelope, binding blob, lifecycle authority/tombstones,
exact-evidence files and immutable image store. Run compatible U05+U06 readers against
that state. Restart/reconcile from that preserved state; do not substitute an older
checkpoint, reset newer authority, or infer success from a memory-only acknowledgment.
Repair missing/corrupt evidence from preserved storage before unhalting. If irreducible
system/pinned input is unfit, reduce it or enlarge the window; unhalt alone is not repair.
Downgrade to pre-admission NanoAgent is forbidden: it cannot honor the new admission and
pending suffix contract. Source restoration is roll-forward only.

Compaction and agent deletion do not garbage-collect staged files. Retain/archive evidence
with logs before separate operator cleanup; deleting a name is not evidence acknowledgment.
Text and image references are not pixels retained in a provider request. Compaction's
preamble states that absent image parts no longer provide pixels in current context.

## Disposable rehearsal

`test/flywheel/u06/restoration.exs` runs as two SERIAL `mix run --no-start` VMs, with
this dispatch's explicit private runtime subroot audited before application startup.
Seed starts the real NanoAgent/StateStore/Image paths, halts before provider calls,
mutates302 pending items including a multibyte staged event and disk FIFO, one immutable image ref,
and binding `durable=23`, and observes durable publication. Restore boots new code in a
fresh VM against that preserved disposable state and checks pending identity/order,
handle position/hash/files, bindings and readable image bytes. No transcript pixels or
provider request are asserted. Process-level checkpoint-restart and missing-file repair
regressions additionally exercise actual NanoAgent callbacks.

Parent alone reviews/integrates/loads compatible modules and performs bounded live checks.
This record does not authorize shared-node restart or claim live deployment.

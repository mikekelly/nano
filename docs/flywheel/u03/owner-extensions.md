# Narrow owner amendments (v1)

Parent decision `u03-question-1` / 2026-10-10 authorizes only these amendments:

* `add_units(server, authority, [new_descriptions], provenance)` -> new IDs. Only new
  IDs; validates combined dependency/leaf/scope graph atomically while retaining all
  existing descriptions, claims, history and stage evidence. Corrective descriptions
  have unique terminal requirement leaves and may retain explicit `corrects_unit` /
  `original_requirement` / `finding_id` trace fields. No general graph editing.
* `reopen(server, authority, id, reason, evidence)` -> `%{unit:, claim_generation:,
  reservation:}`. Rejects if any transitive descendant is claimed, reserved or done.
  Owner must quiesce those descendants explicitly or append a traced corrective unit;
  never silently rewinds live work. Records prior done/stages in immutable history,
  fences current worker generation, retains proposal and any reservation under a new
  integration generation. Applicable stage gates clear; original blockers/resolutions
  remain. Reopening does not free reservation: adopt or abandon explicitly as needed.
* `resolve_external(server, authority, id, resolution)` -> `:resolved`. Requires
  `%{blocker: <exact original blocker>, outcome: :verified_resolved,
  verification: <nonempty bounded closure proof>, owner_decision: :resolve,
  verified_at: <ISO8601 datetime>}`. Persists attribution and original blocker unchanged.
  Unknown/observed/fixture-only real-world outcomes must not be submitted as verified
  resolution. Fixture tests exercise gates, never close real external obligations.

* `abandon(server, authority, id, proposal_id, reason)` -> `:abandoned`. Current owner
  can reject an existing proposal even after restart or loss of its Git worktree; does
  not require unsafe adoption of an invalid proposal. Advances integration/worker
  generations, persists original proposal/reservation/stages in attributed history,
  releases reservation only after durability. Blockers/resolutions remain. Acceptance
  and landing still always validate the actual Git diff.

`record_stage` cannot modify a done unit (`:reopen_required`); append attributed finding
history then reopen safely or add traced correction. External stage blockers accumulate;
empty stage lists cannot silently remove them. Dependencies rechecked at claim, submission,
acceptance/land and close. See api.md for generation/recovery/durability contract.

# Credential intent v1 (review protocol)

Protected authority: `<safety_dir>/credentials/intent-v1.json`, outside checkout.
Primary diagnostic mirror: `<state_dir>/credential-intent-v1.json` (never a source
of enablement if protected authority is absent). Legacy credential files remain
`settings.json` and `chatgpt_auth.json` in state_dir and safety_dir/credentials.
Protected JSON schema 1 has a monotonic revision and per-credential entries
`enabled(version, generation, value)` or `invalidated(version)`. ChatGPT is one
credential; each secret Settings key is separate. Values are private credentials,
never logged. Refresh increments version but retains generation; explicit login/set
creates a newer generation. An invalidation has no value. Protected records are the
only winner, never a timestamp/mtime or an older backup. Mirrors cannot overrule them.

All BEAM lifecycle operations serialize under one node-local lock plus an OS
flock on the stable `credentials/intent-v1.lock` inode shared with the Python
watchdog. Never unlink/replace that inode. BEAM's bounded util-linux flock port
holder releases on caller/VM death (stdin EOF); missing flock or timeout fails
closed. Python skips busy writers and holds this lock across the coherent
intent/primary snapshot, pre-kill decision, child stop and repair. A post-kill
recheck alone is insufficient: a completed refresh must not kill a healthy child.
The watchdog never mutates intent.
Offline installer/reconciliation requires all credential writers stopped. This is
cooperative serialization, not a distributed lock or filesystem sandbox.

A durable `credentials/intent-blocked-v1.json` barrier is written before mutation.
Protected intent is then atomically written (0600 temp, file sync, rename, directory
sync) before backup/primary materialization/removal and the primary mirror. The
barrier is removed and directory synced only after all materializations succeed.
Any uncertain write/rename or crash leaves restoration and rotation blocked until
explicit maintenance reconciliation. No failed operation claims durable logout.
Authoritative invalidation, once committed, wins even if old primary/copies remain.
Reconciliation materializes the latest coherent protected state, never downgrades it.

Legacy migration inventories primary and backup without printing contents; preserves
originals as private evidence. Only reconciled current primary credentials may become
enabled. Missing primary with a credential backup, or conflicting primary/backup,
blocks migration for maintenance. Legacy absence never authorizes stale restoration.
`provision_new_credentials(:new_installation)` requires explicit operator attestation
that no prior protected authority ever existed and refuses any legacy files/history.
`reconcile_legacy_credentials(:legacy_installation)` is a separate offline attestation
for never-protected legacy data. Neither is lost-authority repair. The permanent
`credentials/intent-required-v1` marker forbids reprovisioning even if authority and
mirror disappear. Existing protected state uses `reconcile_credentials/0`; lost
authority requires restoration of the newest coherent authority from preserved
protected evidence, never rebuilding it from credentials/mirror. Missing/unreadable protected
authority blocks lifecycle changes with maintenance error, even when primary exists.

Fallback code must implement schema 1 and honor the barrier and invalidations; older
code is ineligible. Allowed restoration is a compatible v1 roll-forward restart with
latest protected intent and evidence preserved, then offline reconciliation if a
barrier exists. Never replace authority with an older source checkpoint/mirror.
Live rollout requires parent-owned serialization/migration or external maintenance;
no live credentials are changed by the worker.

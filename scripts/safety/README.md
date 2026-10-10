# Durable safety net

Entry points: `Nano.Ops.safety/0` (also `GET /api/safety`), `Nano.Safety`,
`runner.py` and `install.py`. This code does **not** install itself or start
anything on module load. Only the integration owner installs it after review.

## Reviewed installation plan

1. Merge and compile the safety changes, including credential persistence hooks,
   model success hook and HTTP routes. Do not run the installer from an agent's
   worktree against live data. Verify `python3` is in the container image (this
   machine has it; the operators must retain it on recreation).
2. Approve maintenance quiescence first: all credential writers must be stopped
   so bootstrap cannot race a single-use token refresh. Either stop the node, or
   have the integration owner synchronously `:sys.suspend/1` Nano.Settings and
   Nano.ChatGPT.Auth, run installation, and resume both in a `try/after` block
   in the same eval. Suspension waits for current callbacks, including refresh,
   to finish. Prevent other direct file writers during this brief window. From the merged
   checkout run `python3 scripts/safety/install.py --offline --app /app
   --root /data/safety --state-dir /data/state --port 4000`. It copies the runner
   outside the checkout and initializes private credential copies, but does not
   start it. Review `/data/safety/config.json`, root-owned, mode 0600. Root is 0700.
   The command reads the cookie at execution, never stores its value in config.
3. Approve a maintenance restart. The tiny `bin/start` execs the durable runner;
   the runner captures evidence and launches /app with the same state/log volumes.
   On fallback only, a fresh writable runtime copy of immutable known-good evidence
   is launched. /app remains the authoritative editable checkout.
   `GET /api/safety` must show `protected: true` after a health probe. A real model
   success, followed by a probe, records `good.json`. Until then there is **no
   known-good fallback**, visibly reported as null. No synthetic model call is
   made, and merely compiling does not qualify.
4. Ensure the Docker restart policy is appropriate, and retain both /app and /data.
   Do not claim protection against removal of volumes, host failure, corrupted
   OS/dependencies, a deleted Python interpreter, a broken start shim or removed
   durable runner. Container PID 1/restart/recreation testing is still required
   by the operators: the tests here run isolated OS process trees, not Docker.

## Behaviour and evidence

Every boot captures source (including uncommitted/untracked files and dependencies,
excluding `.git`, `_build`, `tmp`); a source digest must still match that capture when a model success promotes it.
Loaded Nano modules must also match their compiled BEAM files and cwd source
location; external hot-loads do not attest a boot. The digest excludes dependency
contents (which are captured, but dependency-change attestation is not certified). Normal cwd remains /app.
Fallback cwd is an explicitly visible private runtime copy, never the evidence
snapshot itself; edit authoritative /app and use absolute paths for git/delegation
while in fallback. Arbitrary root agents can still defeat these checks. No rollback writes into /app. Failed source,
private boot logs and replaced invalid credentials remain under `/data/safety`.
A failed boot or unresponsive probe kills the entire child OS process group and
boots the latest served copy. The default watchdog probes every 5 seconds with a
2-second HTTP deadline, kills after 60 seconds without a response (120 seconds
initial compile/boot grace). PID matching prevents an unrelated healthy HTTP
server from masking the managed node's failure. Only one runner may own a root.

Three attempts are permitted, spaced by 10 seconds, persisted across container
restarts. Five minutes of sustained served health resets the brake. On exhaustion
no child is launched; exit is zero to avoid an on-failure loop. Docker `always`
may still relaunch the runner, but the persisted brake refuses every further child.
Private `notices.jsonl`, secret-free stderr and `/api/safety` describe each recovery,
when it happened, its evidence path and action. Stale status is not protected.

Settings and refreshed ChatGPT tokens are synchronously copied *before* publishing
new values (including directory fsync). This closes the ordinary polling window for single-use refresh tokens.
The independent watcher detects missing, empty or invalid JSON files, stops the
child to quiesce publishers, rechecks and restores only from valid copies, then
restarts to reload them. Backup renames are directory-fsynced before publishing. A valid newer file is left
alone; invalid replaced files are preserved mode 0600. All copies and boot logs
are private; none of their content is included in notices/status. There is still
an unavoidable crash window between upstream token rotation and receiving/writing
the result, and simultaneous arbitrary external writers can race restoration.
External writers must use the same write-through discipline; valid external
updates are not polled into backups because that can overwrite newer refreshes.
Lost individual provider/opaque secret settings are merged back from the protected
copy while preserving newer nonempty values and unrelated settings. Intentional
logout/deletion is therefore a maintenance operation: disable, stop writers, remove
the matching protected copy (or edit its secret names), then change the originals
and re-enable. Disabling alone does not erase protected recovery copies.

## Controls

Create `/data/safety/disabled` to stop watchdog actions (a running child remains).
At next start disabled mode performs a direct, unprotected boot. Remove the file
and restart to enable. Status is explicitly disabled; `protected` is false.
For a manual brake reset, stop the runner/container, preserve `budget.json` as
evidence and replace it with `{"attempts":0}` mode 0600. Do not reset unattended.
To retry the edited checkout after fallback, reset the brake during maintenance;
otherwise the persisted fallback selection remains in effect.

The shim falls back to the original start command only when no durable runner
exists. This keeps initial installation optional, not quietly auto-enabled.
Do not edit or replace installed config while running. Durable runner upgrades
require review, an atomic replacement, and maintenance restart. Snapshots/evidence
are deliberately not automatically deleted; monitor volume capacity and archive
old evidence securely. Disk exhaustion fails closed with a visible watchdog error.

## Verification

`python3 -m unittest discover -s scripts/safety -p 'test_*.py'` runs destructive
faults only in fresh disposable directories. Elixir tests run with `MIX_ENV=test`
and independent test state. No test uses live credentials or a real provider.
Run the real disposable BEAM copy test explicitly with
`NANO_SAFETY_BEAM_TEST=1 python3 -m unittest discover -s scripts/safety -p test_beam.py -v`.
It copies this checkout (including deps), starts its own BEAM and data directories,
uses local synthetic model/OAuth servers, SIGSTOPs only that BEAM, corrupts only
that copy's source and credentials, and verifies restored saved agents.

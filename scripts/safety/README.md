# Durable safety net

Entry points: `Nano.Ops.safety/0` (also `GET /api/safety`), `Nano.Safety`,
`runner.py` and `install.py`. This code does **not** install itself or start
anything on module load. Only the integration owner installs it after review.

## Reviewed installation plan

1. Merge and compile the safety changes, including credential persistence hooks,
   model success hook and HTTP routes. Do not run the installer from an agent's
   worktree against live data. Verify `python3`, `elixir`, and util-linux `flock` are available at every
   container start. The image must explicitly include Python and util-linux. Missing
   flock or bounded acquisition timeout fails credential operations closed. The
   BEAM port and Python share the stable `credentials/intent-v1.lock` inode; never
   unlink/replace it, including during maintenance or atomic publication.
2. Approve maintenance quiescence first: all credential writers must be stopped
   so bootstrap cannot race a single-use token refresh. Either stop the node, or
   have the integration owner synchronously `:sys.suspend/1` Nano.Settings and
   Nano.ChatGPT.Auth, run installation, and resume both in a `try/after` block
   in the same eval. Suspension waits for current callbacks, including refresh,
   to finish. Prevent other direct file writers during this brief window. From the merged
   checkout run `python3 scripts/safety/install.py --offline --legacy-installation --app /app
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
excluding `.git`, `_build`, `tmp`); installed config records `deps_path` from
`MIX_DEPS_PATH` (the image uses /opt/nano/deps) and captures those dependency
sources inside each evidence snapshot. Both normal and fallback launches override
MIX_DEPS_PATH to a private writable /data dependency copy, never the original /opt
or immutable evidence. Fallback thus needs no intact /app or /opt dependency source; a source digest must still match that capture when a model success promotes it.
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

Credential intent v1 is protected outside checkout in
`<safety_dir>/credentials/intent-v1.json`; the state-directory
`credential-intent-v1.json` is only a mirror. Per-credential enabled versions contain
private values and login/set generations; invalidations contain no value and always
win over older primary/backup/fallback copies. Refresh is generation-conditional.
Intent commits before primary removal, and refresh commits before publication.
A durable mutation barrier blocks recovery and rotation after uncertain writes/crashes
until compatible offline reconciliation. `intent-required-v1` permanently records
that this installation used protected history; deleting authority is not a reset.

Explicit logout/Settings removal now persist invalidation (or return a truthful
maintenance error), not a silent backup merge. Accidental deletion of enabled
credentials still recovers from authoritative enabled values; unrelated valid
settings survive repair. The watcher stops publishers, rereads protected intent and
barrier, then repairs; stale copies alone never enable anything. Private original
legacy bytes and replaced damaged files remain evidence. The upstream rotation
window before receipt is unavoidable; arbitrary external writers remain unsupported.

Provision brand-new empty installations with explicit `--new-installation` instead
of `--legacy-installation`. Existing installations that never used v1 require
explicit offline legacy reconciliation; missing/conflicting legacy copies block it.
For an existing safety installation, reviewed v1 BEAM maintenance API
`Nano.Safety.reconcile_legacy_credentials(:legacy_installation)` preserves originals;
`Nano.Safety.reconcile_credentials/0` resumes *existing* coherent authority after a
barrier. Neither API reconstructs lost invalidation history. Lost authority needs
roll-forward repair from the newest preserved protected authority, never its mirror.
Do not call these against live data from an unreviewed worker. The sole integration
owner must quiesce both old Auth/Settings owners and all external writers, update
both BEAM lifecycle code and outside-checkout runner, migrate, then resume compatible
owners using the rehearsed upgrade. A running old Python watchdog cannot be made
safe by merely loading BEAM modules: external maintenance is required if it cannot
be safely quiesced/replaced. Legacy runner/source fallbacks unable to honor intent
are ineligible, including disabled-mode direct boot. Never discard newer authority,
barriers, required marker or evidence for a source downgrade.

Full protocol and disposable restoration/upgrade drivers:
[`docs/flywheel/u07/protocol.md`](../../docs/flywheel/u07/protocol.md),
`test/flywheel/u07/{run,hot_upgrade}.exs`. Host activation remains operator-owned.

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

## Activation and rollback on this node

Read-only inspection found PID 1 is `docker-init -- bin/start`, with the current
BEAM directly beneath it, not beneath a safety runner. Installing does not adopt
that BEAM. `pending_restart` means installed but unprotected. Stopping the current
BEAM ends the container; this node has no Docker CLI/engine socket with which to
verify or trigger host restart policy. Do not restart from inside an eval merely
to test installation. Finish/idle engineers and background work, verify saved
agent names/states are on disk, then have the container owner perform a reviewed
restart with verified policy. The seed restores agents by saved stable names;
nonpersistent OS subprocesses cannot survive container exit.

The runner always overrides `MIX_BUILD_ROOT` to `/data/safety/build`, never the
shared image `/opt/nano/_build`, and isolates dependency compilation as above.
Startup command defaults to named node `nano@127.0.0.1`, reads NODE_COOKIE or the
image's `/opt/nano/cookie` without storing its value, uses production MIX_ENV and
configured PORT. Retain the existing LISTEN_IP/log/spill environment as appropriate.
Do not log raw BEAM process argv: it contains the node cookie.

For rollback without deleting evidence, stop during maintenance and create the
`disabled` marker to select direct unprotected boot. If the durable runner/config
itself is broken, rename `runner.py` to a dated private evidence file (do not
remove it); the tiny shim then uses its original Elixir command. Preserve all
other safety/state files. This rollback explicitly forfeits protection, and
requires an intact editable checkout to boot. Never reset the recovery brake or
remove a known-good snapshot as part of an unattended rollback.

## Verification

`python3 -m unittest discover -s scripts/safety -p 'test_*.py'` runs destructive
faults only in fresh disposable directories. Elixir tests run with `MIX_ENV=test`
and independent test state. No test uses live credentials or a real provider.
Run the real disposable BEAM copy test explicitly with
`NANO_SAFETY_BEAM_TEST=1 python3 -m unittest discover -s scripts/safety -p test_beam.py -v`.
It copies this checkout (including deps), starts its own BEAM and data directories,
uses local synthetic model/OAuth servers, SIGSTOPs only that BEAM, corrupts only
that copy's source and credentials, and verifies restored saved agents.

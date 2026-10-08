# SafetyNet — external recovery, opt-in

Entry point: `SafetyNet.status/0`. This code is **not activated by compilation**.
`bin/start` is the only app-owned launcher: when installed it execs the runtime under
`/data/safety-net/runtime`; otherwise it warns and starts the original node. The runtime
uses Python 3's standard library and survives container recreation with the data volume.
Do not point an experimental supervisor at the live node. It only signals process groups
it creates, never discovers or kills an existing BEAM.

## What it does

* Before starting, privately snapshots source, uncommitted/untracked files and dependencies.
  Excludes `.git`, `_build`, `tmp`, `data`, `archive`, `.claude`, `node_modules`, crash dumps
  and Python caches. Dependencies come from install-time `MIX_DEPS_PATH` (or `--deps-dir`,
  otherwise app/deps), and are materialized into the private snapshot even when the
  checkout has no deps directory. Each source/dependency fingerprint is capped at 50,000
  files, 512 MiB and 30 seconds, streaming 1 MiB chunks. Runs the primary from `/app`;
  capture hashes before/copy/after must
  agree. `safety-snapshot.json` records git revision and content/executable-mode SHA256
  including dirty work. Promotion rechecks both source and candidate digest. `/app` is
  **never reset**. Fallback runs a separate disposable working copy of the preserved good
  snapshot, so ordinary relative edits cannot alter the baseline. Its path is in status.
  Edits while boot is qualifying refuse promotion (without killing a healthy node).
  Changes to source take effect on a subsequent start, or an explicit agent code reload.
* The installed `heartbeat.exs`, loaded before Mix, checks both `Nano.Supervisor` and the
  endpoint process every two seconds. A stalled heartbeat after readiness kills the whole
  child process group after 60 seconds; boot has a 120-second grace. Probe calls can block
  at most five seconds. Detection depends on the external supervisor being scheduled.
* A snapshot becomes known-good only after heartbeat readiness, a 30-second settling
  interval, **and a successful-model attestation in the same nonce-tagged boot session**.
  Compilation and endpoint readiness alone never qualify. `SafetyNet.served/0` is the
  success-path integration hook; do not call it merely because the process started.
* On boot failure, timeout or credential restoration, kills its own child and starts the
  known-good snapshot working copy, with fresh per-attempt build and local dependencies.
  The failed copy stays on disk as evidence. After recording fallback/budget state and
  backoff, the supervisor exits 75: Docker's restart policy restarts the launcher and also
  clears detached OS descendants. Process tests use `restart_via_container=false` for local
  retry plus a separate launcher re-execution test of production handoff. Install sets true.
* Three attempts are recorded durably across supervisor/container restarts, with a
  ten-second backoff. Promotion of a new served candidate clears the count once; fallback
  boots do not. No known-good copy means **park**, not guess at a git revision. Exhaustion
  keeps a quiet process alive with no node, preventing Docker restart storms. Reset is
  explicit after examination. Runtime errors also fail closed and park, reporting type
  to stderr and best-effort `runtime_failed` metadata (disk may be unavailable). It retains
  singleton ownership while parked, so reset or a second supervisor cannot race it.
* Valid, nonempty JSON credentials are backed up atomically with `fsync`, root-only
  directory (0700), files (0600). Missing, empty or malformed files are restored; malformed
  bytes are preserved privately under `evidence/`. A newer valid file is never rolled back.
  Polling runs every 250 ms. A restoration while running triggers a child restart so
  Settings/Auth actually reload the restored files, rather than retaining broken memory.
* Events with UTC time, reason, action and evidence path go to stderr (Docker logs),
  `/data/safety-net/reports.jsonl`, and `status.json`. On application readiness the installed
  heartbeat notifies revived/new agents with the last five event lines (bounded to 8 KiB).
  `SafetyNet.status/0`
  reads only metadata. `monitor.json` records owner/child PIDs, session and last heartbeat
  observation time. Liveness is explicitly unknown; a stale file is not proof of health.

## Integrator hooks (required for the strong guarantees)

The top-level integrator owns the model success hook; the two seed credential writers
and removal hooks are included in this change:

1. `SafetyNet.served()` in `NanoAgent` after a successful model response, not on transport
   failure, parse failure, retries, or merely beginning a request.
2. `Nano.Settings` and `Nano.ChatGPT.Auth`'s atomic write helpers now call
   `SafetyNet.write_credential(path(), Jason.encode!(values))`. Their error handling is
   preserved: new values are not published if persistence fails. Auth logout/permanent
   rejection calls `forget_credential/1`, durably tombstoning before deleting backup and
   primary; polling cannot resurrect revoked or intentionally removed credentials.

The writer is a private atomic write when uninstalled or disabled. Test builds use their
seed-provided unique `test_dir` safety home, never the deployed runtime. Synchronous
installed transactions are bounded by Debian's `timeout 10s` (coreutils), return a redacted
error on failure, preserve private staging evidence and leave any durable pending journal
for replay. An ambiguous writer error requests a monitored reload; Auth drops stale
in-memory tokens/timer rather than refreshing an older generation that could invalidate
the new one. If no monitor is active, a failed transaction may require manual reload;
no immediate live lockup/reload protection is claimed merely from installation. When installed it
stages bytes privately, then invokes installed Python: under the same `flock` as restore,
write and fsync a **write-ahead journal**, then latest backup, then primary, then remove
that journal. Pending generations are replayed before polling the primary: a failed
primary write cannot overwrite the latest rotated backup with old valid bytes. A replay
triggers reload. A conflicting third-party valid write is preserved and parks for review.
Token bytes never enter command arguments, errors or reports. This closes the
poll/deletion window and serializes cooperating writers with recovery. `backup_credentials/0` is useful
for an initial backup but an after-save hook alone does **not** close that window.

This is an operational recovery tool, not a security boundary against root. An arbitrary
noncooperating writer can race the final restore rename, change the runtime or forge the
served nonce. A code reload after boot can make the attestation describe code other than
the snapshot; do not promote a boot with unrecorded live code reloads. For production
initial qualification, run an actual model request before relying on known-good.

## Deployment recipe — review first, no live restart required

Run these only after reviewing the implementation/tests and integrating the hooks. This
work did **not** run the following commands on the live node.

```sh
# From the reviewed checkout. Do NOT run a supervisor manually beside a live BEAM.
python3 safety_net/supervisor.py --home /data/safety-net install \
  --app /app --state-dir /data/state
python3 /data/safety-net/runtime/supervisor.py --home /data/safety-net status
```

Install copies three files (`supervisor.py`, `heartbeat.exs`, `launch`) to private runtime,
backs up valid credentials, and reports `installed / protected=false` with per-file backup
availability. A file never backed up cannot be recovered after deletion. It neither signals
nor watches anything live. It refuses to overwrite an existing installation. It is armed
for the **next ordinary container start** through the reviewed `bin/start`. Until then
lockup protection is absent. Do not confuse an installed runtime with an active watchdog.

For deployment verify Python 3/Elixir/Mix, dependency source availability, disk capacity,
that the app's runtime state directory matches `config.json`, and the external Docker
restart policy. **Exit 75 alone does not restart a container.** Operators must configure
Docker `--restart unless-stopped` (or `on-failure` with suitable retries), or Compose
`restart: unless-stopped`, and persistent mounts for `/app` and `/data`. This container has
no Docker client/socket to inspect or change that policy; installation and status declare
it `external_not_verified` rather than claiming to have enabled it. Retain `/data/safety-net` on the same persistent volume. First supervised boot
must compile dependencies and complete a real model response; check for `known_good` in
reports. Increase boot grace only if measured compilation time demands it. No good
baseline exists before that first qualification. For initial protected baseline without
risking live node, operators can additionally qualify a disposable container with their
own temporary model credentials; no real credentials were copied by these tests.

### Inspect, disable, repair

```elixir
SafetyNet.status()
```

```sh
python3 /data/safety-net/runtime/supervisor.py --home /data/safety-net status
# Suppress credential restoration immediately; next launcher skips watchdog entirely.
touch /data/safety-net/disabled
```

The existing supervisor remains responsible for its child until it exits; disabling is
not an instruction to kill or restart a live node. Reports show disabled state through the
status command. Normal Auth logout/revocation and Settings clearing through the integrated writers use
durable tombstones, so they are not undone. A later nonempty save clears the tombstone.
Direct filesystem deletion/emptying looks accidental and is restored; use disable before
intentional out-of-band cleanup. Remove obsolete backups deliberately while disabled, and
re-enable only after writing new valid credentials. `{}` saved through the Settings API
is intentional clearing; `{}` replacing a file directly is corruption. External tokens
revoked at the provider cannot be repaired from backups. A crash between issuer rotation
and receipt/durable journaling of the new token is intrinsically unrecoverable.

On exhaustion, inspect original `/app`, failed snapshots and private reports. Correct the
source, stop the **parked safety supervisor/container** using the operator's normal process
controls, then (only while supervisor is stopped):

```sh
python3 /data/safety-net/runtime/supervisor.py --home /data/safety-net reset
# Next normal container start tries current /app again, retaining known-good fallback.
```

Reset refuses a held supervisor lock. Never issue reset expecting it to kill a running
node. Updating an installed runtime is intentionally manual: stop its supervisor, retain
old private runtime as evidence, copy reviewed files, then start normally. Editing `/app`
does not silently upgrade the safety code it depends on.

## Reproducible failure evidence

```sh
# All files and processes disposable; no live credentials, ports or model calls.
python3 -m unittest discover -s test/safety_net -p 'test_*.py' -v
MIX_ENV=test mix format --check-formatted lib/safety_net.ex safety_net/heartbeat.exs
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test
```

The Python suite starts real isolated BEAM subprocesses (`+S 2:2`) with private directories.
It tests SIGSTOP -> kill and fallback, invalid Elixir boot -> fallback with evidence,
missing baseline -> parking, persistent budgets, heartbeat without served -> no promotion,
newer valid credentials not overwritten, latest synthetic rotated tokens restored after
unlink, empty settings evidence/mode checks, and restoration while running -> reload.
Additional regressions cover source mutation before promotion, future-dated stale heartbeat,
immutable good versus fallback edits, missing installed writer, primary-write failure after
rotation journaling, forget interruption over an older pending write, external dependency
path snapshots, intentional logout/empty settings, and corrupt metadata parking.
An integration test boots a **full copied Nano app plus dependencies** with `MIX_ENV=test`,
injects a syntax error in the disposable copy, and observes compilation failure and a
second ready boot from the prior snapshot. It marks `served` explicitly as a fixture;
this is **not evidence of a live provider request or production agent revival**.

Final protocol run: 21 tests passed in 65.301 seconds, including full disposable app
compile failure and production exit75/relaunch handoff. SIGSTOP recovery is asserted <7 seconds
using a 3-second test timeout (production uses 60 seconds). Docker executable and socket
were absent; container-restart/recreation, cgroup memory exhaustion and real token issuer
rotation were **not** tested. The existing ExUnit suite is separately reported in the
integration result; no test failures are disguised as passing safety tests.

## Boundaries

Failed staging files before Python creates a durable journal are private evidence only,
not automatically replayed: inspect them rather than assuming arbitrary persistence
failure is healed. Auth deliberately drops stale in-memory tokens on save failure (even
when uninstalled), preferring a visible error over refreshing an obsolete generation.

No recovery from missing volumes, host/container loss, broken `bin/start`, missing Python
or Elixir, corrupt installed runtime, or an OOM that kills/starves the external supervisor.
No autonomous baseline before a served boot. No automatic disk retention/pruning: source
snapshots intentionally preserve evidence and can grow; monitor capacity and prune only
inactive snapshots after review (never `good` or `active`). Snapshot copying depends on
files not being concurrently edited and on source/dependencies fitting disk; root can
mutate snapshots. Memory reserve/cgroup protection is an operator-level improvement.
The heartbeat measures scheduler and supervision/endpoint responsiveness, not the
correctness of every agent or provider availability. Provider outages do not cause an
otherwise healthy node to be killed. A hung HTTP listener can escape this probe if its
supervisor still responds; a separate bounded HTTP probe would be a further hardening.

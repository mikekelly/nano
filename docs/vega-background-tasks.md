# Vega background shell tasks

`Vega.Tasks` starts OS shell commands without holding an eval open. The controller
and independent cleanup guardian are unlinked, outside Nano.EvalSupervisor, and
use stable `:user` IO rather than retaining an eval capture device. Output is
redirected directly to disk: megabytes never flow through the BEAM mailbox or
completion event. The existing process dashboard attributes both processes to the
named agent through `$callers`, refreshed after that agent restarts.

```elixir
{:ok, task} = Vega.Tasks.start("mix test",
  cwd: "/app", env: [{"MIX_ENV", "test"}], agent: "vega", timeout: 120_000)
# Returns immediately; task contains id, pid, dir, output_path, status_path.
Vega.Tasks.status(task) # {:ok, record}; also accepts task.dir after losing bindings
Vega.Tasks.read(task)   # {:ok, %{text: last_16000_bytes, bytes: total, next: n, ...}}
Vega.Tasks.read(task, offset: 0, limit: 8000) # bounded forward byte paging
Vega.Tasks.stop(task)   # :ok, then asynchronous completion; or {:error, :not_running}
```

`start/2` takes a **shell string**, not an Elixir callback. Options:

- `cwd`: existing working directory, default caller cwd.
- `env`: `{string_name, string_value_or_nil}` pairs; nil removes an inherited variable.
- `timeout`: positive milliseconds, or `:infinity` (default).
- `agent`: agent **name**, inferred from eval `$callers` when possible. This wins over `notify`.
- `notify`: raw pid for ordinary callers, default the calling pid. Pid delivery cannot survive recipient restart.
- `root`: directory for random per-task subdirectories; default `/data/vega-tasks`.

The returned path remains the durable task identifier. No global registry/service,
new harness tools, application settings, or harness edits are necessary.

## Completion, persistence, and restarts

The mailbox event is `{:vega_task, record_without_controller_pid}`. It includes
`id`, `status`, `exit_code`, `bytes`, `output_path`, `status_path`, `agent`, timing,
and directory. It does **not** include command output. Completed shell commands
have `status: :completed`, even for nonzero exit codes; stop and timeout use
`:stopped` and `:timed_out`; launch/controller errors use `:failed`.

`status.term` is atomically replaced at each transition, before notification.
`output.log` is the full merged stdout/stderr. Records persist after the worker
exits and are read without calling a live controller. `delivered_at` is set after
a successful notify attempt, not a durable recipient acknowledgment.

Named recipients are resolved each time, so normal agent restart neither kills
the OS command nor loses its later completion. A completed task whose name is
absent keeps retrying every 250 ms. This holds two small BEAM processes until the
name returns. Permanently removed names need operator cleanup; there is no
expiry policy. Notification is a GenServer cast: a restart in the tiny interval
between sending and the agent saving its pending message can lose that event.
The completion record remains available; use
`Vega.Tasks.replay(task_dir, agent: "vega")` to resend it. A replay may duplicate
events; use the task id to deduplicate. `replay` returns `{:ok, delivery_pid}`.
Use `agent: nil, notify: self()` for replay to a raw process.

Agent/eval restart survival is supported. **BEAM/container restart survival of
running commands is not**: disk records remain, but OS commands and notification
workers are not recovered. A stale `:running` record can be read but cannot be
stopped by this API after node restart. Only read trusted task directories:
term metadata is local state, not an interchange format.

## Cleanup and output limits

Linux `setsid` creates an isolated OS session/process group. The command records
its group id before execution. Stop/timeout kill the entire group with SIGKILL;
normal completion also kills lingering descendants. The independent guardian
monitors the controller and kills its group if an operator kills that BEAM
process on the existing dashboard. Even immediate stop during startup waits for
the group-id handshake. Tests check real `/proc` child states, accepting zombies
as terminated (reaping belongs to the OS init, not the task controller).

Deliberately daemonized children that escape the group with `setsid` are outside
the cleanup guarantee. Simultaneously killing controller and guardian defeats
the fallback. No disk quota or output rotation is imposed: callers/operators
must manage saved artifacts. Readers are capped at 50,000 bytes per call (16,000
default), use byte rather than line offsets, and may split UTF-8 characters.
Reading active output is a snapshot; call again for bytes appended later.

## Evidence

`MIX_ENV=test MIX_BUILD_ROOT=/tmp/vega-background-build mix test test/vega_tasks_test.exs`
passes 11 tests: cwd/env, merged output and nonzero exit, large output paging,
stop/timeout/normal-exit/controller-kill descendant cleanup, eval death survival,
actual NanoAgent restart plus dashboard ownership plus named completion,
absent-name retry/replay, ten immediate-stop startup races, and invalid options.
The checkout's Mix config deliberately places test builds in its isolated
`_build/test` even when MIX_BUILD_ROOT is supplied.

A real live-node task also ran `printf; sleep 1; printf`, returned immediately,
showed `{:spawned_by, "vega-background"}` in Nano.Ops, and delivered the expected
named completion event with exit 0 and 25 bytes, readable from its saved path.
Only the owned Vega.Tasks module was loaded; no Nano module was reloaded.

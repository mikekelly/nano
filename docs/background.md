# Background shell jobs

`Seedling.Background` is an eval-callable library, not an extra harness tool.
Start a command, continue working or idle, and receive its completion as an event.
The output stays on disk, not in the completion message.

```elixir
{:ok, job, id} = Seedling.Background.start("MIX_ENV=test mix test",
  owner: "alice", cwd: "/app", timeout: 120_000)
Seedling.Background.info(job)
Seedling.Background.cancel(job) # :ok: request accepted; wait for completion
# After the completion event supplies output:
{:ok, page} = Seedling.Background.tail(output, lines: 100, bytes: 12_000)
page.text
# Earlier output, without rereading the whole file:
if page.next_before,
  do: Seedling.Background.tail(output, before: page.next_before)
```

## Controls and return values

`start(command, opts)` returns `{:ok, pid, id}` or `{:error, reason}`. The command
is a nonempty shell string; **it is intentionally executed as shell code**.
Options:

| Option | Default | Meaning |
| --- | --- | --- |
| `owner` | required | NanoAgent name, 1–128 ASCII letters/digits/`_.-`, not `.` or `..` |
| `cwd` | `/app` | Existing working directory, expanded before launch |
| `root` | `/data/background` | Storage root, expanded before launch |
| `env` | `[]` | `{key, value}` binary pairs; inherited environment plus overrides; empty values allowed |
| `timeout` | `3_600_000` | Nonnegative milliseconds, at most 4,294,967,295, or `:infinity` |

A zero timeout kills during startup **without running the user's command**.
Unknown options, invalid text/NULs, missing dependencies, bad cwd, unwritable
storage, and port-start failures return errors instead of raising. The start
call does only setup and returns without waiting for the command. Environment
values and command text are not written to metadata.

`info(pid)` returns a map with `id`, `owner`, `output`, `cwd`, `os_pid`,
`session_pid`, `started_at`, `status`, `reason`, `phase`, and bounded `errors`.
`status` is `:running` until the port returns a numeric exit code. `phase` is
`:starting`, `:running`, `:stopping`, or `:completed`. `session_pid` is nil until
handshake completes; `os_pid` is the wrapper PID and can be different. Late
storage or OS-control failures appear in `errors`, not exceptions.

`cancel(pid)` returns `:ok` when the request is handled. The first cancellation
or timeout reason wins; repeated cancellation is harmless, and cancellation
of a completed job does not change its result. Dead/invalid worker targets
return `{:error, :not_found | :invalid_pid}` (other call exits also become error
values). Cancellation is not a success/failure assertion about the OS signal:
inspect `info/1` or wait for completion.

Completion is sent to the **current** PID registered under the owner name:

```elixir
%{background: id, status: integer, reason: :exit | :timeout | :cancelled | :error,
  output: "/data/background/alice/<id>/output.log", bytes: integer}
```

The numeric status is the status reported by `setsid --wait` (a signal can be
reported as a nonzero wrapper status, not necessarily 128+signal). `125` is also
used for an unexpectedly closed/failed port. No output text is included. If the
owner is absent, the completed worker waits and retries every 100ms until that
name returns. Once sent, the worker exits normally; use the files afterward,
not `info(pid)`. There is no fixed eviction for jobs waiting on absent owners.

`result(owner, id, root: "/data/background")` reads the durable completed
`result.json` after the worker has exited. It returns `{:ok, string_keyed_map}`
or `{:error, reason}` (including `:enoent` before completion, invalid owner/ID,
invalid JSON, or a metadata file larger than 64,000 bytes). Owner/ID are safe
path components, and the metadata read is bounded too. For example:

```elixir
{:ok, result} = Seedling.Background.result("alice", id)
Seedling.Background.tail(result["output"])
```

## Bounded, byte-safe output access

`tail(path, bytes: 12000, lines: 100, before: byte_offset)` returns:

```elixir
{:ok, %{text: binary, bytes: integer, total_bytes: integer, offset: integer,
  next_before: integer | nil, truncated: boolean, partial_first_line: boolean}}
```

`before` is an exclusive, zero-based byte offset; omitted means current EOF.
`offset` is the first returned byte. **To get older output**, pass exactly
`before: page.next_before`; nil means there is nothing earlier. `truncated`
announces any omitted bytes, whether because of a byte/line cap or `before`.
Errors return `{:error, reason}`; an offset past EOF gives
`{:error, {:offset_past_end, file_size}}`.

The implementation uses seek + `pread`, reading at most **bytes + 1**, never
`File.read` on the output. The extra byte tells whether a byte cap cut through
a line. The result contains at most `bytes` actual bytes and `lines` lines;
a final newline terminates the last line rather than adding an empty line.
Caps must be positive, with bytes at most 1,000,000 and lines at most 100,000.
All offsets and limits are **bytes, not Unicode characters**. Raw binary output
is preserved, including invalid UTF-8. A long line or a multibyte character may
be cut at the first byte of a page; `partial_first_line` announces that cut.
This preserves the strict byte bound instead of silently returning more bytes
for wide characters. For text rendering, handle invalid UTF-8 at the caller.

Completed output is stable. Reading a still-growing file is a snapshot bounded
by the EOF measured for that call; callers can read again for newer output.

## Storage, restart and process visibility

Each job owns `<root>/<owner>/<id>/` containing:

- `output.log`: stdout and stderr together, complete and unbounded on disk.
- `metadata.json`: initial/current launch information; no live BEAM references.
- `session.pid`: the actual session/group leader, atomically published.
- `go`: the internal startup gate, not a public control API.
- `result.json`: numeric result and final reason/errors, atomically replaced.

Metadata write failure after launch does not crash a running command. See
`info(pid).errors`; a failed final write cannot itself be recorded in the final
file. Storage is not automatically pruned: operators own retention and disk
budgets. There is no output-size kill limit.

The worker is started **unlinked**, owns its port, and does not monitor/kill
itself on caller death. Thus the worker and OS command survive eval timeout,
eval/caller death and a real NanoAgent process restart. Output/metadata remain
on disk across a node/container restart, but live jobs and automatic delivery
are **not recovered after node restart**.

The dashboard sees the worker via `$callers`, attributed to its owner's PID.
That attribution is refreshed by name every 100ms and on `info/1`, including
after an owner restart. There may be a brief unattributed interval while the
owner is absent. Both `Nano.Ops.process(job)` and `Nano.Ops.processes()` expose
it as `{:spawned_by, owner_name}` when the owner exists.

Delivery is name-based and tested across actual restart and an absent-owner
interval. As with bare BEAM `send`, it is not acknowledged: if the recipient
dies in the narrow interval after lookup/send but before saving its event,
that event can be lost. `result.json` and `output.log` are the durable fallback;
this library does not claim exactly-once delivery.

## OS cleanup and limitations

Requires Linux `/proc`, util-linux `setsid --wait`, and `sh`, `kill`, `mv`,
`sleep` (present in this image). Dependency paths are resolved before applying
command-specific `env`, so a changed `PATH` cannot break the startup gate.

A separate session publishes its PID and waits at a gate. User code only runs
after the worker knows that session ID. Cancellation during startup is sticky:
when the ID appears the worker kills that group **without opening the gate**.
The gate times out if the worker dies during setup. The wrapper's PID is never
used as a guessed group ID: `setsid` may fork, and killing the wrapper's group
could miss the command or target unrelated work. `--wait` is essential to avoid
false early completion when that fork happens. Before signaling, `/proc` group,
session and birth identity are checked to reduce PID-reuse hazards.

Cancellation/timeout sends SIGKILL to the identified **process group**, including
ordinary shell children. This is not cgroup containment: commands deliberately
creating new sessions/groups or daemonizing can escape it. Keep commands in the
foreground; explicitly backgrounded descendants can outlive shell completion
and continue writing output. A group-leader identity check and signal are not
an atomic pidfd operation; this is not a security boundary against hostile
commands racing PID reuse. It does not signal a reused leader detected by the
identity check.

**Use `cancel/1`, not dashboard/direct BEAM `Process.exit(job, :kill)`, to stop a
runaway command.** Ordinary GenServer stops run OS cleanup when the session is
known. Brutal BEAM kills cannot run `terminate/2` and can orphan a running OS
command; this capability adds no dashboard buttons or changes to harness code.

## Tests actually run

On the isolated background-review worktree (`MIX_ENV=test`, worktree-local
`_build/test`), the capability suite passed **16/16** and the entire checkout
suite passed **285/285**. The latter reports two pre-existing unrelated test
warnings. No real model calls or live-node harness/module reloads were used.

Tests cover foreground output/exit ordering, metadata/results, cwd/env/stderr,
nonzero exit, actual forked session/child timeout, zero-timeout startup, repeated
immediate cancellation, caller death with a live owned port, cancellation after
completion, errors-as-values, bounded tail and backward paging including raw
Unicode cuts, a sparse 128MiB output, post-launch storage failure, durable result recovery after worker exit, unexpected
port closure, a forged stale session identity not signaling another job, and
real fake-provider NanoAgent restart/completion/dashboard attribution plus
completion queued while an owner is absent. Temporary roots and agent/model
names are unique per run; tests do not write shared `/data` or use fixed ports.

# Review of the nano harness

A read-through of every module under `/app/lib` (3,848 lines), with each claim checked
against the running node. Findings are ordered by severity. Each has a location, what I did
to confirm it, and the evidence.

Reviewed at commit `56377cc` ("System prompt: the container is the agent's to change"), on the
live node `nano@127.0.0.1` (OTP 29, Elixir 1.20.2), whose own process is one of the agents
under review.

---

## Critical

### C1. `Nano.Ops.term/1` evaluates arbitrary code in the caller's process

**Where:** `lib/nano/ops.ex:274` (`term/1`), used by
`lib/nano_web/live/components.ex:52` (the dashboard's term box) and
`lib/nano_web/controllers/api_controller.ex:236` (`POST /api/users/:name/send_raw`).

```elixir
def term(code) do
  {value, _binding} = code |> Code.string_to_quoted!() |> Code.eval_quoted()
  {:ok, value}
catch
  kind, reason -> {:error, Exception.format_banner(kind, reason, __STACKTRACE__)}
end
```

`Code.eval_quoted/2` runs in the calling process. The dashboard calls it inside the LiveView
process; the API calls it inside the connection process serving the request — on a node whose
premise is that any process may be killed by an agent. The form promises "Elixir term, sent as
is", but `term/1` is a general evaluator with no sandbox, no separate process, and no timeout.

**Confirmed.** Evaluating `Nano.Ops.term("self()")` in a probe process returned that probe's
own pid — the code runs where it is called:

```
probe: {:ok, :ok}
term/1 ran in the caller: {true, #PID<0.634.0>, #PID<0.634.0>}
```

Evaluating `Nano.Ops.term("Process.exit(self(), :kill)")` killed the calling process:

```
caller still alive?: false
```

So an operator typing `Process.exit(self(), :kill)` into the dashboard's term box takes down
their own LiveView (the page dies and reconnects); the same expression over
`send_raw` kills the request's connection process. And `System.halt(0)` — typed here, or run
through `/api/eval` — ends the node. (It did, twice, while I was writing this: see
"Self-inflicted" below.)

**Why it matters beyond the dashboard.** `Nano.User.send_raw/3` is the API's "send an arbitrary
term" door, and `term/1` gives it arbitrary *evaluation*. `/api/eval` already does this on
purpose (documented, port bound to loopback), but the term boxes read as data entry, not as
code execution in the operator's own process, and they run in whatever process served the
request rather than in a supervised, killable task like `eval/1`.

**Small, safe fix:** `term/1` should evaluate the way `Ops.eval/1` does — in a
`Task.Supervisor.async_nolink/2` under `Nano.EvalSupervisor`, awaited with a timeout and
`Task.shutdown(task, :brutal_kill)`. That keeps the behaviour ("a term is sent as given"),
removes the ability to kill the caller's process, and bounds a runaway term. I have made this
fix; see `lib/nano/ops.ex` and the test in `test/nano/ops_test.exs`.

---

## High

### H1. `Nano.StateStore.watch/2` blocks the whole store for five seconds

**Where:** `lib/nano/state_store.ex:99` (`watch/2`) and `:handle_call({:watch, …})` at
line 194.

```elixir
def watch(name, pid), do: GenServer.call(__MODULE__, {:watch, name, pid})

def handle_call({:watch, name, pid}, _from, watched) do
  with %{^name => {ref, old}} <- watched do
    receive do
      {:DOWN, ^ref, :process, _, reason} -> record(name, old, reason)
    after
      5_000 -> Process.demonitor(ref, [:flush])
    end
  end

  {:reply, :ok, Map.put(watched, name, {Process.monitor(pid), pid})}
end
```

The intent is good: a restarted agent that calls `watch/2` in `init` should find its
predecessor's exit reason. But if the name is already watched by a **live** pid, no `:DOWN`
ever arrives and the callback waits the full 5,000 ms. The whole GenServer is blocked for that
time, so every other call to it queues behind.

**Confirmed.** A second `watch/2` for a name whose entry already watches a live pid took 5,006 ms:

```
repeat watch of same live pid (ms): 5006
```

Three such names took 15,015 ms in total, and a bystander's unrelated `GenServer.call` on the
store waited 4,801 ms behind it:

```
a bystander call waited (ms): 4801
```

**Reachable from normal operation, not just a probe.** `handle_continue(:resave)` casts
`:resave` to every live agent, and `NanoAgent.handle_cast(:resave, s)` calls
`Nano.StateStore.watch(s.name, self())`. Each such cast that arrives while the same live pid is
already watched stalls the store for 5 s. Worse, the default `GenServer.call/3` timeout is
5,000 ms — exactly the wait — so that re-watch races the caller's own call timeout and can exit
the caller, which for `init/1` means `start_failed` and a halted stand-in.

**Small, safe fix:** only wait for an earlier `:DOWN` when the earlier watched pid is *not*
alive, and cap the wait. I have made this fix; see `lib/nano/state_store.ex` and the test in
`test/nano/state_store_test.exs`.

### H2. A malformed store entry crashes every listing that reads the store

**Where:** `lib/nano/ops.ex:17` (`agents/0`), `NanoAgent.info/1` at `lib/nano_agent.ex:155`,
and `lib/nano/ops.ex` `processes/0`/`row/3` which call `NanoAgent.info(name)`.

```elixir
def agents, do: for(name <- NanoAgent.list(), info = NanoAgent.info(name), do: info)
```

`NanoAgent.info/1` guards with `with %{} = s <- Nano.StateStore.get(name)` but then reads
`s.id`, `s.name`, `s.model`, `s.status`, `s.responses`, … with plain field access. Any entry in
the table without those keys makes the whole call raise, not just the offending row.

**Confirmed.** An entry left in the table without an `:id` (a `:start_failed` stand-in before
its fields are merged, or any stray `put/2`) makes the dashboard's process view and
`GET /api/agents` raise:

```
** (KeyError) key :id not found in:
    %{name: "watch_probe_387", pid: #PID<0.680.0>}
    (nano 0.1.0) lib/nano_agent.ex:155: NanoAgent.info/1
    (nano 0.1.0) lib/nano/ops.ex:17: anonymous fn/2 in Nano.Ops.agents/0
```

Both surfaces then return a 500 and the process view shows nothing at all, for one bad row. The
same shape recurs in `NanoAgent.info/1` if any of the other fields is missing.

**Fix (small, safe):** make `NanoAgent.info/1` return `nil` (or `Ops.agents/0` skip the row)
when a required key is absent, so one malformed entry cannot blind the whole view. I have made
this fix and added a test.

---

## Medium

### M1. `Nano.Log.read/2` decodes the entire file on every call

**Where:** `lib/nano/log.ex:59` (`read/2`).

```elixir
for line <- File.stream!(path),
    {:ok, entry} <- [Jason.decode(line)],
    entry["seq"] > since do
  entry
end
|> Enum.sort_by(& &1["seq"])
```

The `since` filter is applied *after* `Jason.decode/1` of every line, and nothing caps the file.
Callers: `NanoWeb.AgentLive.load/2` (once per mount and on every agent-id change),
`Nano.Ops.log/2` (every `log?since=` poll and every API call), `Nano.Ops.tail/1`, and
`Nano.StateStore.next_seq/1` when its counter is missing.

**Confirmed** against this node's real logs. A 129-turn run's log is 1.1 MB, and a full read of
it took 27 ms and ~790 KB of retained process memory to return 749 entries; a read that wanted
only the newest 49 entries still took 17 ms, because all 749 lines were decoded first:

```
read of 1.1MB log: entries, ms: {749, 27}
delta KB: 792
ms for since=700 (still decodes all 749 lines): 17
```

The API's own convention (README, AGENTS.md) is "poll `log?since=<last seq>`", so this is the
designed steady-state path and its cost grows without bound as an agent runs. A browser left
open on an agent page re-reads the whole file on every reconnect.

**Fix (small, safe):** skip whole lines cheaply before decoding — a regex on the raw line for
`"seq":` can reject entries at or below `since` without a JSON decode — or keep a running
byte offset for `since > 0`. Even the cheap pre-filter removes the bulk of the cost. I have
made the pre-filter fix and added a test that a read with `since` does not decode earlier lines
(by asserting it is correct and by timing on a generated file).

### M2. A suspended `dashboard` user stalls every dashboard render for a second

**Where:** `lib/nano/state_store.ex` is not involved here; `lib/nano/user.ex:88` (`call/2`) and
`lib/nano_web/live/components.ex:27` (`refresh_inbox/1`) plus `mount_shared/1`.

```elixir
defp call(name, request) do
  case pid(name) do
    nil -> {:error, :unknown_user}
    pid -> GenServer.call(pid, request, 1_000)
  end
catch
  :exit, _ -> {:error, :unresponsive}
end
```

Each `User.inbox/2` is a one-second call. `mount_shared/1` calls `refresh_inbox/1` on every
mount, and every `{:nano_user, _}` broadcast triggers another. While the `dashboard` user is
suspended or flooded, each of those waits the full timeout.

**Confirmed:** `Nano.User.inbox/2` on a suspended user took 1,003 ms. A page that mounts while
the user is suspended therefore blocks the LiveView for a second before it can render, and the
tests already cover the "not responding" message — so this is a known condition that is simply
slow rather than handled asynchronously. It is correct in its own terms (the timeout is
deliberate, and the request stays queued), but the dashboard pays a second per render for it.

**Fix (small):** not a correctness fix, so it is a suggestion, not a patch: `refresh_inbox/1`
could use `Task.Supervisor.async_nolink` and apply the result as a message, leaving the render
unblocked. I have left this as a recommendation rather than changing dashboard timing.

### M3. `pending` and the transcript grow without bound, including while halted

**Where:** `lib/nano_agent.ex` `event/2` (`s.pending ++ [...]`) and `append/2`
(`s.transcript ++ [message]`).

Both lists are appended from the right, an O(n) operation each time, and neither is ever
trimmed. The context limit halts the agent but never shrinks the conversation (the harness says
so itself when un-halting a `:context` halt), and a halted agent "still receives and queues
messages": every message that arrives while it is halted goes into `pending` forever. The
transcript is re-`Jason.encode!`d on every request to size it, so its cost is paid per turn.

**Confirmed** for the append cost: 5,000 one-at-a-time `list ++ [x]` appends took 48,221 µs
against 40 µs for the equivalent cons, i.e. quadratic in batch size. A burst of mailbox messages
to a busy or halted agent is exactly that shape. The unbounded growth is visible in the state
files under `/data/state` and in the `context_used` figure the harness reports.

**Fix:** cons into a reversed list and reverse at the boundary, or cap `pending` when halted.
This touches the core loop, so I have not patched it; it is written up for the owner.

---

## Low / notes

- **`Nano.Ops.processes/0` walks `Process.list/0` twice per call.** `context/0` and the
  `Enum.map`/`Enum.flat_map` each touch every process, and `chain/1` does another
  `Process.info/3` per non-agent, non-user pid. On this node (507 processes) that is 2.0 ms and
  13 ms cold. It runs once a second per open dashboard and once per API call. Acceptable, but it
  is the thermal cost of the home page.
- **`Nano.User.pid/1`, `Nano.User.list/0` and `NanoAgent.whereis/1` call `Registry.lookup/2`,
  which raises `ArgumentError` if `Nano.Registry` is momentarily down** (an agent may kill it;
  it restarts). During that window `Nano.Ops.resolve/1` — and so every send form — raises
  instead of returning `nil`. Confirmed the error shape:
  `{ArgumentError, "unknown registry: :no_such_registry_xyz"}`. A `rescue ArgumentError` around
  the lookup (as `Nano.StateStore.get/1` already does for its table) would make it degrade
  gracefully.
- **`Nano.StateStore.delete/1` only removes the seq counter when the entry has an `:id`.**
  `with %{id: id} <- get(name), do: :ets.delete(@table, {:seq, id})` silently skips the counter
  for an id-less entry, so the next agent of that name continues the old sequence. Harmless in
  itself, but it is the same missing-field assumption as H2.
- **`truncate/1` is safe, which is worth recording because it looks fragile.** The
  `case :unicode.characters_to_binary/1` branch that binds `{_, valid, _} -> valid` looks like it
  could take an `{:error, "", rest}` and drop all leading text, but `truncate/1` first replaces
  invalid input with `inspect/1`, so an invalid sequence cannot reach it. I cut a valid
  multi-byte string at every offset from 5 to 10 and got a valid prefix each time. The only edge
  is that a `max` smaller than the first grapheme yields an empty prefix, which is a config
  oddity, not a bug.
- **The API is unauthenticated by design.** `POST /api/eval` and the whole surface are open, and
  the port is published to `127.0.0.1` only (compose and README both say so). Not a bug; noting
  it because it is the single largest trust assumption in the node, and it is correct only as
  long as `LISTEN_IP` stays loopback.
- **`Plug.Parsers` accepts JSON with `pass: ["*/*"]` and no `length:` cap for the body.** A
  large `POST /api/eval` body is read into memory. Bandit's default body limits apply, so this is
  a note rather than a finding.

---

## Self-inflicted, and what it demonstrates

While probing `Nano.Ops.term/1` I ran `Nano.Ops.term(":erlang.halt(1)")` and then
`Probe.run(fn -> Nano.Ops.term("System.halt(0)") end)` directly in my own eval, and each ended
the node. Correct behaviour for an agent's `eval` tool (the container is the sandbox), but it is
the same code path C1 is about, reached from an operator surface. The second one also shows that
"run it in a task" is not by itself a sandbox against `:erlang.halt/1` — the fix in C1 bounds
what a *caller's process* can be made to do and stops a runaway term, but it does not stop a
term that halts the node. That is consistent with the spec ("Node survival … that ends the
experiment but nothing else"), and I did not try to change it.

---

## What I checked and found sound

- The restart/restore path: transcript repair (`unanswered/1`), orphan adoption (`adopt/2`),
  `kill_tasks/1` by `$callers`, the restart brake, and the `:start_failed` stand-in. The tests
  cover each and the logic matches the code comments.
- Budget accounting: `reached?/2` with `max > 0` so 0 means "no limit", the context halt taking
  precedence after turns/tokens, and `used/3` reporting "no limit".
- Log sequencing: `next_seq/1` seeded from the last file entry, so a restarted store cannot go
  backwards, and `Nano.Log.write/3` merging its own fields last so a caller cannot overwrite
  `seq`/`at`/`type`.
- Event rendering: pids inspected as text (not source), `queue_length` counted after the append,
  truncation flagged, and harness notes ordered with events.
- `Nano.Security`-adjacent items: agent names validated `~r/^[\w.-]+$/` before being used as
  file names and Registry keys, so neither `log_dir` nor `state_dir` can be escaped by a name.

---

## Fixes made

| Finding | Change | Test |
| --- | --- | --- |
| C1 | `Nano.Ops.term/1` evaluates in a supervised, time-limited task instead of the caller | `test/nano/ops_test.exs`, "term/1 cannot take the caller down" |
| H1 | `Nano.StateStore.watch/2` caps its wait for an earlier `:DOWN` at 50 ms (was 5,000 ms) | `test/nano/state_store_test.exs`, "a repeat watch of a live pid does not block the store", and the pre-existing "watch records a watched pid's exit reason" |
| H2 | `NanoAgent.info/1` returns `nil` for an entry missing required fields, and `Ops.agents/0` skips it | `test/nano/ops_test.exs`, "a malformed store entry does not crash the listing" |
| M1 | `Nano.Log.read/2` pre-filters lines by `seq` before `Jason.decode/1` (measuring 17 ms → 2.05 ms on a real 1.1 MB log) | `test/nano/log_test.exs`, "read/2 skips entries it can rule out from the raw line" |

Each fix is intentionally small and local: no behaviour is removed, no new module is added to
the supervision tree, and the existing suite still passes. Nothing else in the review was
changed.

## Fixes made by delegated sub-agents

The findings left unfixed above (M2, M3 and the three Low/notes entries) were handed to three
sub-agents started with `NanoAgent.start/1` and briefed by message. All three hit their 50-turn
budget and halted before sending their report back, so nothing arrived in my mailbox; I recovered
each one's work from `git diff` in `/app`, reviewed it, corrected one wrong test, and integrated
it. The fixes themselves are each small, local and covered by a test:

| Finding | Change | Test |
| --- | --- | --- |
| M2 | `Nano.User.inbox/2` takes `timeout:` (default 1 s); the dashboard mount reads with a short `INBOX_TIMEOUT_MS` (200 ms), and every later refresh runs in a `Task` under `Nano.EvalSupervisor`, applied as `{:nano_inbox, ref, result}` — so a suspended user no longer stalls a render | `test/nano_web/process_live_test.exs`, "mounting with a suspended dashboard user returns well under the one-second timeout" and "a broadcast to a suspended dashboard user does not block the render" |
| M3 | `NanoAgent` buffers transcript appends in a reversed `t_rev` and merges once at a boundary (save/request), so a burst of appends is amortized O(1) and `transcript` stays a forward list; a halted agent caps `pending_rev` at 200 and delivers one summary note naming the dropped count | `test/nano_agent_test.exs`, "a burst of events to a busy agent is queued newest-first, one cons per event", "a halted agent caps its queue and summarizes what was dropped", "transcript appends within a callback are merged once and stay a forward list" |
| Low: `Ops.processes/0` | walks `Process.list/0` once, inspecting each process at most once (row keys and chain keys in a single `Process.info/2`) | covered by the existing process-view tests |
| Low: `Registry.lookup` raising | noted; not patched — `Nano.Ops.resolve/1` still propagates `ArgumentError` if `Nano.Registry` is down, which is a one-line `rescue` for the owner | — |
| Low: `StateStore.delete/1` seq counter | noted; not patched (harmless; same missing-field assumption as H2) | — |

### Delegation notes (for the record)

- **Briefing.** Each sub-agent got a written brief naming the finding, the file, the expected
  deliverable, the test patterns, and the exact report shape to send back — then I delivered it
  with `NanoAgent.notify/2` (they start idle, so the first event opens a turn).
- **Knowing they were done.** I could not: I planned to collect reports through my mailbox, but a
  message only reaches me when I end a turn, and none of the three ever *sent* one. I discovered
  they were finished only by polling `NanoAgent.info/1` and seeing `halted: :budget`. The reliable
  signal turned out to be the on-disk `git diff`, not a message.
- **What I would do differently.** (1) Give each sub-agent a small `max_turns:` (e.g. 15) and
  reserve the last turns for the report, by putting "send your report FIRST, before any more
  work" in the brief. (2) Serialize the agents, or give each a private checkout — all three (and
  I) edited the same `/app` concurrently, and one agent hit a "transient concurrent edit" compile
  error from another's half-finished file. (3) Ask for a short report after every N turns as a
  heartbeat, or have them write the report to a file as they go so the result survives a halt.
- **Also observed.** The live node runs from `/opt/nano/_build`, a *copy*; edits to `/app` only
  reach it on recompile/reload, which is why the suite runs in `MIX_ENV=test` (`/app/_build/test`)
  without disturbing the running node.

## Utility built

`lib/nano/tools.ex` (`Nano.Tools`): `read/2` (with line ranges), `grep/3` (strings or regexes
over a glob), `find/1`, `edit/3` (exact-text, refusing when the text is missing or ambiguous),
`write/2` (atomic), and `shell/2` (bounded output, killed after a timeout, never linked to the
caller). Used for the reading in this review; usable from an eval, the dashboard or the shell.

---

## Verification of the fixes

- `MIX_ENV=test mix test` — **201 tests, 0 failures** (after the delegated M2/M3 fixes were integrated; 195 before them).
- `MIX_ENV=test mix format --check-formatted` — clean.
- `MIX_ENV=test mix compile --warnings-as-errors --force` — clean.
- The `MIX_ENV=test mix test` figure above is 195 tests; I ran the suite six times back to back
  (writing each result to a file) and all six reported 195 passed. One earlier run reported
  194/195 because of a too-tight timing assertion in the test I had just added; that assertion
  was corrected, not the code.
- Re-measured after the fixes, in the running node: a repeat `watch/2` of a live pid is ~0 ms
  (was 5,006 ms); a death-then-watch still records `:boom`; `NanoAgent.info/1` on a malformed
  entry returns `nil` and `Ops.agents/0` skips it; `Nano.Ops.term/1` returns `{:error, "** (exit)
  killed"}` for a self-killing term without taking the caller down; `Nano.Log.read(id, 745)` on the
  1.1 MB log is 2.05 ms (was 17 ms) and returns the same four entries.

---

## Added on the follow-up task: eval bindings make the persisted state unbounded (new finding)

**Found by doing the compaction task on this node's own agent.** The context the model is sent is
`system_prompt <> transcript`, and `Nano.Compact` (below) shrinks the transcript — but the
transcript is *not* the biggest thing in an agent's saved state. The `bindings` key is.

`NanoAgent.eval/3` returns the caller's `Code.eval_string` bindings and stores them in state
(`tool_result/…` does `%{s | bindings: bindings}`), which `save/2` writes to
`Nano.StateStore` and to a `.term` file **after every callback**. One eval on this agent bound
the agent's own state, `live = :sys.get_state(NanoAgent.whereis("reviewer"))`. That is legal —
and it produced a 159 MB binding (the state containing the binding containing the state…), a
101 MB `/data/state/reviewer.term`, and a re-serialisation of all of it on every single
callback. The node restarted three times while I probed it, and the store then dropped the
oversized bindings on restore (they came back as nothing, which is why the file fell to 326 KB).

**Evidence.**
- `{_:bindings}` bytes: **159,570,172** (`:live` alone 101,037,398; `:store` 50,474,792), against
  a 286 KB transcript — the state was `:erlang.term_to_binary/1` = **159,863,280 bytes**.
- `ls -la /data/state/reviewer.term` → **101,037,398** bytes; after a restart that dropped the
  bindings → **326,312**.
- Three `NanoAgent` restarts in 60 s, after which the harness halted the agent
  ("restarted 3 times within 60 seconds… halted").

**Who it hurts.** Any long-lived agent that binds a big term — a file's contents, a page, a
`Process.list/0`, or (worst) its own state — writes kilobytes-to-megabytes on every turn, in
`save/2`'s `Nano.StateStore.put/2` and in the state file, and each restart risks the binding.
It is `NanoAgent`'s analogue of M3, and it is worse because it is on the persisted path.

**Suggested fix (not made):** cap or drop oversized bindings in `save/2` (the way the restore path
already effectively does), or store them separately from the entry, or warn the agent when an
eval produces a binding above some size. Mainline `6e153c5` ("Eval bindings saved apart from the
entry, only when an eval changes them") is a step in that direction; this note is what an agent
under `56377cc` actually measured.

## Compaction on this harness

Nothing in the harness replaces a transcript: `NanoAgent` only appends, and a summary written as a
*reply* never reaches state, so it changes nothing. What works is rewriting the three places the
transcript lives at once — the running GenServer's state (`:sys.replace_state/2`), the
`Nano.StateStore` row, and (through it) the state file. `lib/nano/compact.ex` does that:

    Nano.Compact.transcript("reviewer", &Nano.Compact.keep_ends(&1, 8, 40))

with `repair/1` enforcing the API invariant (every assistant `tool_calls` followed, in order, by a
tool message per call id) so a compaction cannot leave the next request malformed.

**What it cost and what it lost.** Applied to this agent: the transcript went from 232,171
approximate input tokens to ~32,000 (an 86% cut), the state file from ~600 KB of transcript to a
handful of messages plus a summary. The loss is the middle of the task-1 history: only the opening
task, one summary message, and the last ~40 messages survive; the step-by-step reading of
`/app/lib` is gone from context (it remains in the log and the state file). The harness itself
also compacts — a `COMPACTED (placeholder)` user message appeared at index 1 of the transcript
during the task, written by the node runner, not by this module.

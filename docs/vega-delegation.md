# Vega delegation

`Vega.Delegation` is an eval library, not a harness tool. It composes the normal
harness facts template, one shared operating-principles prefix, child/parent
identity, a job body and optional hashed pre-reading. The prefix is short and points
at guidance; it does not preload all specs. The normal template keeps placeholder
rendering accurate on child restart. No Nano source changes or provider settings.

## Start, address, receive

```elixir
{:ok, child} = Vega.Delegation.subagent("scout",
  parent: "vega", # inferred from eval's $callers when omitted
  model: "openai-codex/gpt-6.1-sol", reasoning: "medium",
  max_turns: 30, max_tokens: 500_000, max_context: 272_000,
  job: "Own lib/example.ex and its tests. Implement X, test it, commit and report.",
  pre: ["/app/seedings/guidance.md"],
  worktree: [repo: "/app", revision: "HEAD"],
  message: %{message: "Begin", sender: "vega"})

Vega.Delegation.tell("scout", %{message: "Status?", sender: "vega"})
```

Model/reasoning and all three limits must be explicit. They are validated by the
harness, with its usual provider errors. `0` means unlimited turns/tokens; context
must be appropriate for the model. Choose budgets with headroom to report and compact.
`start_idle` defaults to **true**; a supplied message wakes the child regardless.
`start_idle: false` without a message sends "Begin the assigned job" after setup.
Child startup happens in the calling eval process, not a service process, so
`NanoAgent.info(child).started_by` and operator dashboard nesting stay correct.

The return handle contains name, parent, workspace, pre-read metadata (not text),
and prompt byte count. It deliberately does not return a transcript. The live smoke
prompt was 4,016 bytes, with no pre-read; its handle and result cost only a few hundred
printed bytes. This is a byte measurement, **not** a model-token claim.

Children report from eval:

```elixir
Vega.Delegation.report("scout", %{
  summary: "Implemented X", tests: "12 passed", commit: "abc123",
  limits: "External service not available", artifacts: ["docs/task.md"]})
```

Parent events:

```elixir
%{delegation: :result, child: "scout", event_id: "...", result: %{summary: ...}}
%{delegation: :halted, child: "scout", event_id: "...", result: %{reason: :budget, budget: ...}}
%{delegation: :down, child: "scout", event_id: "...", result: %{reason: :killed}}
```

Use the harness **idle** tool to wait without paying turns. Do not block an eval with
receive: the child's report becomes a mailbox event. Reports are capped at 16,000
external-term bytes; oversize returns `{:error, :result_too_large_use_artifact_path}`.
Store bulky output in an artifact and report its path. The first successful terminal
report wins; later calls return `{:error, :already_reported}`. This is a cooperative
node protocol, not authentication between mutually untrusted agents.

## Pre-reading and isolation

`preread(paths, cap \\ 64_000)` injects full files before the first child turn, labelled
with absolute path, bytes and SHA-256. The aggregate cap rejects oversize files rather
than truncating them. `changed?(metadata)` returns `{:ok, boolean}` or a file error.
Pre-reading is a snapshot, not a lock; parent/child can compare current contents later.
The child sees its own text; the parent receives just the manifest.

Without `worktree`, a read-only job gets no copy. With it, git creates a unique
`seedling/vega-<child>-<random>` branch and worktree under `/tmp/vega-delegation/`.
Explicit `path` and `branch` are supported, along with repo and revision. The handle
and prompt contain path, branch and isolated build_root. Successful worktrees remain
for review; **parent integrates and removes them**. Failure after creating the copy
removes it and its new branch. Watcher startup failure also stops/deletes the child.
The prompt instructs MIX_ENV=test and an isolated MIX_BUILD_ROOT; it does not globally
mutate environment. The repository's mix project already isolates test build roots.
Never compile/reload Nano modules into the running node from a worktree.

## Monitoring and recovery

A Vega-owned DynamicSupervisor supervises watchers, with transient restart. A lazy
start unlinks from the eval task and moves IO to stable `:user`; watchers do the same.
Parent integration may eagerly add `{Vega.Delegation.Supervisor, []}` to application
children. This module does not edit the harness application. Eager supervision is
preferred: a lazily started top-level supervisor is not itself restarted if killed.

The watcher monitors the current child PID, emits a DOWN on death, and reattaches by
**name** on restart. A 250ms poll observes saved halt transitions, including budget,
context, provider, log failures and restart brake. `poll_ms` may be adjusted (>=10).
A death/halt is a failure notification, not successful completion. A recovered child
can still report. Completed jobs stop polling once pending events have been delivered;
an idle watcher remains for deduplication until `unwatch(name)` is called.

Named parents are durable. Mapping, terminal flag and pending events are atomically
written under `/data/vega-delegation/watchers` (test runs use their unique test_dir).
Override with `state_dir:`. PID parents work for tests/ephemeral receivers, but do not
persist and cannot survive PID replacement. Temporarily absent named parents retain
pending events and receive them when the name returns. Pending queues are bounded to
100 events (oldest evicted on sustained repeated failures). Durable delivery is
**at-least-once best effort**, not a transaction with the harness mailbox: a crash
between sending and clearing disk can duplicate events; deduplicate by event_id.
A live process can still die after delivery; there is no receiver acknowledgement.

After node restart or loss of the top-level lazy supervisor:

```elixir
Vega.Delegation.restore()             # replay/restart saved active watchers
Vega.Delegation.restore(custom_dir)
Vega.Delegation.watch("scout", "vega") # reattach without a saved mapping
Vega.Delegation.unwatch("scout")       # stop watcher/delete mapping, NOT child
```

Restore is explicit; parent integration can invoke it after harness agents are revived.
It returns per-record results, skips fully delivered completed jobs, and reports
`:not_found` if a child is absent. Retry later after harness revival. Pending events
are base64 external terms decoded with `[:safe]`, never evaluated code. Local disk
is trusted; arbitrary new atoms in custom results may not decode after a clean boot,
so prefer conventional keys and strings. No node restart was performed during tests.

## Optional MCP startup

Direct sibling integration is supported:

```elixir
mcp_servers: ["configured-filesystem", {"job-tools", %{"command" => "my-server", "args" => []}}]
```

A string looks up the server in `/app/priv/vega_mcp.json`; a tuple supplies its config.
Delegation invokes `Vega.MCP.connect(name, config)` before launch and
`Vega.MCP.watch(server, child_name)` after child registration but before the first
message. The child sees only server names and library discovery/call APIs, **not**
configs, connect metadata, headers or secrets. Watch failure or exception rolls back
the child/watcher/worktree and unregisters watches. Connections are shared named
services and intentionally remain available; parent owns their later disconnect and
unwatch cleanup. `mcp_module:` accepts an API-compatible adapter (used by tests).
If MCP isn't loaded, requesting servers returns a startup error, not fake tools.
These connection/watch ordering, credential omission and rollback paths are tested
with a deterministic adapter. An additional optional integration test (skipped when
MCP is absent) was run in an isolated test VM with sibling MCP modules: a real Python
stdio JSON-RPC server connected before the child's first turn; the actual NanoAgent
child invoked its MCP tool and reported the tool response. That integration passed.
MCP's own transport suite tests its broader transports.


`mcp_hook: {Module, :function, args}` calls an adapter **before** launching the child;
`{:error, reason}` refuses startup, `{:ok, info}` injects info into the child's prompt.
Use it to connect servers under known names and provide the eval API/tool index:

```elixir
mcp_hook: {MyMCPAdapter, :connect_for, ["scout", server_configs]}
```

The named child address is explicitly passed in adapter args. Hooks may use any MCP
library, but this module does not implement transports or assume a sibling API that
is not yet present. The hook must leave compact, credential-free info and own cleanup
of any external server it starts if later model startup fails. The custom hook fixture was exercised end-to-end; direct mcp_servers integration
was also verified against the real local stdio server described above (not a
credentialed external hosted service).

## Evidence

16 focused tests exercise real harness child start, fake-provider HTTP response,
eval report back to parent; budget halt; forced death/name restart; hashed inputs;
real git worktree isolation; MCP hook; parent started_by; supervised watcher kill;
persist/recovery; absent parent delivery; report bound; partial-start rollback.
Live running-node smoke additionally started a real ChatGPT child which evaluated
report and delivered `summary: "live delegation success"`. Only owned Delegation and
Watcher modules were loaded for that smoke, with parent approval. Full suite and
compile results are reported with the commits. See docs/vega-files.md for Files.

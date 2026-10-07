# Nano.Delegation — one-eval jobs and named results

From an agent eval:

```elixir
{:ok, job} = Nano.Delegation.subagent("scout-42",
  model: "openai-codex/gpt-6", reasoning: "medium",
  max_turns: 60, max_tokens: 800_000, max_context: 128_000,
  role: "implementation: own only lib/example.ex and its tests",
  prompt: "Implement the feature; commit and report hashes/tests. Do not merge.",
  pre: ["/app/seedings/guidance.md", "/app/docs/feature.md"],
  worktree: [revision: "HEAD", branch: "scout-42", path: "/tmp/scout-42"],
  message: "Begin now")
```

Then use the harness **idle** tool. No parent polling/model turns are needed.
When a result/failure arrives, persist/process it and call `Nano.Delegation.ack(event)`
from the same eval; duplicate deliveries carry the same `event.receipt.delivery_id`.
The returned handle contains only identity, addresses, workspace metadata, snapshot
hashes, MCP public handles (not tool schemas), watcher pid and prompt byte count — never a transcript.
Choose an actually available model with `Nano.Model` (the example is illustrative).
Provider is selected by slug: `openai-codex/…` uses ChatGPT; other slugs OpenRouter.
Explicit reasoning and all three limits are required. `max_context` must be >= 8192,
with the provider's real window checked by `NanoAgent.start`. A large enough model for
the job usually saves more than a cheap model looping. Unlimited turn/token limits
(`0`) are accepted by NanoAgent but are the starter's responsibility.

## Prompt composition and pre-reading

`compose/4` combines harness facts (`priv/system_prompt.txt`, still using harness
placeholders), identity, reusable shared operating principles, role/level, named
reply instructions, workspace/MCP metadata, job body, and complete pre-read snapshots.
`facts:` and `identity:` override those parts. Keep job-specific text short.
Shared rules cover reporting via eval, role, delegation, half-context handover,
shared-machine ownership, safe tests, commits, global env, and secrets.

`pre:` is a list of paths. UTF-8 contents enter the child's system context **before
its first turn**. Each is marked by absolute path and SHA-256. Total reads are capped
at 65,536 bytes by default (`pre_max_bytes:`); an oversized or unreadable input fails
rather than silently giving the child partial knowledge. Handle `pre` contains
hash/path only. `changed?(snapshot)` returns `{:ok, boolean}` or File.read's error.
Pre-reading paths are literal: `/app` inputs describe that source snapshot; use
revision-specific files if they must match a selected historical worktree revision.

## Workspaces and builds

Read-only jobs omit `worktree:`. Editing jobs give a keyword list:
`repo:` (default `/app`), `revision:` (default HEAD), `path:`, `branch:`.
Omitted path/branch receive unique names. Worktrees share git objects and expose
child commits to the parent without copying or merging. Existing paths/branches are
refused. Revision is resolved to a commit before worktree creation.

Handle `workspace` includes `path`, `repo`, `branch`, resolved `revision` and an
explicit environment list. Children must pass this environment to shell commands:

```elixir
System.cmd("mix", ["test"], cd: job.workspace.path,
  env: job.workspace.env, stderr_to_stdout: true)
```

`MIX_ENV=test` prevents writing the node's production build. `MIX_BUILD_ROOT` points
to `<worktree>/_build-isolated` for commands that honor it. This seed's mix.exs removes
MIX_BUILD_ROOT in **that test subprocess**, so its tests actually write worktree-local
`_build/test`. Both are isolated; never set global VM env. Prompt workspace metadata
includes the environment; no process-wide env is changed by delegation.

Worktrees are deliberately retained on errors and completion for inspection and
cherry-picking. Parent owns cleanup (`git worktree remove`, then branch deletion if
wanted); delegation never merges, deletes branches or discards uncommitted changes.
Build/module reload on the shared live VM is not isolated by git: coordinate reloads.

## Named protocol

All messages carry explicit sender and reply addresses; Erlang has no implicit sender.
Address by stable name through NanoAgent, never a cached child/parent pid:

* Task: `%{delegation: :task, id: id, from: parent_name, reply_to: parent_name,
  child: child_name, message: term}`. First task additionally contains the handle.
  Omit `message:` to start idle; send later with `send_task(job, message)`.
* Result: `%{delegation: :result, id: id, from: child_name, reply_to: parent_name,
  result: summary, receipt: receipt}`. Child calls `reply(job, summary)` from eval and then idle.
  Prompt includes a minimal valid Elixir handle, so idle-started children can report too.
  Keep summary compact: outcome, commit hashes, tests, unresolved issues, relevant paths.
* Failure: `%{delegation: :failure, id: id, from: child_name, reply_to: parent_name,
  kind: :halted | :exit | :start, reason: reason, receipt: receipt}`.

Failures report a halted budget/context/node-budget/usage-limit/restart-brake/log-failed/
start-failed condition, or process death. Death is a lifecycle report, not a claim that
supervised restart failed: watcher re-resolves by name and watches the new pid. A halted
reason is enqueued once per transition; unhalting permits a later repeat. The parent chooses
whether to retry, unhalt or delegate a successor. Results mark watchers terminal but do not stop children, change limits or kill tasks.
Watchers exit only after all pending deliveries are acknowledged. Protocol messages are cooperative, not
cryptographic authentication; the harness is a shared trusted VM.

`NanoAgent.start` executes in the **calling eval**, preserving harness `started_by`
and dashboard parent nesting. Neither MCP setup nor monitoring moves start to a worker.
Outside an agent eval supply `parent:` explicitly. `adapter:` is an injected NanoAgent-
compatible module for scripted no-spend tests, not a provider configuration.

## Watcher durability

Independent unlinked watchers monitor deaths and poll `NanoAgent.info` every 250ms
(`poll_ms:`); polling deterministic state is free of model turns. Durable compact handle
manifests live under `<state_dir>/delegations` (`storage_dir:` override). Terminal reply synchronously
persists its result before returning to the child's eval (so a subsequent child exit
cannot race a false failure). Atomic same-directory rename replaces the manifest.
**Results and lifecycle failures use a durable outbox**: they remain on disk until
`ack(event)` succeeds. Delivery waits for the parent's stable name to exist; parent
absence does not suppress later delivery. Retries every 5s (`retry_ms:`) reuse the
same receipt, supporting deduplication. Receipt includes id/name/parent/storage_dir
and delivery_id. Acknowledgment removes just that entry; a terminal watcher removes
its manifest and exits once the queue is empty. Duplicate acknowledgments are safe. **After node restart or watcher loss call
`Nano.Delegation.restore()`** (boot integration or a successor eval). `watch(job)` also
resumes one watch idempotently. Restore does not call models or restart stopped children.
Malformed manifest files return per-file errors without blocking other recoveries.
No automatic boot hook is installed by this standalone module. Parent boot integration
should invoke restore after StateStore/Registry initialization. Restarts may redeliver
unacknowledged receipts (at-least-once, not exactly-once delivery); process results
idempotently by receipt id and acknowledge only after recording them.

Starts return `{:ok, handle}` or `{:error, reason}`. A provider start failure also sends
`:start` failure to the named parent. If child starts but persistence/watch fails, the
error explicitly includes `stage: :watch`, child name/pid/handle so it is not silently
orphaned. Validation/pre-read/worktree/MCP failures are returned synchronously. Retained
workspace paths in start errors allow recovery.

## MCP

Optional `mcp:` servers are connected through Nano.MCP before the child is started:

```elixir
mcp: ["configured-files", {"custom", [config: %{"command" => "/path/server"},
  subscribe: ["file:///brief.md"]]}]
```

Each entry is a configured server name (`/app/config/mcp.json`) or `{name, keyword_options}`.
Connect options pass through to Nano.MCP, excluding `subscribe:` resource URIs. Connection
uses `recipient: child_name`, then explicitly watches/subscribes the stable child name.
Public capabilities and all paginated tool schemas enter the **child's prompt**; schemas
are removed from the **parent's returned handle**. Child calls `Nano.MCP.call_tool` from
eval; its prompt includes the named server and usage example, so discovery costs no turns.
Credentials in connect config never enter the prompt, handle or delegation errors.
Connections are shared named MCP resources; delegation deliberately does not disconnect
shared servers on partial failures/completion. Parent/MCP owns their lifecycle.

`mcp_max_bytes:` defaults to 32,768 for complete metadata. Oversized/spilled schema results
fail setup rather than pretending the child knows the tools; pagination loops are refused.
No MCP connection is touched when the option is absent. If Nano.MCP is unavailable and
MCP was requested, setup returns a clear error. `mcp_adapter:` injects the MCP API for
scripted no-spend tests. A `mcp_setup:` callback overrides direct integration, accepting
`(child_name, servers)` and returning `{:ok, public_handles}` or `{:error, reason}`. Return
only public identifiers/capabilities, **never credentials or tokens**. Callback authors
are responsible for any discovery/setup before returning.

## Verification

`MIX_ENV=test MIX_BUILD_ROOT=/tmp/nova-delegation-build mix test test/nano/delegation_test.exs`
uses scripted fake agents, unique run directories, no model calls or API spending.
It verifies required settings, pre-read hash/change/cap behavior, shared composition,
idle starts, MCP-before-start callback, lifecycle halt/death, named terminal reply,
durable watcher/outbox recovery across absent parent/restart, duplicate receipts/ack,
corrupt manifest isolation, and real local git worktree/build isolation.

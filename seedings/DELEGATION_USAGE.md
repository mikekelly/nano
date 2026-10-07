# Delegation

`Seedling.Delegation` starts ordinary named NanoAgents with their own context. No
new harness tools or model calls are needed to set them up.

```elixir
{:ok, job} = Seedling.Delegation.subagent("scout",
  identity: "Repository scout; report findings, do not edit.",
  prompt: "Find the cause of the failing parser tests.",
  pre: ["/app/NOTES.md", "/app/lib/parser.ex"],
  message: "Begin now.", notify: "planner",
  max_turns: 80, max_tokens: 2_000_000, max_context: 130_000)
```

For an agent, end the turn with `idle` and the result arrives as an event, costing
no model turns while waiting. **Do not call `await` from an agent eval**: that
blocks a transient eval process, not the agent mailbox. `await(job, milliseconds)`
is for IEx/test/operator processes and returns `{:ok, result}` or `{:error, reason}`.
Address the child normally with `NanoAgent.whereis("scout")` and `send/2`.

## Options and return

`subagent(name, opts)` returns `{:ok, %{name:, pid:, ref:, reply_to:, worktree:,
pre:, mcp:}}` or `{:error, reason}`. The `pre` manifest contains paths, full SHA256,
original byte sizes and truncation flags, **not file contents**, keeping the
parent's return compact. The task, identity and snapshots live only in the
child's prompt. Example: two 8 KB prereads cost the child roughly 4,000 input
tokens; parent receives two metadata entries rather than those 4,000 tokens.
No model-backed token measurement is claimed; actual provider accounting is in
`NanoAgent.info(name).budget` and logs. Setup itself makes zero model calls.

- `prompt:` job body; `identity:` reusable role string. Node facts come from the
  configured system-prompt template, composed unchanged before these sections.
  The harness fills its existing placeholders (also if present in job/pre text).
- `pre:` at most 32 regular files, each <=64 MB, absolute paths recommended.
  Full-file streaming SHA256; UTF-8 head limited by `pre_file_bytes:` (8,000 by
  default, at most 24,000) and total `pre_max_bytes:` (24,000, at most 96,000).
  A changed file can be checked by hashing it again with `preread([path])`.
  Read errors abort startup. Hash and snapshot are from the same pass, but a
  file concurrently edited during the pass is not an atomic filesystem snapshot.
- `model:` includes provider (`openai-codex/...` or an OpenRouter model);
  `reasoning:`, `max_turns:`, `max_tokens:`, `max_context:` pass through to
  `NanoAgent.start`. Omitted values use node defaults, **not parent settings**;
  zero means unlimited. Caller is responsible for generous but finite budgets.
- `message:` optional first event. Without it, child starts idle; `start_idle:
  false` sends a small begin event. Setup completes before either event.
- `notify:` parent agent name preferred; inferred from the eval's `$callers` by
  default. A pid works for an operator, but does not survive its death.
- `worktree: [revision: "HEAD", path: "/data/seedling/worktrees/scout"]` creates
  a detached git worktree from `/app`. `repo:` overrides the repository. Omit
  this option for no isolated checkout. Worktree setup errors abort startup.
  All git commands use argv, not shell interpolation. Worktrees are retained
  after success **and after later setup failure**: inspect and remove explicitly
  with `git worktree remove PATH`. Never assume `/app` includes uncommitted files
  in a worktree. Eval still runs on the same BEAM node; use explicit paths and
  shell `cwd:`. Worktrees isolate files, **not privileges, Elixir modules or OS**.

## Optional MCP

`mcp: [{"server", config}]` connects and waits for readiness before the child is
started; `mcp: ["existing-server"]` attaches a durable named listener to an
already configured server. Server names are in the handle's `mcp` field and
child prompt. Config is the `Seedling.MCP.connect` string-key map (command/args/
env/cwd or url/headers). Use `Seedling.MCP.tools`, `call_tool`, `resources`, etc.
via eval; see MCP_USAGE.md. Setup failures abort the child and return an MCP
error. Connections/listeners are shared and intentionally retained on later
startup failure and completion; parent must unlisten/disconnect when appropriate.
No fake success when module unavailable: `{:error, :mcp_unavailable}`.

Preread paths are resolved against the node cwd, **not** the new worktree. Pass
absolute worktree paths if pre-reading an existing checkout; a freshly created
worktree's files can be read by the child at the explicit worktree path.

## Reply protocol


The child prompt contains a ready-to-use, valid Elixir call:

```elixir
Seedling.Delegation.report_job("<0.123.0>", %{summary: "done", commit: "abc"})
```

Use the actual address from the child's prompt, not the example. Alternately,
from the first message's `reply_to` pid and `delegation_ref` reference:
`Seedling.Delegation.report(reply_to, ref, result)`. Printed pids/references are
not Elixir source; `report_job` avoids rebuilding a reference. These helpers
identify the agent owning the eval, not the eval task's transient `self()`.

Parent events:

- `{:delegation_done, ref, name, result}` — explicit child report.
- `{:delegation_failed, ref, name, {:halted, reason}}` — any harness halt,
  including budget/context, usage limit, node budget or start failure.
- `{:delegation_failed, ref, name, {:exit, reason}}` — original child died,
  even if the harness restarts it. `:noproc` can indicate death before monitoring.

The reference-based report checks both the job reference and declared child pid;
`report_job` checks the declared child pid and uses a unique watcher address.
These are routing checks, not authentication: Erlang messages have no sender,
and arbitrary code can forge fields. Wrong fields are ignored. Duplicate reports
after the first terminal result are suppressed (the watcher is gone). Keep results
short or report an artifact path: result payloads are not automatically truncated.

The independent watcher accepts one terminal report, then exits. Halts are
polled every 100 ms, death is monitored. Reports already queued take precedence
at the next receive. A result means a report, not agent termination; the child
can remain running/idle, and the parent must stop it when appropriate. Plain
assistant words do not count as a report. There is no job timeout: an idle child
can wait indefinitely, and the parent should enforce a deadline when needed.
Named parents resolve again on delivery (up to 60 s retries), surviving process
restart. Delivery has no acknowledgement/durability and a send-to-dead-pid race
is possible. Watchers and handles do **not** survive node/container restart;
child inline prompt still contains the old reply address. Start a new job after
such restart. No cross-agent security boundary is promised by this protocol.

The original `NanoAgent.start` runs synchronously in the parent's eval, preserving
`started_by` for the dashboard. Prompts encourage delegating large work and
handover around half context before exhaustion.

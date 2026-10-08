# Delegation

`Seedling.Delegation` is an eval library, not a new harness tool. Start an independent
job in one eval, then use the harness's `idle` tool to wait without polling turns.

```elixir
{:ok, child} = Seedling.Delegation.subagent("review-ui",
  model: "openai-codex/gpt-6.1-sol", reasoning: "high",
  max_turns: 60, max_tokens: 1_000_000, max_context: 272_000,
  flavour: :reviewer, prompt: "Review the UI changes and report findings.",
  pre: [{"/app/docs/design.md", offset: 1, limit: 100}],
  worktree: [path: "/tmp/review-ui", revision: "foundation-commit",
             branch: "seedling/review-ui"],
  message: "Begin")
# In the child:
Seedling.Delegation.report("review-ui", "Reviewed commit abc; 12 tests pass; no blockers")
# In the parent, if recovering a result after a restart:
Seedling.Delegation.result("review-ui")
```

The provider is selected by the explicit model slug using `Nano.Model`; models,
reasoning, token/turn/context limits must all be supplied, never inherited silently.
`max_context` must be at least 8192, and the prompt must leave 5120 estimated tokens
for kickoff, worktree metadata and a response. Zero token/turn caps mean unlimited,
so choosing them is an explicit spending decision. The operating principles partial
mentions automatic compaction, but delegation itself does **not** implement compaction.
Install the companion compaction capability to keep long-lived children working.

## Composition and pre-reading

The prefix is the node's existing `priv/system_prompt.txt` (the facts remain owned by
the harness), then `priv/seedling/prompts/principles.txt`, then one or more flavours,
then a standard parent/reporting protocol and the job, then pre-reading. Builder,
reviewer and scout are supplied. `flavour: :reviewer` selects one; `flavours:
[:builder, :reviewer]` composes several. The shared prefix is aligned and cacheable.
`root:`, `facts_file:` and `partials_dir:` can select another checkout's files without
loading code. `compose(name, opts)` returns `{:ok, template, manifest}` without starting.

Pre-reading is in the child's system context **before** its first model call, even
when it starts idle. Each manifest entry states absolute path, SHA256 of the full file,
SHA256 of the included excerpt, one-based offset, included and total line counts.
`changed?(entry)` returns `{:ok, boolean}` (or a file error). Default cumulative cap
is 32KB, including markings; oversize and invalid offsets return actionable errors.
Choose explicit paging or `pre_max_bytes:` rather than relying on silent cuts.
Binary files are refused. Reserved harness `{{placeholders}}` in a pre-read excerpt
are refused too: NanoAgent would otherwise rewrite their bytes after hashing. Page
around those markers or read those source files explicitly in the child.

## Isolation and first turn

Worktrees are optional (a job with none is instructed to remain read-only).
If requested, `path`, `revision` and a new `branch` are all mandatory. Git resolves
that explicitly named revision to a commit and starts a worktree at that commit;
uncommitted edits are never copied. Existing directories are not adopted or overwritten.
Worktree creation failures return `{:error, {:git, output}}`. The returned metadata
contains the resolved commit and isolated build instructions. Use `MIX_ENV=test` and
a unique `MIX_BUILD_ROOT` on the **whole subprocess environment**, not just the first
command before `&&` (use `Seedling.Tools.sh(cmd, env: [{"MIX_ENV", "test"},
{"MIX_BUILD_ROOT", "/tmp/job-build"}])` or export them for the whole shell); seed Mix currently deletes MIX_BUILD_ROOT for test builds
and uses the worktree's own `_build/test`. Delegation never changes global env, deletes
worktrees or merges child commits. If agent setup later fails, inspect/remove the
created worktree yourself; preserving it avoids deleting work someone may need.

Starts run **directly** in the caller's eval, so the dashboard's `started_by` ancestry
remains correct. Parent defaults to the calling agent's registered name, not the
short-lived eval task. Outside an agent eval, give `parent:` explicitly; prefer a name
to a pid for restart safety. The child always starts idle: failure watches and optional
`mcp: ["server"]` connections are set up before delivering `message:`. Delivery is deferred across **all**
requested MCP servers, then released only after every connect reports ready; even
connecting/notification events cannot wake a partial first turn. A constructor monitor
terminates a half-setup child and reports a durable error if its eval task dies or is
timed out. Explicit setup failures also disconnect the child's server attachments.
`mcp_options:` passes connection options such as an isolated `instance:`. The guard
does not suspend any agent process. The RPC event gate is in memory: after a whole-node
restart normal MCP event forwarding resumes, while durable subscription intent and
parent watch/result records are restored. MCP setup failures
produce an error report and terminate the idle child. With no message it remains idle until ordinary events arrive (MCP lifecycle events
can wake it after setup is ready);
`start_idle: false` supplies a short kickoff. `tell(name, message)` addresses live names.

## Reports and failure protocol

A parent receives ordinary mailbox events, visible in its dashboard timeline:

```elixir
%{type: :delegation, child: "review-ui", child_id: "review-ui-...",
  status: :ok, summary: "...", sender_name: "review-ui", sender_pid: pid,
  report_id: "unique-event-id"}
```

`report/3` accepts `:ok` (default) or `:error`, at most once per job. Summaries are
bounded to 8KB (longer ones are shortened with a marker); put details in files. The
manager also emits `:halted` (including budget and context failures), `:exited` and
`:restarted`. Process exits are warnings, **not** an assertion that the harness failed
to restart the child; always address the name. A replaced child id produces an error.
The manager monitors processes and subscribes to the harness's existing log broadcasts;
a one-second code-side timer covers log/state races and PubSub restarts without making
any model calls. `result/1` is the most recent event, including a failure warning, or nil.

Watches, results and undelivered reports are atomically persisted under
`Application.get_env(:nano, :delegation_dir)` or `state_dir/seedling-delegation`.
If a named parent is temporarily absent, events wait until it returns. Delivery is
at-least-once across crashes; deduplicate with `report_id` where necessary. Pid-only
parents cannot survive restart. Add `Seedling.Delegation.Manager` to the application's
children after Nano.StateStore to recover at node boot. `ensure_started/0` lazily adds
it to Nano.Supervisor for an already-running node. No harness mutation is required.

## Tested

Tests use the seed's real local fake provider, not paid calls. They cover composed
partials, exact hashed pre-reading and changed-file detection, cap/marker validation,
explicit worktree revision and edit isolation, zero-turn idle starts, preserved ancestry
from a real parent eval, reporting and manager-kill recovery, named-parent queued delivery,
budget/death/restart alerts, and a stopped child whose DOWN was lost during watcher recovery. Guard tests cover
constructor death and stale-name reuse. A real two-server MCP integration test uses
a private file-controlled handshake gate to prove there is **no first model request**
while only one server is ready, then releases it and observes the call; partial setup
errors and constructor death are also verified to terminate the child without a turn. The implementation was also used live to start the MCP
builder in a worktree at explicit shared-foundation commit `eee9dda`; ancestry was
`started_by: "orion-delegation"` and its pre-read hashes were returned in the single-eval
start result. This is not a claim of full node-restart testing; persistence and manager
recovery are covered in-process, and startup integration belongs to the application.

The live start's compact inspected result was 793 bytes (~397 tokens under the
harness's conservative two-bytes-per-token estimate), versus 26,150 bytes in the
child's composed prompt. This measures returned metadata, not the parent's eval source,
API envelope or exact provider tokenizer; the child transcript is never returned.

Final independent validation after MCP integration: 30 focused capability tests
(11 delegation, 3 multi-server integration, 16 MCP/schema) and `mix test --seed 0`
299/299 passed, followed by warnings-as-errors compilation and owned-file format checks.
An implementation-run shell environment scoping mistake caused a worktree's prod
compile to overwrite shared build artifacts; no live modules were loaded by that
command. The parent restored the shared priv symlink and was told to rebuild integrated
prod artifacts before restart. The corrected validator sets env on the entire subprocess;
this operational failure is not a passing test claim.

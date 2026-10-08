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
a unique `MIX_BUILD_ROOT`; seed Mix currently deletes MIX_BUILD_ROOT for test builds
and uses the worktree's own `_build/test`. Delegation never changes global env, deletes
worktrees or merges child commits. If agent setup later fails, inspect/remove the
created worktree yourself; preserving it avoids deleting work someone may need.

Starts run **directly** in the caller's eval, so the dashboard's `started_by` ancestry
remains correct. Parent defaults to the calling agent's registered name, not the
short-lived eval task. Outside an agent eval, give `parent:` explicitly; prefer a name
to a pid for restart safety. The child always starts idle: failure watches and optional
`mcp: ["server"]` connections are set up before delivering `message:`. MCP setup failures
produce an error report and terminate the idle child. With no message it remains idle;
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
budget/death/restart alerts, and a stopped child whose DOWN was lost during watcher recovery. The implementation was also used live to start the MCP
builder in a worktree at explicit shared-foundation commit `eee9dda`; ancestry was
`started_by: "orion-delegation"` and its pre-read hashes were returned in the single-eval
start result. This is not a claim of full node-restart testing; persistence and manager
recovery are covered in-process, and startup integration belongs to the application.

The live start's compact inspected result was 793 bytes (~397 tokens under the
harness's conservative two-bytes-per-token estimate), versus 26,150 bytes in the
child's composed prompt. This measures returned metadata, not the parent's eval source,
API envelope or exact provider tokenizer; the child transcript is never returned.

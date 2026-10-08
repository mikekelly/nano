# Compaction entry point and operations

Use `Seedling.Compaction` (module docs describe the reusable API). Every `NanoAgent`
uses it automatically before its model-call context guard; there is no opt-in setting.
For an early checkpoint from eval:

```elixir
Seedling.Compaction.provide_summary("""
## Goal
Finish the delegated task and report to the parent.
## Constraints & Preferences
Work only in the assigned worktree. Do not reload shared harness code.
## Progress
### Done
Tests pass; the implementation is committed.
### In Progress
Reviewing the parent integration.
### Blocked
None.
## Key Decisions
Keep external requests verbatim because those are the obligations being answered.
## Next Steps
Send the commit and test results to the parent.
## Critical Context
Exact paths, function names, errors, commit hashes, outstanding recipients and goals files.
""")
```

A voluntary submission returns `:ok` or `{:error, reason}`. It must come from the
agent's active eval, not an operator RPC or another process. It commits after all calls
in that model response have results. A failing, interrupted or timed-out submitting
eval cancels the checkpoint. Bindings and eval side effects are not rolled back.
A later successful submission in the same response replaces an earlier submission.

## Model lifecycle

The last provider-measured context plus a cautious estimate of additions triggers
compaction when less than 16,384 tokens remain. For models below 65,536 tokens the
reserve scales to a quarter-window. The harness appends an explicit checkpoint note
to the existing tip, calls the same provider/model/reasoning, and extracts a literal
summary from exactly one `Seedling.Compaction.provide_summary("...")` eval AST. It
does **not** run that eval or any other code returned during automatic compaction.
All attempts and invalid outputs remain logged; they never enter the conversation.
Invalid responses retry the same request up to three times. Transport failures use the
normal timeout, backoff and retry lifecycle, without changing the checkpoint request.
The normal model-call timeout applies (default permits long streamed replies).

Summaries are bounded at an estimated 12,000 tokens (one per two JSON bytes). The prompt
aims for 2,000–8,000 tokens and fixed headings. The output bound is at most 12,000 when
the provider supports one; ChatGPT does not support an output limit. Like the harness's
existing input estimate, this is cautious on ordinary text, not an exact tokenizer.

First brief and newest external events survive word for word, in original order, within
about a fifth-window allowance. The first brief survives even when larger than that
allowance. Original event image references survive with their immutable attachments and
are charged conservatively to the allowance. Tool/eval images and explicitly identified
child reports are results: the model must carry their findings in the summary. Child
reports are recognized from map `sender_pid` or `sender` matching an agent whose
`started_by` is this agent; unidentified senders remain external conservatively. Erlang
does not authenticate message senders, so this classification is not an access-control
boundary. Harness budget notes and all agent calls/results are replaced by the summary.
Queued arrivals during compaction are delivered **after** the summary.

The summary preamble identifies the harness, the agent's own model as its author, why
the checkpoint exists, and the exact full JSONL log path. Context measurement is reset
to a fresh-prefix estimate; identity, pid, bindings, children, mailbox, budgets, disk
files and cumulative cost remain unchanged. The next call is an uncached prefix.

## Operator recovery and diagnostics

Log events: `compaction_started`, `compaction_rejected`, `compaction_completed` (including
summary and full record path). Status stays `thinking`/`running_tool` during work.
`NanoAgent.info(name).halted == :compaction_failed` means three invalid responses.
`NanoAgent.unhalt(name)` resets checkpoint attempts and retries the original request;
operator notes and queued arrivals are delivered only after a successful checkpoint.
Provider/agent/node spend limits still apply to checkpoint calls. A valid summary can
be saved while the agent remains halted for a spend cap; unhalt resets only the normal
limits that the existing harness resets. Neither compaction nor its retries bypass
logging or the hard context guard.

An oversized first brief, an oversized system prompt, or a sudden large tool/event
addition can still hit the hard context guard before any valid checkpoint request can
fit. This is intentional: never send a request that cannot fit. Use bounded tools and
checkpoint voluntarily before huge work. A checkpoint that cannot shrink enough is
checked once against the hard guard rather than repeatedly summarized forever.

## Migration and safe reload

State is persisted in the agent's normal state file; no new global process or table is
required. New fields are filled lazily for live older agents and at restoration:
`compaction`, `compaction_summary`, `compaction_fresh`, `compaction_events`,
`compaction_pending_events`, and saved `input_modalities` (legacy defaults text-only).
Old rendered user events are recovered from the transcript, excluding harness notes.
Legacy state lacks exact child-report metadata, so those events remain external. If an
old batched user message has images but lacks per-event metadata, all its images are
assigned to its first event to avoid silently losing attachments.

Do not compile or hot load `NanoAgent` into a shared node without operator approval.
Test a separate `MIX_ENV=test` build first; never rewrite the running shared prod build.
For an approved deployment, load supporting `Seedling` modules **before** the harness.
Live model responses and evals started by the previous harness version are accepted;
the old eval four-element success tuple and the new image-aware five-element tuple
are both handled. New calls use the image-aware tuple, while public `run_eval/2` and
`eval/3` retain their original return shapes. If the process dies while an automatic
checkpoint is in flight, it resumes that checkpoint; restart notes queue behind it.
A process/node restart changes the system pid prompt truthfully, so its request prefix
will no longer be byte-identical to the pre-restart provider request.

Prefer a controlled restart for deployment when practical. Existing rendered system
prompts stay unchanged until a restart; editing a template does not rewrite a live
agent's system prompt. Keep the default/agent prompt accurate about automatic compaction
and point orientation at `Seedling.Compaction`, rather than repeating this document.

Tests use scripted HTTP providers and real supervised GenServers, without provider
spend. The real-provider crossing-threshold acceptance smoke is an operator-coordinated
step after approved deployment; do not represent a scripted summary as that smoke.

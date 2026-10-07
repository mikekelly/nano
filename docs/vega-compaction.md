# Vega automatic compaction

Every NanoAgent now checks its pending request (both event deliveries and tool-loop
continuations). Above `max_context - 16_384`, a removable older prefix is summarized
by a **separate, tool-free request with strictly bounded accepted output**. Recent messages are
kept verbatim, with cuts only where all assistant tool calls have results. The agent
retains its pid/name/mailbox/bindings. Incoming events queue during summarization.

Configuration (application env `:nano`, defaults shown):

- `:compaction_reserve`: 16_384 tokens, an absolute reserve, not a fraction.
- `:compaction_keep_tokens`: 20_000 (also capped at one quarter of agent context).
- `:compaction_max_output`: 13_000 (also capped at one eighth of agent context).
- `:compaction_timeout_ms`: 120_000; task is killed on timeout.
- `:compaction_model`: optional model slug; defaults to the agent's own model for
  both OpenRouter and Codex agents. No keys or provider settings are changed.
  Summarizer window and reasoning support come from the provider's model list.

OpenRouter receives an actual wire output cap. The Codex backend refuses the
`max_output_tokens` wire field, so **Codex cannot guarantee a provider-side generation
cap**. Its separate summary request uses the lowest supported reasoning effort,
an explicit prompt length limit, a conservative input/output reserve, and strict
post-return checks of both serialized summary size and reported completion tokens.
Overlong or truncated responses are rejected, never silently sliced or installed.
This supports available Codex-only nodes without pretending its backend can cap
output. The separate call never competes with the agent's own reply.

The summary is in the agent's persisted transcript and in `compaction_completed`
log entries. The continuation note truthfully names the harness and model and points
at `<log_dir>/<agent-id>.jsonl`, whose original model responses/tool results remain
untouched. Context usage is recalibrated conservatively from full request JSON bytes
until the next provider measurement. Summarizer token usage/cost counts toward agent
and node budgets, but not agent turns (those count its own model requests).

Errors, empty/truncated/oversized summaries, unsupported providers, timeout and
insufficient shrink leave the old transcript intact and explicitly halt with
`:compaction_failed`, with a harness note and log. Operators can fix the problem and
unhalt. No original-history model request is sent on failed compaction. With no
removable complete exchange, the normal context guard remains authoritative: a
single enormous tool exchange cannot be severed to make it fit. This does not remove
budget/context guards or recover a response already beyond the hard context cap.

## Validation and deployment

Run in the worktree, isolated from the live node:

```sh
MIX_ENV=test MIX_BUILD_ROOT=/tmp/vega-compact-build mix test
```

`test/vega_compaction_test.exs` starts actual supervised NanoAgents against the
scripted HTTP provider (not real paid inference), drives context across threshold
inside a tool loop, and checks identity, bindings, queued messages, verbatim suffix,
durable summary, accounting, boundary selection, failure and timeout behavior.
Existing context-guard test also checks successful compaction after unhalt.

Parent integration/reload procedure (requires explicit approval): cherry-pick this
commit; optionally configure a cheaper summarizer model if credentials exist;
compile/test outside live production build first. Load `Vega.Compaction` and then
`NanoAgent` from the integrated source with `Code.compile_file/1` only after review.
No live harness modules were loaded by the implementation agent. Existing state maps
need no new mandatory fields; tasks already in flight retain existing model/eval
handlers. Do not reload a stale worktree over sibling NanoAgent edits.

### Live Codex validation (2026-10-07)

After parent-approved integrated harness reload, the implementation agent ran a
real subscription test on `openai-codex/gpt-6.1-sol`, reasoning `low` (`off` is not
supported by the live catalog), name `vega-compact-live`, context 24,000. Its lean
system instructed idle only, never eval. A 26,999-byte inert numeric event produced
measured context 12,273, above the 7,616 compaction threshold. A second small event
triggered automatic compaction at a complete exchange boundary:

- Summary request: 12,220 prompt + 117 completion tokens.
- Conservative context after persisted summary: 1,090.
- Resumed actual agent request: 470 prompt + 14 completion; measured context 484.
- Same pid throughout; saved transcript contained the harness summary; idle/no halt.
- Total usage 25,094 includes summarization, with two agent turns (not three).

Full retained record: `/data/logs/vega-compact-live-ccb2fd.jsonl`; machine-readable
inspected evidence: `/tmp/vega-compact-live/evidence.txt`. The test agent and its
tasks were stopped afterwards. No node settings or credentials were changed/logged.
Live provider returned no price, so cost remains unknown, not claimed free.
The isolated implementation suite passed all 254 tests after the Codex follow-up.

### Full-window histories

The old serialized prefix is streamed through bounded UTF-8 data slices if it cannot
fit conservatively in a single summary input. Each tool-free call receives the
previous capped cumulative digest plus the next chronological slice; the final
capped digest replaces the prefix. Slice boundaries may bisect data records, but
never provider tool exchanges: those records are inert text in a user message.
Every byte of the old prefix is covered exactly once. The actual kept transcript
still cuts only at complete exchanges. Input selection includes JSON escaping,
system instructions and prior digest, plus output cap and 512-token headroom.
The cap also respects the summarizer's own window/output limit.

`:compaction_max_stages` defaults to 32 to bound pathological work. Ordinary full
272k contexts generally require only a few calls. All completed stages (including
a rejected response) add node tokens once; summed usage and cost are returned for
agent-budget accounting. A later failure keeps the agent's original history intact.
The existing overall task timeout remains authoritative; operators can explicitly
increase `:compaction_timeout_ms` for unusually slow/many-stage providers. A task
killed by the harness timeout can have already booked node tokens but cannot return
its unfinished aggregate to the agent; no summary is installed in that case.

For per-invocation cost/latency tuning or inexpensive real multi-stage validation,
`Vega.Compaction.summarize(model, old, agent_window, stage_input_tokens: 8_000)`
additionally caps conservative stage input without changing global settings. The
provider window/output reserve still bounds it from above; accumulated digest and
instructions count within this input cap. Invalid nonpositive caps are errors.
Automatic harness calls retain the default `summarize/3` interface and policy.

### Real multi-stage validation (2026-10-07)

Parent loaded the reviewed streaming/tuning implementation. A real Codex-only
`summarize/4` task processed 21,227 bytes of chronological inert planning history
with `stage_input_tokens: 6_000`, agent window 24,000, and no settings changes.
It returned **three completed stages**, summed usage **4,868 prompt + 503 completion
 tokens**, and a final digest preserving the earliest final-report-path commitment
(`/tmp/vega-compact-live/report.md`), provider-exchange boundary decision, and latest
`validate_restart` unresolved question/no-deployment limitation. The provider did
not supply cost. Evidence: `/tmp/vega-compact-live/staged-evidence.txt`.

An initial larger 62,987-byte validation task completed, but its `Task.async_nolink`
result was addressed to the expired eval caller and could not be recovered (node
usage was booked). The corrected small test explicitly sent its result to the
agent pid. Only the recovered three-stage run is claimed as passing evidence.
No settings or credentials were changed, and no test task remains running.

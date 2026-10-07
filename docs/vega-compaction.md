# Vega automatic compaction

Every NanoAgent now checks its pending request (both event deliveries and tool-loop
continuations). Above `max_context - 16_384`, a removable older prefix is summarized
by a **separate, tool-free, output-capped OpenRouter request**. Recent messages are
kept verbatim, with cuts only where all assistant tool calls have results. The agent
retains its pid/name/mailbox/bindings. Incoming events queue during summarization.

Configuration (application env `:nano`, defaults shown):

- `:compaction_reserve`: 16_384 tokens, an absolute reserve, not a fraction.
- `:compaction_keep_tokens`: 20_000 (also capped at one quarter of agent context).
- `:compaction_max_output`: 13_000 (also capped at one eighth of agent context).
- `:compaction_timeout_ms`: 120_000; task is killed on timeout.
- `:compaction_model`: OpenRouter slug. Default is the agent model if it is on
  OpenRouter. **Codex agents require an explicit OpenRouter summarizer**: ChatGPT
  does not accept an output cap and is deliberately not used as the summarizer.
  No keys or provider settings are changed by this capability. Summarizer window
  and output support come from the provider's model list.

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
commit; configure a capped OR summarizer for Codex agents if credentials exist;
compile/test outside live production build first. Load `Vega.Compaction` and then
`NanoAgent` from the integrated source with `Code.compile_file/1` only after review.
No live harness modules were loaded by the implementation agent. Existing state maps
need no new mandatory fields; tasks already in flight retain existing model/eval
handlers. Do not reload a stale worktree over sibling NanoAgent edits.

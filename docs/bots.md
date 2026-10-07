# Consumer bots

API: `Vega.Bots` module docs; planned consumer surface `/bots`, operator dashboard `/`.
`docs/bots-design.md` records rationale and UX. Bot identity is independent of a stable
`bot.<botid>.<sessionid>` NanoAgent; each pair has its own restored transcript.

## Service and persistence

Parent application integration: add `{Vega.Bots.Server, root: "/data/vega"}` **after**
PubSub, StateStore and AgentSupervisor. No lazy eval-linked processes. Tests start
supervised instances with a unique root and `name:`; callers pass `server: pid`.
All service records have string keys. Mutations persist before broadcast/dispatch.
The durable outbox retries failures and requester-name answers; duplicate requests and
answers are idempotent by request ID. Agent delivery is at-least-once; bot prompts
instruct message-ID deduplication. Bot-to-bot posts do not automatically fan out.

Create bots with explicit model, reasoning, max_context, max_turns and max_tokens.
No model credentials or node settings are modified. Provider validity is checked by
NanoAgent on session-agent startup; a failed dispatch becomes a visible retryable error.
Cheap snapshot reads do not call into busy/suspended agents. Provider/status polling
uses NanoAgent.info (ETS), not GenServer calls to agents.

## Posting and memory

```elixir
{:ok, bot} = Vega.Bots.create_bot("Muse", description: "A practical companion",
  voice: "Kind and concise", model: "openai-codex/gpt-6.1-sol", reasoning: "low",
  max_context: 272000, max_turns: 0, max_tokens: 0)
{:ok, session} = Vega.Bots.create_session([bot["id"]])
Vega.Bots.send_message(session["id"], "I prefer window seats")
# Agent eval, not prose responses:
Vega.Bots.post(session["id"], bot["id"], "I'll keep that in mind.")
Vega.Bots.remember(bot["id"], "Person prefers window seats",
  provenance: %{"session" => session["id"]})
```

Memory identity is `bot:<id>` via sibling Vega.Memory, retrieved at most four entries
and 5000 JSON bytes per human turn. This currently inherits lexical retrieval, not
semantic reasoning. Explicit remember avoids turning every utterance into a fact.
The shared harness compaction must be merged and active for real long bot sessions;
bot prompt adds personal preferences, decisions, commitments, open questions and
handled input IDs to the summary priorities. No copied compaction implementation.

## Human conduit

```elixir
{:ok, request} = Vega.Bots.request_human(bot["id"], "Which account should I use?",
  requester: "my-stable-agent-name", session_id: session["id"], request_id: "account-1")
# Person answers through UI or eval:
Vega.Bots.answer_request(request["id"], "My work account")
# Requester receives {:vega_human_answer, "account-1", "My work account"}.
# After safely recording/handling it:
Vega.Bots.acknowledge_answer("account-1", requester: "my-stable-agent-name")
```

Requester must be a stable registered agent name. Answers remain in durable request
state and retry by name every 30 seconds until explicitly acknowledged, even if requester
was absent or restarted. A cast is not proof of receipt; correlation+ack is the protocol.
Never send credentials as plain human answer/chat; use node settings via operator UI.
Without explicit session, newest session involving the bot is used, or one is created.

## Evidence and current limits

`MIX_ENV=test MIX_BUILD_ROOT=/tmp/vega-bots-build mix test test/vega/bots_test.exs`:
6/6 passing isolated backend tests (no real provider spend). Frontend pending separate
subagent. No modules loaded into the running node. Real Codex bot and compaction tests
wait for parent integration/fixed compaction and authorization.

Initial state snapshot uses Vega.Store's 4MB per-file cap. At cap a new message returns
`:store_too_large`, never discards old chat; partitioned/archived history is a future
scaling improvement. Snapshots currently return full chat history and are intended for
modest local use. File attachment support waits for sibling immutable Images validation
and hook; arbitrary file paths fail closed. Notifications planned for background open
browser tabs, not closed-tab push. Node remains unauthenticated like existing operator
API; this is not a multi-user authorization boundary.

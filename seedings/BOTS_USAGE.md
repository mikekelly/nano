# Bots: durable consumer conversations

Open `/bots` on the existing Phoenix endpoint. This is a trusted-local-node product
surface, **not a security boundary**: the operator API and agent eval remain unrestricted.
Do not expose the endpoint publicly without authentication. Bot session agents have the
same container and node privileges as other NanoAgents; "own computer" means isolated
conversation/bindings, not separate VMs or sandboxes.

## Plain-function API

All durable data uses string keys. `bots/0`, `sessions/0`, `requests/0` return lists;
`session(id)` returns a map or nil. Mutations return `{:ok, map}` or `{:error, reason}`.

```elixir
{:ok, muse} = Seedling.Bots.create_bot(%{name: "Muse", description: "Calm, concise companion"})
{:ok, scout} = Seedling.Bots.create_bot(%{name: "Scout", description: "Curious researcher"})
{:ok, chat} = Seedling.Bots.create_session([muse["id"], scout["id"]], %{title: "Our plans"})
Seedling.Bots.say(chat["id"], "Help me plan a trip")
# From a bot's own eval: the final model response is NOT displayed.
Seedling.Bots.post(chat["id"], muse["id"], "Here is our plan…")
Seedling.Bots.settings(chat["id"], %{notifications: true, quiet: false})
```

Subscribe with `Seedling.Bots.subscribe/0` (Phoenix PubSub `seedling:bots`);
changes emit `:bots_updated`. Only explicitly posted chat messages are consumer-visible:
operator logs, evals, harness notes and arbitrary final model responses are never streamed
into the conversation. Content is rendered escaped; no model-supplied HTML executes.

## Human requests: one conduit for every agent

```elixir
{:ok, request} = Seedling.Bots.request_human(muse["id"], "Which region should we deploy in?",
  session_id: chat["id"], reply_to: "my-agent", timeout: 86_400_000)
# The person answers in /bots, or equivalently:
Seedling.Bots.answer(request["id"], "EU")
# my-agent receives {:bot_answer, request_id, "EU"}
```

Prefer a registered agent **name** as reply_to so it resolves after restart. A pid is
supported but cannot survive a node restart. Without reply_to, calls from agent eval use
the calling agent (not the transient eval task); ordinary callers use self(). Requests,
questions, answers, expiry and pending/answered status persist. Duplicate answers reject.
If no session_id is given, an existing session containing the bot is selected; create one
first. There is no automatic new session for missing bots. Answer delivery is best effort,
not an exactly-once durable mailbox: offline recipients can inspect `requests/0` for their
persisted answer. Credentials should not be sent through plain chat or persistent memory.

## Conversation isolation, shared conversation, memory

One NanoAgent per bot/session pair (`Seedling.Bots.agent_name(bot_id, session_id)`) avoids
cross-session context-window leakage. Identity survives independently of those processes.
Multi-bot sessions share durable chat messages; each new human turn includes the last 30
messages from the shared conversation. They do not automatically trigger infinite
bot-to-bot reply loops. A small typed routing judgment chooses participants; on model
failure conservative fallback asks all participating bots. Agents must actually call
`post/3` to speak: no claim that an arbitrary model always obeys.

```elixir
Seedling.Memory.add(muse["id"], "The person prefers quiet hotels",
  source_session: chat["id"], tags: ["travel"])
Seedling.Memory.retrieve(muse["id"], "hotel", limit: 5, budget: 2400)
```

Memory is a per-bot disk-backed linked graph with source-session provenance. Retrieval
uses a bounded lexical/one-hop shortlist and optional typed small-model ranking. Bots
receive at most five nodes/2400 text bytes per turn; no entire memory dump. Bot prompts
ask them to save explicit durable preferences/facts. Learning is agent-mediated, not a
promise that every incidental remark becomes a correct memory. No secret redaction or
memory-edit UI is currently implemented; callers must avoid storing credentials.

## Automatic context maintenance and typed decisions

`Seedling.Decision.decide(:route | :memory | :compact | :summarize, state, opts)` validates
strict structured JSON output. See its module docs and `test/seedling_memory_decision_test.exs`.
Default small model: `openai/gpt-4.1-nano`; configure `:nano, :decision_model` or per-call
`model:`. OpenRouter key is needed for live decisions. `adapter:` supplies a fake in tests.
Confidence is self-reported, **not calibrated probability**.

The Bots service polls every 30 seconds. At 45% of a session agent's context limit,
`Seedling.Bots.Compactor` asks the decision model for a continuity summary and uses
`NanoAgent.compact(name, summary, expected_transcript_hash: hash)` only while idle.
It preserves counters, budgets, identity, system prompt, bindings, unread events and
original durable logs. A stale snapshot/busy agent is rejected and retried, never overwritten.
Only a successful compact of an agent halted specifically for context allows unhalting;
other budget/provider halts remain operator-controlled. For manual maintenance:

```elixir
Seedling.Bots.Compactor.compact(Seedling.Bots.agent_name(muse["id"], chat["id"]))
```

Summary failures/low confidence leave history intact. Large transcript inputs over the
Decision input cap (120KB), long non-idling turns, unavailable providers, and imperfect
summaries can still prevent seamless compaction. This is not a guarantee of never forgetting.
Two small live structured-output smokes succeeded but omitted the owner of one commitment,
even after strengthening the prompt: retain original logs and verify critical commitments.

## Persistence and configuration

`Seedling.Bots` is a supervised boot child (also lazily startable). Atomic JSON store defaults
to `<:nano, :state_dir>/bots.json`, override with `:nano, :bots_path`. Memory defaults to
`/data/state/bot_memory`, override `:memory_dir`. Back up these files alongside Nano.StateStore.
The bot store fails closed on unreadable/corrupt JSON rather than overwriting it: restore
from backup. No retention/migration/multi-user access control is implemented.

Configure session-agent provider with `:nano, :bots_model` (default node model), and
`:bots_reasoning` (default "off"). Each agent has a 64k context limit and 1M total token
budget. Compaction does not reset spending. No per-bot independent browser/computer,
file attachment storage, push service worker or guaranteed background notification delivery
is implemented. Browser notification permission and session opt-in are required; no
notifications are sent while the browser is closed.

## Validation

Targeted non-spending tests: `env -u MIX_BUILD_PATH MIX_ENV=test mix test test/bots_test.exs
 test/bots_compactor_test.exs test/seedling_memory_decision_test.exs` plus UI and compact-API
tests delivered with their modules. Run serially: these tests change application environment
and use isolated temporary persistence directories. Overall integration is run by sol.

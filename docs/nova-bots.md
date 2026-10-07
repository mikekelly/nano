# nova-bots: consumer chat

Open `/bots` on the existing Phoenix endpoint. This surface never reads harness logs.
Create named bots in the To field, pick removable recipients, then start a one-to-one
or group chat. Chats are sorted newest first. Keyboard focus, arrows in the recipient
list, Enter and Command/Control-number selection work. Notifications are opt-in,
background-page only and globally rate-limited to one per minute.

## API from eval

```elixir
{:ok, ada} = Nano.Bots.create_bot("Ada", description: "A concise, friendly travel companion")
{:ok, bea} = Nano.Bots.create_bot("Bea")
{:ok, chat} = Nano.Bots.create_session([ada.id, bea.id], title: "December hotel")
Nano.Bots.say(chat.id, "Where should we stay?")
Nano.Bots.post(chat.id, ada.id, "Here are some options…")
Nano.Bots.remember(ada.id, "The person prefers vegetarian dinner")
{:ok, request} = Nano.Bots.ask_human(ada.id, "Choose a budget", session: chat.id,
  reply_to: "asking-agent-name")
# From agent eval omit reply_to to infer its stable registered name via $callers.
# Outside agent eval omit reply_to to get {:nano_human_answer, request_id, answer} in this process.
# The person answers the inline request form, or:
Nano.Bots.answer(request, "Under £200")
Nano.Bots.snapshot()
```

`ask_human` chooses the most recently active matching session unless `session:` is
specified. With no session it returns `{:error, :no_matching_session}`; it never
silently chooses another bot's chat. Requests, question, answer and status are durable.
Double answering is refused. For answers across node restarts use a stable agent name,
not a transient PID. Saved answers remain inspectable even if the requesting process dies;
there is no guaranteed-delivery acknowledgement/replay protocol yet. **Do not put
credentials in chat**: plaintext disk persistence is not a secrets store.

## Runtime configuration

Choose explicit per-bot agent_options (see below) or set a deployment fallback:

```elixir
# Set through config, not a shared node eval during concurrent tests:
config :nano, :bots_agent_options,
  model: "<a model your configured provider actually lists>",
  reasoning: "off", max_context: 32_000, max_turns: 0, max_tokens: 0
```

These options pass through `NanoAgent.start/1`; provider credentials and validation
are the existing harness's responsibility. With no model the UI says unavailable,
not a fabricated reply. Bot prompts explicitly require `Nano.Bots.post/3` for user
output and `remember/3` for durable facts. Ordinary final model text remains operator-only.

The service starts lazily under Nano.Supervisor, writes atomically to
`<state_dir>/bots/state.term`, and restores the exact identity/session records after
restart. A custom `start_link(name:, path:, runner:, decision:)` supports isolated tests.
Unreadable state fails loudly rather than recreating strangers.

## Isolation, memory and compaction

One harness agent per bot/session/generation deliberately spends more processes to
avoid cross-session context leakage. Both group members receive the same human
message and recent shared conversation, speak under their own identities, and see
other members' replies on subsequent human turns. Peer messages route through the cheap-model :respond judgment; positive decisions
wake the peer immediately, with a hard budget of two extra peer turns per human
message. No decision provider means peers observe replies on the next human turn.
They never automatically debate in an unbounded response loop. Generation identity
is captured from eval callers: retired/wrong-session bot agents cannot post, even
if their old tool operation finishes later. Operator calls remain unrestricted on
this trusted node; this is lifecycle protection, not a security sandbox.

Per-bot facts are bounded to 200 records; at most six relevant facts enter each turn.
This store is currently independent of Nano.Memory: it does not assume another
seeding's API. Selection is an optional cheap-model decision, with a conservative
lexical fallback if unavailable. Agents must explicitly remember facts: automatic
memory extraction and knowledge-graph traversal are not yet implemented.

Automatic rollover checks incoming human messages and also subscribes to agent
PubSub response/tool-result/turn-ended traffic plus a 500ms poll. A hard trigger is
24KB of visible conversation or measured agent tokens/serialized transcript bytes
over 55% of context; a semantic decision model can compact sooner. No provider
transcript is edited, so orphan tool calls cannot arise.

The proactive worker suspends agents at GenServer callback boundaries and inspects
their stored state. If any is running an eval/tool, it resumes and retries later;
it never kills a live eval during rollover. At a safe idle/context-halted boundary it saves
a **lossless runtime checkpoint to disk**, persists the new generation, retires old
agents, and resumes unfinished work in a fresh context. Active thinking providers are not killed by the monitor; completed tool calls/results remain in the checkpoint. Abort,
service death or timeout resumes the old agent rather than leaving it suspended.
An eval that suddenly emits an enormous result can still outrun the external monitor
and hit the harness cap; the monitor can recover a context-halted agent, but this is
not a guarantee of unbounded single-turn autonomous execution. Recovery cannot
promise exactly-once external side effects: successor prompts say inspect completed
actions and do not repeat them, but actions should still be idempotent.

The UI retains all visible history; `Nano.Bots.history(session, offset: 0, limit: 20)`
retrieves it in pages. `Nano.Bots.checkpoint(session, generation, offset: 0, limit: 6000)`
retrieves runtime history in bounded text pages. Semantic summaries preserve decisions,
preferences, commitments and open questions when a decision model is configured.
Without it a bounded excerpt is explicit fallback; it may omit facts from working
context, but neither display history nor proactive runtime checkpoints are erased.
Bots are instructed to retrieve the archive rather than guessing forgotten details.
Use per-bot memory for cross-session facts; this is not perfect automatic extraction
or a claim of never forgetting a nuance.

## Cheap typed decision adapter

`Nano.Bots.Decision.decide/2` accepts `:memories`, `:compact`, `:summary`, `:respond` and returns
`{:ok, %{value: typed_value, probability: p, confidence: c}}` or `{:error, reason}`. Configure an explicitly inexpensive model:

```elixir
config :nano, :bots_decision_options, model: "<cheap OpenRouter model>"
# Uses OPENROUTER_API_KEY without printing it. Optional :api_key and :url for deployment/tests.
```

Requests use JSON-object output, zero temperature, a 1500-token cap, eight-second
timeout, no retries; booleans, bounded summaries and memory indices are validated.
Probability/confidence must be numeric in 0..1. The service acts only above 0.6
for each; invalid outputs never silently become decisions. Semantic compaction
considers topic transitions, continuity, commitments, recent chat and actual
budgets; deterministic hard context limits remain in code. Missing model/key uses transparent
fallback. Semantic decisions run outside the state owner in workers, with a per-session
preparation queue to serialize incoming human dispatch. Offline tests inject callbacks.
A real smoke (google/gemini-2.5-flash-lite, 256-token cap) returned
`{:ok, %{value: true, probability: 0.9, confidence: 0.8}}` for a directed peer question.
No keys or provider secret payloads were logged. Jev is not required or claimed integrated.

## Safety and current scope

HEEx escapes every model-written string. A deliberately small Markdown subset renders
headings, lists and fenced code; raw HTML and links are inert text. There is no HTML
sanitizer trust boundary, no arbitrary URL/file download, and no model-authored script
or style. This is particularly important because `/api/eval` shares the origin.
The deployment remains the seed's **unauthenticated trusted single-user node**:
no multi-user access control, sandbox per bot or distinct VM/computer per bot exists.
Do not expose this endpoint publicly without authentication and network isolation.
Attachments, voice input, app connections, full Markdown, configurable quiet hours,
service-worker notifications while the browser is closed, bot editing/deletion and
production-grade transcript pagination are not implemented. Display history is stored
in one state file; very large histories will need an append-only database/stream.

## Verification

Focused ExUnit tests cover persistent identities/restart, group creation, cross-session
memory selection, typed decision fallback, rollover, request correlation and duplicate
answers, LiveView group UI and model HTML/code safety. Tests use unique temp directories,
fake runner functions, no real keys or global provider changes. LiveView uses the
existing test endpoint (port 0). Run `MIX_ENV=test mix test test/nano/bots_test.exs
test/nano_web/bots_live_test.exs` in this checkout; builds are checkout-local because
the seed mix.exs explicitly clears MIX_BUILD_ROOT in test mode.

Follow-up focused verification includes `test/nano/bots_audit_test.exs`; 12 focused tests pass.

## Per-bot runtime options and instance decisions

```elixir
Nano.Bots.create_bot("Ada", agent_options: [model: "google/gemini-2.5-flash-lite",
  reasoning: "off", max_context: 32_000, max_turns: 0, max_tokens: 0])
Nano.Bots.configure(bot_id, agent_options: [model: "google/gemini-2.5-flash-lite"])
# For isolated service deployments/tests, without changing global application env:
Nano.Bots.start_link(name: :my_bots, path: "/tmp/my-bots/state.term",
  decision_options: [model: "google/gemini-2.5-flash-lite"])
```

The To composer exposes an explicit model slug field. No costly model is chosen
silently; its placeholder names a cheap example, not a hidden default. Only model,
reasoning and budget options are persisted; API keys/system prompts are discarded.
Node-wide bots_agent_options remains an optional deployment fallback.

Runtime followup tests (`test/nano/bots_runtime_test.exs`) cover proactive no-human
rollover, lossless checkpoint retrieval, durable options/secret stripping, and
slow-decision UI responsiveness. 16 focused tests pass, including defer/resume while a tool is running.

## Request-boundary policy and aggregate context caps

`Nano.Bots.Context.before_request/1` implements the opt-in harness `context_policy`
contract: pure bounded-time deterministic callback, no network/GenServer/model calls.
At pressure it replaces completed tool exchanges with a quoted plain-user checkpoint,
never an active/dangling tool call. It keeps a previous checkpoint and recent completed
exchanges. This is a conservative safety fallback, not a fake semantic classifier;
semantic summaries and retrieved memory arrive from asynchronous decision workers.
It is wired into new bot agents as `context_policy: Nano.Bots.Context` (requires the
coordinator's generic NanoAgent hook). The external monitor now rotates only idle or
context-halted agents, never active thinking providers or running evals.

`Nano.Bots.Runtime.payload/4` has a final **12KB JSON aggregate cap**. Incoming text is
bounded to 3KB, memories to ~3KB total, history to ~4KB total, session brief to 1.5KB;
the newest human message is not duplicated in history. Runtime system brief is at
most 4KB. UTF-8 is preserved and JSON escape expansion is accounted for. Full text
remains in durable history, available by paging, rather than flooding a new context.
Regression tests cover six 32KB memories, twelve long messages and Unicode/control
character expansion. 19 focused tests pass with these guards.

Custom service agents receive a stable Registry `{:via, Registry, ...}` descriptor in
their prompts (service ID persists on disk). Replies, memories, human requests,
history/checkpoints and retirement archives route to that service, not the production
singleton. Thus isolated named/path services can run live smoke without changing
node-wide provider configuration. Service restart restores that stable routing ID.

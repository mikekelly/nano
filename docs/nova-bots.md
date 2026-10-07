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

The operator must set `:nano, :bots_agent_options` in deployment configuration:

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

Automatic rollover is checked on each incoming human message at 24 KB of visible
conversation, or when measured agent tokens/serialized transcript bytes exceed 55%
of its context limit; a decision model can request an earlier rollover. The new
agent receives a bounded brief and recent conversation, while the UI retains the
full history. No transcript rewrite means provider tool calls cannot become orphans.
Old idle generations are stopped; busy ones are not killed mid-tool-call. A tool-heavy
single turn can still hit the harness context cap before the next human turn. This
is not a claim of arbitrary-length autonomous execution with zero forgotten detail.
The fallback brief is a bounded recent excerpt, not semantic summarization; older
facts may be lost without explicit memory or a configured decision model.

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
fallback. Decisions currently execute in the state-owner call and can delay other
chat operations up to the request timeout; provider judgments/cost are not exercised
in offline tests. Jev is not required or claimed integrated.

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

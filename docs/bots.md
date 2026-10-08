# Bots: the personal chat surface

Open **`/bots`** on the existing Phoenix endpoint. `/` remains the operator dashboard.
Create a named bot with a short description, pick recipients in the **To:** line, and
start a chat. Pick two or more for a shared group. Each bot keeps its face and name
across sessions and restarts; messages identify their speaker. New chat makes a new
conversation, while the large main companion opens its latest direct chat.

The recipient picker supports arrows, Enter, and Command/Control + 1–9. Enter sends a
message; Shift+Enter inserts a newline. **Stop** ends the current exchange; sending
another message continues. Image attachments use the shared `Images` store and appear
as safe previews; include a short accompanying message. Generic file uploads are not
implemented. The microphone is an explicitly unavailable future feature.

## Agent entry points

`Bots` module documentation is the API reference. A minimal setup:

```elixir
{:ok, mira} = Bots.create_bot(%{name: "Mira", description: "Thoughtful researcher"})
{:ok, chat} = Bots.create_session([mira["id"]])
Bots.say(chat["id"], "Help me plan tomorrow")
```

Agents needing a person should use a request, not a dashboard log entry:

```elixir
{:ok, request} = Bots.request(mira["id"], "Which hotel should I reserve?",
  requester: "travel-agent", session_id: chat["id"], idempotency_key: "hotel-choice-42")
# travel-agent receives {:bots_answer, request_id, answer}
# Deduplicate by request_id, durably handle the answer, then:
Bots.ack(request["id"])
```

The answer transition is durable and happens once. Transport retries until acknowledged,
so consumers must deduplicate. `Bots.request_status/2` permits recovery/polling. Use a
stable NanoAgent name for requesters that must survive VM restart; PID destinations are
only meaningful within the current VM. Human replies target a request explicitly in the
chat, so the response goes back to the asking agent rather than whichever bot last spoke.

## Architecture and trust

- `Bots.Server` owns persistent identities, sessions, requests, and notification budgets.
  Default storage is `<STATE_DIR>/bots`; writes are atomic. Corrupt storage fails closed
  rather than discarding your bots. Preserve the file for operator repair/recovery. Each isolated test instance
  accepts `root:` and `name: nil`; facade functions take `server: pid_or_name`.
- `Bots.Runtime` defaults to `openai-codex/gpt-6-astra` with low reasoning. Override
  via Bots startup options `model:`/`reasoning:` or application settings
  `:nano, :bots_model` / `:bots_reasoning`. It gives each **bot × session** its own NanoAgent. The context window is not
  switched between sessions. These agents share the node/container and root privileges;
  conversation isolation is **not a filesystem or security sandbox**.
- `Bots.Router` uses the shared typed `Decision` client to judge recent conversation,
  including follow-ups and who was addressed. A failed classifier must not leave a human
  unanswered. Bot-to-bot exchanges have a ceiling, a rising relevance bar, and a visible
  end marker. Stop and new human messages revoke stale response tokens.
- Explicit `Bots.post` is the consumer output channel. Tool calls, eval results, model
  scratch work, and harness traffic stay on the operator dashboard. Posting tokens are
  capabilities scoped to a bot, session, and response epoch, not protection against a
  malicious root agent.
- `Bots.Memory` uses shared `Memory` primitives with persistent bot-scoped owners. Agents
  record small durable preferences, facts, commitments and open questions; bounded
  relevant retrieval makes these available to other sessions. It is not a transcript
  dump or automatic perfect recall. With no decision service it falls back conservatively.
- Existing `Compaction` automatically checkpoints long-running NanoAgent contexts. Bot
  prompts require preservation of human preferences, decisions, commitments and open
  questions. The full chat remains in Bots storage independently of model compaction.
- `NanoWeb.BotsMarkdown` renders an intentionally small safe Markdown subset. Raw HTML
  is escaped, links are protocol-checked, and model text cannot become page scripts.
  Image URLs are derived only from validated immutable image IDs. Keep these guarantees:
  this origin also exposes the unauthenticated operator `/api/eval` endpoint.

This is a single-person, trusted-local-node product, not a multi-user authenticated
service. Do not expose the endpoint publicly. Session IDs are not authorization.

## Notifications

Notifications default off. Open the settings gear, explicitly grant browser permission,
and set the interruption budget. Server-side cooldown and hourly limits survive service
restart. The browser additionally suppresses foreground notifications, deduplicates
across tabs when Web Locks/storage are available, and uses text-only notification bodies.
Permission denial does not lose requests: they stay in the conversation.

A Bots page must remain open/connected for browser notifications. There is no Web Push
service worker; a closed browser cannot be awakened. Browser/OS policy can suppress a
notification even when permission is granted. Never place secrets in notification text.

## Verification

```sh
MIX_ENV=test mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test
node --test test/bots_hooks_test.js
MIX_ENV=test mix run --no-start test/support/bots_managed_start_check.exs
```

For real browser wiring without paid models, start a **disposable test instance**:

```sh
MIX_ENV=test mix run test/support/bots_browser_server.exs
# Copy its BOTS_URL output into a second shell:
BOTS_URL=http://127.0.0.1:PORT node --experimental-websocket test/bots_browser_smoke.mjs
```

The browser harness uses installed Lightpanda and binds its CDP server to loopback port
0. It creates two bots and a group, sends hostile-looking text, checks safe rendering,
and opens notification settings. Stop the fixture when done. Node 20 needs the
experimental WebSocket flag; no npm packages are required. Tests use isolated storage
and scripted runtimes rather than external paid providers.

## Diagnosing a bot that cannot respond

The runtime checks active grants with bounded asynchronous health probes. A halted
agent is still a live process: process monitors alone cannot detect a node-budget,
provider or operator halt. These conditions are now reported specifically rather
than waiting for the response deadline. A blocked health probe cannot block chat,
and stale probe results cannot revoke a newer speaking grant.

After resolving the underlying condition, `Bots.retry(session_id)` retries an errored,
inactive session's latest pending human message. It preserves the transcript and
message ID, advances the session epoch, and grants fresh response tokens; it does
not impersonate the person by appending a new message. It does not unhalt agents or
change budgets. An operator can inspect the owning bot agent's `NanoAgent.info/1`
and explicitly unhalt a budget-paused agent after capacity becomes available.
The seed rechecks the node budget before every model call. Do not unhalt arbitrary
operator/provider/agent-limit halts as a substitute for diagnosing them.

This distinction was verified on the live deployment: the build exhausted the shared
node budget before two consumer chats arrived. After the operator raised the cap,
only affected budget-paused bot agents were resumed, and the original conversations
received real responses. Earlier timeout notices remain in the transcript as evidence.

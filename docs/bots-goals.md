# Bots, goals, memory and front of mind

Consumer entry point: **`/bots`**, on the existing Phoenix endpoint. Operators retain
`/agents/:name`, including the raw timeline. Capability state is atomic JSON beneath
`<state_dir>/seedling` (production `/data/state/seedling`). The existing Nano state store
restores session agents; the bot service re-subscribes saved agent IDs and reconciles thinking
status on restart. No additional web server, model tools or service workers.

## Persistent companions and isolated sessions

```elixir
{:ok, muse} = Seedling.Bots.create("Muse", model: "openai-codex/gpt-6.1-sol",
  reasoning: "low", max_context: 64000, description: "A thoughtful travel companion")
{:ok, dots} = Seedling.Bots.create("Dots", model: "openai-codex/gpt-6.1-sol",
  reasoning: "low", max_context: 64000, description: "A practical organizer")
{:ok, one} = Seedling.Bots.session([muse["id"]])
{:ok, group} = Seedling.Bots.session([muse["id"], dots["id"]], title: "December hotel stay")
Seedling.Bots.say(one["id"], "I prefer quiet hotels")
Seedling.Bots.say(group["id"], "Help compare December options")
# Only from the owning bot/session agent's eval:
Seedling.Bots.post(session_id, bot_id, "**Done.** Here are the options.")
```

One agent **per bot/session** avoids context-switch leakage; each has independent history,
bindings, mailbox and checkpoint. Identity (name, face, description, model, workspace, graph)
is per bot and survives restarts. This costs more than one process switching sessions;
isolation is worth that trade-off. The library checks the actual caller for `post`.
Final model answers, evals, reasoning, tool results and harness notes are NEVER promoted
to consumer chat; agents must post, as their prompt states. Thinking/unavailable statuses
explain silence. First delivery validates provider/model asynchronously, not in a page render.
Model defaults can be set with app env `:bot_model` or advanced creation controls; a default
is not a promise that its provider is connected.

Each bot has a distinct durable `workspace` under `bot-computers/<bot-id>` for files/shell
work. This is a **logical computer on the shared node**, not a separate OS, VM, container
or security sandbox. Eval retains the seed's root privileges. The prompt requires using its
workspace and avoiding other agents' files; do not treat bots as mutually untrusted tenants.

`Seedling.Bots.snapshot/0` is an ETS read; page renders never call agents or decision APIs.
Changes use existing `Nano.PubSub` topic `"bots"`, `{:bots, event}`. Human delivery is serialized
per session with a durable pending queue, replayed on service restart. The send/ack boundary
is **at least once**; a crash can repeat an event, not an exactly-once broker. Provider failures
stay visible. Each event includes that session's last 24 human-facing messages and small
selected memories. Jev Choice routes groups to one participant or all; uncertainty/missing
service falls back to all with a labelled reason. Bot posts don't recursively wake peers
(avoids runaway feedback); peers see them in the next human-delivered shared snapshot.
This supports shared discussions, not instantaneous autonomous peer debate.

Limits: 100 bots, 500 sessions, eight bots/session, 1,000 messages/session, 12,000 characters
per message, 1,000 requests/catalog, four files/message, 4 MB catalog. Limits return errors;
no chats silently discarded. Start another session before the per-chat limit. This bounded
first product is not an unbounded archive.

## Per-bot knowledge graph

```elixir
{:ok, pref} = Seedling.Memory.remember(muse["id"], "preference", "Quiet hotels near trains",
  session: one["id"])
Seedling.Memory.remember(muse["id"], "person", "The local person", links: [pref["id"]])
Seedling.Memory.recall(muse["id"], "hotel travel")
Seedling.Memory.forget(muse["id"], pref["id"])
```

Explicit memories have kind/text/links/provenance/time. Prompts ask to remember useful
preferences/facts, not raw sessions or secrets; sensitive facts require consent. Per-bot
graphs: 1,000 nodes, 1,000 characters/node, 20 links/node. Retrieval lexically shortlists
24 candidates plus linked nodes (max 32), then batches Jev relevance Nouls. At most five
nodes/1,600 characters enter a session. Unavailable Jev yields a labelled lexical fallback,
never fabricated probabilities. The lexical shortlist can miss purely semantic associations;
traversal is one hop, not full best-first search. Extraction relies on explicit `remember`,
not guaranteed automatic fact ingestion. Text and recent activity are sent to TypeSafe
when decision features run: share only data the operator/person permits.

## Every agent's human conduit

```elixir
{:ok, req} = Seedling.Bots.request_human(muse["id"], "Which dates should I use?",
  session: one["id"], reply_to: me, timeout_ms: 3_600_000)
Seedling.Bots.answer(req["id"], "December 12–15", session: one["id"])
Seedling.Bots.request_status(req["id"])
# Requester receives %{type: :bot_human_answer, request_id: ..., bot_id: ...,
#   session_id: ..., state: "answered", answer: "December 12–15"}
```

With no session option, choose the most recent containing that bot; a session must exist.
The request records **actual requester** separately from reply target; UI prominently says
who asked. Named reply targets are resolved afresh after restarts. Unnamed pids are runtime
only/best effort. Named offline/restarted requesters are retried from a durable outbox until acknowledged;
retry backoff is 60 seconds up to one hour, swept every 30 seconds and after service restart.
After processing call `Seedling.Bots.acknowledge(request_id)` from the actual reply-target agent,
and deduplicate by request ID. This is at-least-once delivery. Polling is also available. Answers are
one-shot, require the correct session, and reject expired/cancelled/answered requests.
Expiry sweeps every 30 seconds; `cancel_request/2` returns correlated cancellation.
These are trusted local single-person APIs like `/api/eval`, NOT multi-user authentication
or protection against agents executing arbitrary root code. Do not put credentials in chat;
ask the person to set them in operator settings.

Notifications are **off by default**. Button requests browser permission; server limits
gate proactive posts/requests independently. Use `Seedling.Bots.notifications(enabled: true,
per_hour: 3, cooldown_seconds: 60, quiet_start: 22, quiet_end: 8)`. Quiet hours use UTC and
support wrapping. Browser display requires permission and a background tab. Multiple tabs
may each receive the event (browser notification tags coalesce where supported). No closed-
browser push service. Browser Notifications API has NOT been tested in a real graphical
browser in this run; server limits and LiveView events are tested. Keyboard: Tab/Enter,
dropdown arrows, Cmd/Ctrl+K and Cmd/Ctrl+1…9. Voice button visibly disabled for later work.

## Safe Markdown, files and images

`Seedling.ChatMarkup` escapes all source text before producing restricted markup: headings,
paragraphs/bullets, bold, inline/fenced code and HTTP(S) links with noopener/noreferrer.
No raw HTML, javascript/data links, iframes or model-written scripts execute. Not full
CommonMark. NEVER render raw model HTML here: the origin's unauthenticated `/api/eval`
executes arbitrary code. Files use `Seedling.BotFiles.add(path, name)` (regular <=5 MB) and
opaque IDs; pass its returned maps as `files:` to `post`/`say`. `/bots/files/:id` serves
application/octet-stream + attachment disposition + nosniff + sandbox CSP, including HTML/SVG.
Nano.Images sniffs PNG/JPEG/GIF bytes, validates bounds and stores immutable refs. UI renders
these through `/api/images/:sha256`; delivery includes chat text + images in ONE harness event
via `NanoAgent.deliver_images/3`. Text-only models receive explicit harness warnings rather
than pretend vision. No attachment garbage collector yet.

## Durable goals

```elixir
{:ok, g} = Seedling.Goals.create(me, "Ship search", "Find reliable sources")
{:ok, step} = Seedling.Goals.create(me, "Test", "Evidence before reporting", parent: g["id"])
Seedling.Goals.update(me, step["id"], status: "done")
Seedling.Goals.review(me) # eight active-first rows / 1,600 chars, not the tree
Seedling.Goals.list("orion") # readable by fresh/sub-agents
Seedling.Goals.configure(me, bobbing: true, threshold: 8000)
```

Adjacency trees (500 goals/agent) have mandatory why, ID, status and timestamps.
Statuses: open/active/blocked/done/cancelled. Parent must exist and be unfinished when adding
a child; completion rejects unfinished children. No reparenting means no cycles. Goals
survive process/node restarts and compaction independent of context. Dashboard uses bounded
filesystem reads, never agent calls. Review frequency stays the agent's choice.

## Experimental context bobbing

```elixir
Seedling.FrontOfMind.set(me, "Keep this under £200; test before saying done.")
Seedling.FrontOfMind.configure(me, enabled: true, threshold: 8000, drift: true)
Seedling.FrontOfMind.clear(me)
```

Note limit: 1–1,000 Unicode characters, durable/replaceable/clearable. Harness calls
`before_request(state)` before EVERY model request including mid-turn tool loops, BEFORE
budget estimates. `after_compaction(state)` resets tracking and immediately re-shows active
sources. Reusable `Seedling.Bobbing` supports notes and opt-in goals. User-role append-only
reminders explicitly attribute **the named agent's own words** and writing time, re-shown by
harness, **not an outside instruction**. Cached prefixes remain valid. Saved indices and
revisions survive restarts. Distance is a conservative **estimate**: ceil(JSON bytes since
last appearance/2) + 4,800 tokens/image, not exact tokenization and not turns. Harness events
are incorporated before hooks; crossings between calls are caught at the next model call.

Optional drift: one compact Jev judgment per five request IDs or note revision, six short
recent activity excerpts. Probability >=0.65 becomes advisory on the next bob; never changes
the note. Bobbing/drift can independently be disabled. `front_of_mind_updated` configuration,
`context_bob` source/distance/threshold/reason/text and `drift_judgement` typed result or blocked
reason go to Nano.Log/timeline PubSub. Missing services NEVER get invented probabilities.

### Evidence, not an efficacy claim

- Live TypeSafe Noul call returned **jev-1.13.0**, drift **0.17** for aligned activity “Testing
  goal persistence” vs note “Ship tested goals”. Credentials were supplied, not printed.
- A builder's real note appeared automatically before repeated **mid-turn** model calls under
  the merged harness; logs contain each bob's measured trigger.
- Deterministic comparison: disabled inserts zero reminders into matched transcript; enabled
  inserts initially, after >=100 estimated tokens and immediately after reset. Goals work
  independently while note is disabled. Tests cover Unicode limits, attribution, clear, durable
  reads and distance logs.
- No randomized model-behavior comparison established improved alignment. Attention/efficacy
  remains **unproven**. This is mechanics/cost evidence, not causation. Compare matched tasks and
  randomized enabled/disabled trials when researching it.

## Shared typed decision models

`Seedling.Decision.evaluate(state, %{"id" => Decision.noul(question)})` returns
`{:ok, %{answers: string_keyed_map, model: ..., usage: ...}}` or sanitized error. Noul/Choice/Score
constructors work with the documented POST https://api.typesafe.ai/v1/systemone, jev-latest,
setting TYPESAFE_API_KEY. Defaults: 3s timeout, no retries, 64 questions/64 KB input. No keys or
provider error bodies logged. Tests inject transport/loopback/key, never spend. Small judgments
serve drift, group routing and memories without spending the bot's main model.

## Tests and honest remaining boundaries

Parent owns supervision/routes/static allowlist/root script integration. Tests use unique
temp roots, unnamed services, fake session-agent starters and scripted providers; no `/data`
writes or fixed ports. First full integrated worktree suite: **299 passed**; final report
records subsequent tests/format results. Separate physical computers, guaranteed automatic
memory extraction, infinite archives, instantaneous peer debate and actual browser permission
popups are explicitly not claimed. Unit comparisons establish bobbing mechanics, not efficacy.

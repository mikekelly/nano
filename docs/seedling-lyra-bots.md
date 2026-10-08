# Bots consumer chat

`/bots` is a calm LiveView messaging surface sharing endpoint/PubSub; only explicit chat
posts are shown, never evals/reasoning/tools/harness logs. HEEx escapes model text; safe
paragraph/fenced-code Markdown subset, never raw HTML.

```elixir
{:ok, muse} = Seedling.Bots.create_bot("Muse", "Warm, precise travel companion")
{:ok, dot} = Seedling.Bots.create_bot("Dot")
{:ok, chat} = Seedling.Bots.create_session([muse.id, dot.id])
Seedling.Bots.say(chat.id, "Plan a weekend")
Seedling.Bots.post(chat.id, muse.id, "Here is the plan.")
Seedling.Bots.remember(muse.id, "Person prefers jasmine tea; stated October 8", ["preference"])
Seedling.Bots.memories(muse.id, "tea")
{:ok, request} = Seedling.Bots.request_human(muse.id, "Which hotel?", session: chat.id, reply_to: me)
# UI answers; requester receives {:human_answer, request, text}.
Seedling.Bots.answer(request, "Hotel A")
Seedling.Bots.snapshot().requests[request] # durable answer / status
```

Parent adds `{Seedling.Bots, []}` after settings/PubSub to supervisor. Atomic store:
`:state_dir/bots.json`. Identities, sessions, transcripts, memories, requests and answers
survive restart. One native NanoAgent worker per bot/session (`bot-ID-SESSION`), restored
by harness, avoids cross-session context leakage. Human messages go to every group member;
bot posts go to live peers as observation-only updates, avoiding infinite bot loops.
Recent group transcript accompanies human turns. Per-bot workspace directories are not
OS sandboxes; inherits seed's trusted unauthenticated root-agent model.

Set `BOT_MODEL` node setting to supported slug (default `openai-codex/gpt-5.4`). Listed
default reasoning, up to 64k context. Parent's automatic compaction applies; bot prompt
asks preservation of preferences, decisions, commitments and open questions.

Jev follows real quickstart docs: `POST https://api.typesafe.ai/v1/systemone`, `jev-latest`,
Noul questions, bearer TYPESAFE_API_KEY. Up to 30 memory candidates, inject up to 5 with
relevance >= .65. Bounded fallback on missing service, never fabricated scores. Real probe:
HTTP 200, jev-1.13.0, relevance .94 for jasmine-tea preference, 292 input/22 output tokens.
No keys logged. Lexical memories/2 available cheaply; semantic scoring outside store lock.

Browser notification permission explicit, opt-in/muteable, background-only generic body,
at most one per 5/30/60 minutes. Cmd/Ctrl-N, Cmd/Ctrl-1..9, arrow recipient navigation,
Enter send / Shift-Enter newline. Bots-specific root layout owns client hooks.

Tests: `MIX_ENV=test mix test test/seedling_bots_test.exs test/nano_web/bots_live_test.exs`:
5 passing: restart durability, session isolation, memory, human one-answer delivery,
real NanoAgent with scripted HTTP provider evaluating explicit post, group UI and escaping.
Unique tmp dirs and fake HTTP port 0. Real decision probe succeeded. No real large-model,
compaction or browser-permission end-to-end claim yet; verify compaction after parent merge.
No Nano modules loaded live.

Limitations: no attachments, voice, identity editing UI, connectors, deletion, full inline
Markdown or accessibility audit. Description configurable via API. Notifications require
connected page (no offline push/service worker). Live requester pid not durable: poll saved
answer after restart. Single trusted household, no tenant auth. Snapshot rewrites full
history; large deployments should use append-only storage. Per-bot computer is a workspace,
not isolation from root agent execution.

## Follow-up validation

create_bot/3 accepts model: and max_context: per bot; default model now gpt-6.1-sol.
Human reply_to: may be a registered agent name, persisted with request; answered requests
redeliver on named-agent incarnation change or broker restart. Recipients deduplicate IDs
(at-least-once, not exactly-once). Pid-only requests remain live-only. Session queues persist
pending recipient IDs, enqueue after atomic write within store order, rank memories outside
store lock, and retry affected session on queue crash. Concurrent startup/ordering barrier test
passes. 7 focused tests now pass.

Actual gpt-6.1-sol smoke: two bots, individual/group sessions, both distinct consumer posts,
Muse durable preference remembered in separate session via Jev semantic retrieval. Actual
Chromium page hidden with Notifications permission granted emitted native generic notification
on human request; browser answered Quiet Hotel A in chat, named lyra-bots received answer.
Screenshot /tmp/lyra-bots/.browser/bots.png (runtime artifact, not committed).
16k actual bot compaction triggered but summarizer returned oversized checkpoint and halted;
reported to continuity sibling, retest pending. No success claim for that yet.

# Real consumer-bot evidence — 2026-10-07

Parent approved bounded REAL tests and loaded only owned backend modules, then started
Vega.Bots.Server under Nano.Supervisor rooted /data/vega. This agent did not reload live
modules, change settings/credentials or hot-upgrade a running service map.
All chat messages below used the public eval APIs, not direct model text capture.
Provider: **openai-codex/gpt-6.1-sol**, reasoning low.
Bots: Muse `223f6efcb1c09c464634`, Dot `d957a25ebc76e9556764`. Each has finite limits30 calls,
600000 cumulative tokens, 24000 context; stable identities, faces and chats retained
for the eventual /bots surface. Tests used three durable sessions:

- `29d67ebc9342a3c4c676` — A little about me (Muse)
- `1a9fd33b92065818003d` — Meet Muse and Dot (both)
- `dea4cf20deecfc322797` — Weekend ideas (Muse)

## Authored group messages and cross-session identity memory

At21:51:02 Dot posted via eval: “I’m Dot, your practical companion for turning ideas
into clear next steps.” At21:51:04 Muse posted its own calm-companion introduction.
Both messages have their distinct author IDs in the SAME group session.

In the first private session, a person explicitly asked Muse to remember a harmless
sample preference: quiet forest walks. Muse called Vega.Bots.remember and posted a
confirmation at21:51:07. Durable memory `3933GR4XxMlgjmla` has provenance pointing to
that session. In the separate Weekend ideas session, the person asked what outings they
prefer. At21:51:31 Muse posted: “You prefer **quiet forest walks**, according to my
identity memory.” Each session had a distinct deterministic NanoAgent name/transcript;
no first-session transcript was supplied as the second-session context.

## Human conduit with actual requester restart

Started requester `vega-bots-human-demo` via Vega.Delegation with finite6 calls/150000
cumulative tokens, no files/settings work. The real agent itself called request_human
for Muse in Weekend ideas, correlation `weekend-human-demo`: “For the weekend, do you
prefer forest walks or a busy city outing?” Durable pending card created21:51:21.
Before answering, killed its process deliberately; supervisor restored same name/history,
PID0.10869.0 -> PID0.11100.0, restart_count1. Then answered through the public API at
21:52:01: “Quiet forest walks, please.” The restarted requester received the by-name
relay and at21:52:05 ran eval to notify this agent and acknowledge_answer. Durable request
is answered/acknowledged=true. Its log tool_resultseq27 reports successful ack; it then
idled. Its finite6-call budget halted it after success, not before delivery; no runaway.
This verifies actual agent asking, persisted human answer, name-stable restart and ack.
No real browser notification was triggered/tested: browser UI was not yet live.

## Automatic REAL compaction and continuity

Sent a24261-character harmless synthetic long input (sample note_0001..note_2400,
explicitly not facts to memorize) in the original Muse session. Bot posted brief ack at
21:52:12 and did not dump the items. Harness automatically logged:

- compaction_startedseq21 at21:52:12, removed8 messages, kept2
- compaction_usageseq22: ChatGPT11058 prompt tokens /436 completion tokens
- compaction_completedseq23 at21:52:22, estimated context4412

Durable full log: `/data/logs/bot.223f6efcb1c09c464634.29d67ebc9342a3c4c676-0885b1.jsonl`.
Summary preserved sample preference, memory ID, message IDs, completed confirmations
and pending acknowledgement instructions. Agent returned idle, halted=nil.
Asked after compaction what preference to still remember; at21:53:09 it posted:
“For this demonstration, you prefer quiet forest walks.” Thus compaction was automatic,
real Codex-provider-backed and retained the person's preference across continued chat.
The UI wasn't needed for test mechanics; no eval/tool traffic belongs in consumer messages.

## Real native vision attachments

Generated an8x8 blue PNG (73 bytes) and imported immutable ref
`92b9adcd9752e7e651ea8c1a23b301efa3c292bbba52e9cc8a8645e65a31f520`.
Message4b3457f64d16695c5f51 at21:58:42 attached it through public send_message(images:refs)
and asked each bot for the main colour, without mentioning the expected answer.
Saved model modalities are text+image. Dot at21:58:48 and Muse at21:58:54 independently
posted “The main colour is blue.” Native image events and provider hydration were used,
not a filename pretending to be vision. Source PNG remains under immutable Images
storage and message metadata only; transcript/log image bytes aren't copied into chat.
Both group agents returned idle, no halt.

## Separate automated/browser evidence and limits


Backend tests exercise actual NanoAgent with scripted provider separately from these real
calls. Tests cover pair isolation, compaction, restart, bounded memory judgments,
durable input/answer acknowledgement, nonblocking ETS snapshots/page reads, immutable
file/image validation and malicious Markdown. Focused backend11 plus safe-download1 passed, frontend12 tests passed including
bounded/sliding history. A full compile --warnings-as-errors + suite checkpoint
passed342 tests after sliding fix; cheap routing and detached-scroll followups rerun
separately before final report. Existing seed-test-only warnings were disclosed.
Reproducible mocked JS test lives test/js/bots_hooks_test.js; run node on it.
ARM Node syntax check and VM-mocked hooks pass permission/background/rate/dedupe,
keyboard recipient shortcuts and Enter/Shift+Enter composer. **Real browser layout,
mobile gestures and OS notification permission/popups remain untested.** No closed-tab
push is offered; no authentication/multi-user security is implied. Live parent service
was an earlier committed backend (unbounded snapshot/old idle-status mapping); parent
must review and restart it onto latest tested bounded-cache map, not blind hot reload.

## Final source validation

After all final source changes: MIX_ENV=test with isolated worktree build,
`mix compile --warnings-as-errors && mix test` passed **345 tests**, exit0,
output `/tmp/vega-bots-tasks/HjxHTL-vkCFBpcpG/output.log` (2026-10-07T22:09:08Z).
Focused bots suite totals27 tests (14 backend/controller,13 LiveView/Markdown).
Node --check and both committed test/js VM scripts passed. No real browser/OS
notification claims are added by those mocked tests. Integration still requires
parent static bots.css/js allowlist and reviewed eager service restart/map migration.

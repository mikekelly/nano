# Bots design / foundation gate

Status: spec inspected; design only. No implementation until Vega reports merged shared
foundation commit. Ownership: lib/vega/bots*.ex and lib/vega/bots/**,
lib/nano_web/live/bots_live.ex, own BotsLayouts/components, /bots routing additions,
priv/static/bots.css and bots.js, test/vega/bots* and bots LiveView tests, docs/bots*.md.
No edits to shared app.css/layout hooks, memory/delegation/compaction or harness.

## Product and interactions

Separate `/bots` consumer surface on existing endpoint/PubSub, operator `/` unchanged.
Own root layout loads existing Phoenix clients and own CSS/JS; it does not overwrite
shared assets. Desktop: soft white two-column messenger; mobile: chat list OR active
conversation, Back to chats retains selection/draft. Sidebar has Search, New chat,
large default bot, newest-first chats, overlapping friendly faces/person initials,
one-line previews, selected row, person initials and notification settings below.
First visit has onboarding Create your first bot; errors always have a visible retry.

New chat opens To: editable combobox: Create new Bot, Create group chat, filtered bots.
Arrow keys select, Enter chooses, Escape closes; Cmd/Ctrl+1..9 choose visible bots.
Chosen bots become removable face/name chips with accessible remove labels. No match
provides Create [typed name]. Create form asks name, short description/voice; friendly
colour and geometric face assigned once and persisted. Two chips automatically make
a group; Start chat disabled with no participants. Group title defaults to names;
person can rename topic. Search filters chat titles/previews and bot names.

Chat header pill shows participants. Each bot message names its author and has face;
person messages align right. Composer placeholder names recipients. Attach + opens
file chooser with previews/removal and clear validation errors. Send preserves draft
on failures and clears only after durable acceptance. Microphone disabled with explicit
Voice input coming later label (no fake recording). Enter sends; Shift+Enter newline.
Thinking/status lives separately from messages; no eval/tool/harness text enters chat.
Older messages remain readable; autoscroll only while near bottom, otherwise New
messages jump control. Retry and actionable provider errors never expose secrets.

Semantic landmarks, labels, focus-visible, live polite thinking/error announcements,
aria-selected current chat, combobox/listbox semantics and keyboard navigation;
minimum touch targets, reduced-motion support, narrow layout and long-code overflow.
Empty/loading/disconnected states cannot resemble a silently stalled bot.

## Durable backend and isolation

Vega.Bots service serializes mutations and atomically persists JSON with string keys
under `/data/vega/bots`; test instances receive unique root/server names. Stable bot IDs
hold name, face, description, voice, preferred model. Session IDs hold participant IDs,
title, ordered messages and pending human requests. One NanoAgent per bot/session,
with deterministic registered name `bot.<botid>.<sessionid>`: stronger isolation than
switching one transcript between sessions. Restart restores identity and session agent
history rather than re-creating a persona. Group messages delivered to each member,
authored replies broadcast back with explicit authors; routing can select subset via
sibling cheap decision adapter, with conservative all-member fallback (no brittle
keyword heuristics). Avoid automatic bot-to-bot ping-pong: bot posts visible but do not
wake every other member unless explicitly requested.

Public candidate API (all return {:ok, value}/{:error, reason}; opts include root/server):
create_bot(name, opts), bots(opts), get_bot(id, opts), update_bot(id, attrs, opts),
create_session(bot_ids, opts), sessions(opts), get_session(id, opts),
send_message(session_id, text, opts), post(session_id, bot_id, text, opts),
status(session_id, bot_id, state, opts), subscribe(opts),
request_human(bot_id, question, opts), answer_request(request_id, answer, opts),
pending_requests(opts), acknowledge_answer(request_id, opts).

Agent prompt explicitly says prose responses do not reach person: use
Vega.Bots.post(session_id, bot_id, markdown), status, and remember API through eval.
Post authorization checks configured bot/session pairing; consumer identities are not
an auth boundary (same unauthenticated node as existing API). Durable status/errors
are drawn from service plus NanoAgent.info/log status without revealing reasoning.
Session boot/message event carries stable bot persona, relevant memories, attachments,
message ID, author and post instructions. Session transcript, never other transcript,
is visible to that agent. Memory is per stable bot identity via sibling
Vega.Memory.put/retrieve/get/update/delete; retrieve bounded relevant items per human
turn. Agent chooses lasting facts/commitments using explicit remember wrapper rather
than storing every chat line as a supposed fact. No duplicate memory implementation.
Automatic compaction is mandatory shared harness capability; bot prompt asks preserve
preferences, decisions, commitments/open questions and points to durable session data.

## Safe content and attachments

Markdown is untrusted on an origin with eval authority. Render escaped structured
Markdown subset (paragraphs, lists, emphasis, inline/fenced code, safe links) with
Phoenix HEEx nodes, never raw model HTML; unknown syntax displayed literally. Reject
javascript/data/protocol-relative URLs; links allow http/https with noopener noreferrer.
No remote image HTML, SVG, event attributes, script or embedded model HTML. File
attachments only from validated immutable file references; never expose arbitrary
paths or serve active HTML content. Images use sibling Vega.Images validation/store
and native agent image-event API, not paths pretending to be vision. Need exact API
from images sibling before implementing upload/send. Test malicious Markdown/URLs,
raw HTML, long fences, filenames and outbound files.

## Human conduit and notifications

request_human requires durable requester agent NAME (not pid), request correlation ID,
optional target session; select bot's recent appropriate session or create one if none.
Persist question + unanswered request before notification. Render answerable request
card within chat; form answer appends person reply, durably stores answered state,
then relay `{:vega_human_answer, request_id, answer}` via NanoAgent.notify(name,...).
Keep answered delivery pending until acknowledge_answer; replay to same registered
name after restart/offline recovery. Pending requests/answers are queryable so lost
casts are not permanent loss. UI answers idempotent; repeated delivery correlated by
request ID. Plain chat remains supported, but explicit answer button removes ambiguity
when several requests coexist.

Notifications never request permission automatically: person toggles and clicks Enable
browser notifications gesture. Configurable enabled, min interval, max/hour, request
only/all proactive messages; permission denied explicitly shown. Own JS uses
Notifications API only in background, generic preview unless person enables content,
click focuses tab/opens session. Persist preference in service; browser local storage
holds permission/rate dedupe across tabs/reloads. Server issues event after durable
post/request; active-tab messages are not interruptions. Rate limiting applies even to
requests; badges/pending cards remain when notification is suppressed. This initial
scope is an open/background tab, not closed-tab push/service-worker delivery.

## Tests and gate

Unit tests on isolated temp roots: stable identities/faces, restart/re-read JSON,
session separation and deterministic agent names, group authors, bounded memory calls
via injected adapter, posting/live PubSub, status/error mapping, request correlation,
idempotent answers, absent/restarted requester replay, attachment validation, Markdown
XSS, notification limits. LiveView tests: first-bot, recipient filtering/chips/group,
chat switching, rendering/status, send errors/draft retention, answer relay, notification
preferences/mobile semantic markup. JS keyboard/permission/rate tests where browser
available; otherwise explicitly disclose untested browser behavior.

Real agent tests only after merged delegation + automatic compaction + memory gates.
Model tests use existing fakes; end-to-end real bot/compaction evidence requires parent
approval and provider budget. No live harness load or settings changes. Build/test with
MIX_ENV=test in assigned worktree; no shared _build/prod paths. Parent integrates and
adds supervised service child if needed. Foundation/API decisions to confirm: server
startup integration, default model/budget policy, Images event API, decision adapter,
compaction personal-summary hooks, and delegation subagent call for frontend split.

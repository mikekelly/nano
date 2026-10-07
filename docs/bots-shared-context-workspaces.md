# Shared group context and identity computers

Followup from parent review: authored group bubbles alone weren't enough. Independent
session agents previously received only the current person message, so they couldn't
reliably react to another bot's suggestion without fetching chat themselves.

Every delivered person event now includes `shared_context` for **that same session**:
chronological recent_messages (at most20 records, JSON <=8000 bytes), author ID/name,
message ID, at, reply_to/request_id, safe attachment metadata, and UTF8-safe text
truncated to at most1000 bytes. Meta reports total prior messages, included count,
omitted older count, truncation budget, and exact before_cursor. `get_session(id,
before: cursor, limit: 80)` recovers older history; `get_message(session,id)` recovers
full text of a truncated record. No other session's transcript is included. Peer
posts remain context-only until the next person input; they never cause autonomous
bot ping-pong. Event instructions treat peer content as data/context, not new requests
or instructions to execute. Current person input remains separately full.

Dispatch passes only at most21 recent messages to the runtime worker, plus original
prior-message count and participant profiles. Workers don't capture the service's full
state/history map. Text shaping is outside the service read/mutation path. Optional
cheap typed routing can skip a turn, but the bot's next addressed input gets fresh
shared context including peer contributions.

## Stable identity computer

Each bot owns an organizational workspace under `<root>/bot-computers/<botid>`;
each session's file work goes under `<identity>/sessions/<sessionid>`. New bot records
expose `workspace`; restored legacy identities gain the field in state/cache. Identity
and session paths are deterministic across process/service restart and distinct between
bots. IDs are strict generated20-hex strings; path traversal IDs fail closed.

```elixir
{:ok, ws} = Vega.Bots.workspace(bot_id, session_id: session_id)
Vega.Files.write(Path.join(ws["session"], "report.txt"), "...report...")
{:ok, result} = Vega.Bots.shell(bot_id, session_id, "pwd")
# Reuses Vega.Files.sh(command, cwd: ws["session"]), not a duplicate shell runner.
```

Prompt/events direct work into those directories rather than shared /app. Current
name/description/voice is supplied as identity_profile, so older agents see authoritative
profile updates without reading another transcript. Shell output defaults to owned
session `.shell-output`. Membership checks reject nonparticipant session workspace use.

**Not a security sandbox:** these are filesystem/context organization boundaries.
All agents retain the privileged shared BEAM/container/eval capabilities of this node;
no OS container isolation or multi-user authentication is claimed.

## Evidence and real-test gate

Three new isolated tests pass: exact byte/UTF8/record limits with cursor/full-record
recovery; two-bot/same-identity session directory distinctions, shell cwd, artifact
persistence/service restart/path traversal; and actual NanoAgent/scripted provider wire
contains Dot's authored token in Muse's next person event but no private foreign-session
token. Focused new+existing runtime/service run13 tests passed. No live modules loaded
by this agent. Parent must review/load followup first; then real Dot-generated random
token -> person asks Muse to repeat is authorized only after upgrade confirmation.
That real shared-conversation check is pending, not inferred from authored UI bubbles.

Full own-worktree compile --warnings-as-errors + suite passed **348 tests**, task
`mTOR2P1yxlQtf-VS` log `/tmp/vega-bots-tasks/mTOR2P1yxlQtf-VS/output.log`, exit0.

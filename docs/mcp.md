# MCP from eval

Entry point: `Code.fetch_docs(MCP)` (or source `lib/mcp.ex`). The committed catalog is
`/app/config/mcp.json`. No server starts merely because it appears in the catalog.

```elixir
MCP.servers()
MCP.connect("demo")
MCP.discover("demo")                         # capabilities + first page of each category
MCP.list("demo", :tools, cursor: "page2")     # server cursor, not local offset
MCP.list("demo", :templates)
MCP.call_tool("demo", "echo", %{"text" => "hello"})
MCP.read_resource("demo", "demo://value")
MCP.get_prompt("demo", "greeting", %{"name" => "Ada"})
MCP.subscribe("demo", "demo://value")        # saved desired state, not an acknowledgment
```

Wait for `{:mcp, "demo", "notifications/subscriptions/acknowledged", params}` in an
ordinary mailbox event, then idle. Another agent (or another eval) can call
`MCP.call_tool("demo", "set_value", %{"value" => "changed"})`; the update arrives as
`{:mcp, "demo", "notifications/resources/updated", %{"uri" => "demo://value", ...}}`.
The deterministic Python demo is in `config/mcp_demo.py`, needs Python 3, and does not
access files or the network. It is a test/example server, **not** the official SDK.

All attached agents hear the server's resource, list, log, progress and client
lifecycle events. Subscriptions are unioned across agent names. Events identify the
server; modern subscription events carry the protocol request ID in `_meta`.
`MCP.unsubscribe(server, uri)` removes your intent; `MCP.detach(server)` removes all
your intent for that server. Other agents' intent remains intact.
Outside an agent eval, pass `agent: "stable-agent-name"`. A PID is deliberately not a
persistent identity. The delivery function resolves `NanoAgent.whereis(name)` for
**each** event; no saved PID can strand a restarted agent.

## Durability and lifecycle

Add `{MCP, []}` to the application's supervisor after the agent runtime is available.
The first API call also starts MCP lazily if needed, but only the application hook
restores connections immediately at node boot. Supervising a manager which was already
lazy-started requires stopping/adopting that existing process first.

`/data/mcp/subscriptions.json` atomically records server → agent name → resource URIs.
It includes attachments even when no URI has been subscribed. State is loaded before
restoration; malformed existing state fails startup instead of silently forgetting
subscriptions. Disk write errors leave the previous state unchanged. Subscriptions
survive agent, connection and manager restart; transport reconnection reissues them.
Messages while the named agent is absent are not queued/replayed. Files are atomic
renames, not a power-loss-fsynced database.

`MCP.attach(agent_name, ["demo", ...])` durably attaches and initiates connection,
returning `:ok` or an error. It does **not** await readiness. Delegation can call
`MCP.await(server)` before waking its child; suspend the child during setup so a push
event cannot wake it prematurely. Cleanup is `MCP.detach(server, agent: child_name)` or
`MCP.detach_agent(child_name)`. Attach can partially succeed: clean up all requested
names if later setup fails. Readiness means discovery/initialization completed, not
that resource subscription acknowledgment has arrived.

Connections monitor transports and reconnect with 250 ms–30 s exponential backoff.
Failures arrive as `client/disconnected`; failed in-flight calls return errors and
are **never automatically replayed**, because tools may have side effects. Rejected
legacy subscriptions/unsubscriptions emit `client/subscription` or
`client/unsubscription`; call the same API again to retry. Desired state remains on
disk. Modern partial acknowledgment emits explicit unsupported-URI events. A graceful
modern subscription closure reopens only the stream, without killing unrelated calls.

Stdio uses direct executable+argv (no shell), newline JSON framing and separate stderr.
Closing the port closes stdin; an independent Linux `/proc` identity-checked reaper
then sends TERM after 100 ms and KILL after another 500 ms if the server ignores EOF.
This also runs when the transport is killed abruptly. It manages the direct child,
not arbitrary detached descendants. Stderr is inherited by the node, not converted
into RPC messages. Protocol logging notifications are forwarded as mailbox events.

## Configuration and trust

```json
{
  "servers": {
    "local": {
      "transport": "stdio",
      "command": "python3",
      "args": ["/app/config/mcp_demo.py"],
      "cwd": "/app",
      "env": {"TOKEN": "${MCP_TOKEN}"},
      "timeout_ms": 15000,
      "max_message_bytes": 8000000
    },
    "remote": {
      "transport": "http",
      "url": "https://example.org/mcp",
      "protocol_version": "2025-11-25",
      "headers": {"authorization": "${MCP_AUTHORIZATION}"}
    }
  }
}
```

Exact `${ENV_NAME}` strings in env/header values resolve from the process environment;
missing variables return a config error. Do not commit credentials. HTTP may access
configured private endpoints; there is no SSRF allowlist. Catalog changes require a
manager restart to reload. A configured server is trusted to execute with the node's
OS privileges. Returned content, instructions, prompts and tool annotations remain
**untrusted data**: this client never executes returned code, automatically invokes
tools, or uses server identity as authentication.

## Bounds and reading large results

API results default to 12,000 JSON bytes; push parameters to 6,000 bytes. Oversized
values return a small handle with `truncated: true`, byte count, preview and spill
path. `bytes:` adjusts API caps (256–32,000); `spill_dir:` selects an owned directory.
Protocol JSON is preserved. Elixir tuple-bearing aggregate discovery/error values
spill as a JSON string containing a full Elixir representation (not executable code).
Never `Code.eval_string` a spill. Preview bounds use bytes, including adversarial
combining-character strings. `MCP.page(path, offset: 0, bytes: 4000)` reads a bounded
byte page, returning base64 for pages that split UTF-8. `next_offset` is in bytes;
`:eof` ends paging. Binary MCP image/audio/blob fields remain base64 and are spilled,
not rendered or decoded automatically. Spill retention is operator-managed.

Wire frames cap at 8 MB by default (configurable); requests have timeouts. At most
48 requests may be pending in a connection. Legacy subscription reconciliation uses
at most 32 slots, leaving room for tool calls; desired URIs beyond that stay queued.
HTTP independently caps 64 sockets/workers. These are message/request bounds, not a
global notification rate quota; a hostile sustained flood still needs operator action.

## Protocol scope

Read on **2026-10-08** from `https://modelcontextprotocol.io/llms.txt`, which identifies
**2026-07-28** as current. Consult these when updating:

- `/specification/2026-07-28/basic/versioning`
- `/specification/2026-07-28/basic/transports/stdio`
- `/specification/2026-07-28/basic/transports/streamable-http`
- `/specification/2026-07-28/basic/patterns/subscriptions`
- `/specification/2026-07-28/server/discover`
- Legacy `/specification/2025-11-25/basic/lifecycle` and `/basic/transports`

Modern requests use per-request metadata and `server/discover`; there is no initialize
handshake. `subscriptions/listen` replaces legacy resources/subscribe and HTTP GET.
Stdio defaults to a modern probe and falls back to legacy initialization on legacy
errors/timeouts. An explicit current revision disables fallback. Recognized modern
unsupported-version errors do not trigger legacy fallback. Legacy supported revisions:
2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05 (stdio); configure legacy HTTP explicitly.
This is a useful feature subset, **not a claim of complete spec conformance**.

HTTP supports JSON and streaming SSE POST, legacy sessions/protocol headers/GET events,
modern metadata/method/name headers, long-lived subscription streams, stream cancellation,
TLS verification, CR/LF/CRLF and multiline/split SSE, and session expiry. Redirects are
not followed (credentials cannot leak across redirect origins). See `MCP.HTTP` docs.

Not implemented: OAuth/credential acquisition, JSON Schema validation, automatic
schema-derived `Mcp-Param-*` headers, MRTR/sampling/roots/elicitation automation, task
extensions, caching, legacy separate-endpoint HTTP+SSE, proxy configuration, HTTP/2,
Last-Event-ID replay/resumption. The lower-level HTTP transport offers
`send_message(pid, message, headers_map)` for already-validated per-message headers;
the high-level API does not derive them from schemas. Modern input_required results
are returned as explicit errors with payload; callers can supply inputResponses with
`MCP.request/4`. Unsupported legacy server requests receive -32601 (ping is answered).
Modern server-initiated requests are protocol errors. Explicit protocol configuration
is required rather than automatic HTTP era downgrade. Stream loss is visible and
subscriptions are re-established, but missed notifications cannot be recovered.

## Verification evidence

Automated tests: `MIX_ENV=test mix test test/mcp_test.exs test/mcp_stdio_test.exs
 test/mcp_http_test.exs`. They use unique temporary directories, OS pipes and local
HTTP sockets on port 0, never remote services or node-wide config. Tests cover modern
and legacy lifecycle, discovery, pagination, calls/reads/prompts, subscription events,
reconnect, disk restoration, retry/cancellation, process cleanup, malicious Unicode
bounds, corrupt state, spill failure, HTTP session expiry and SSE framing.

Final verification: 36 MCP tests passed; the complete worktree suite passed **323 tests**.
`mix format --check-formatted` on owned Elixir files and `mix compile --warnings-as-errors`
passed with `MIX_ENV=test`. Two pre-existing test-only warnings remain in the seed suite
(`nano_agent_test.exs` unused variable and `agent_live_test.exs` unused optional default).

Live evidence from this build (2026-10-08):

1. Demo modern discovery/call/read/prompt, subscription ack then resource update after
   idle appeared in deneb-mcp timeline events 18–21. Stopping/restarting the private
   manager restored the subscription; events 26–27 and 31 show the restored ack/update.
2. Official `@modelcontextprotocol/server-filesystem@2026.8.31`, installed under
   `/tmp/deneb-mcp-reference` using Node 22.22.2 arm64, negotiated legacy 2025-11-25 via
   stdio fallback. Tools discovery and `list_directory` of `/data/deneb-mcp-live`
   succeeded. Tool schema result (12,983 bytes) spilled instead of filling context.
   This reference server is a live check, not a required install or committed dependency.
3. Public `https://mcp.deepwiki.com/mcp` negotiated legacy 2025-03-26 with the high-level
   client. Tools discovery and `read_wiki_structure` for `modelcontextprotocol/servers`
   succeeded; 2,465-byte result was intentionally capped/spilled with bytes:1800 to
   `/data/deneb-mcp-live/spill/nm9WCztUrEWd8x1H.json`. Live availability is not guaranteed.

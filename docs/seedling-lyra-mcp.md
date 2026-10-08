# MCP: stdio and Streamable HTTP

Entry: `Seedling.MCP`. Boot child (parent owns harness integration):

```elixir
{Seedling.MCP.Supervisor, [name: Seedling.MCP.Connections,
  config: "/app/config/mcp.json", state_dir: "/data/mcp"]}
```

Start after `Nano.Names` and before agent restoration. Configured connections restore
on boot; durable named subscriptions and watchers replay automatically. Each delivery
resolves `NanoAgent.whereis(name)`, so agent PID replacement requires no MCP intervention.
Boot notifications sent before an agent exists are not queued; future updates still route.

```elixir
{:ok, c} = Seedling.MCP.ensure_connection("fetch") # default sup: MCP.Connections
Seedling.MCP.watch(c, "lyra") # durable, all eligible notifications
Seedling.MCP.status(c) # async opening: ready, era, version, info
Seedling.MCP.discover(c) # one bounded page each: tools/resources/templates/prompts
Seedling.MCP.discover(c, all: true) # explicit cursor following, maximum 100 pages
Seedling.MCP.call_tool(c, "fetch", %{"url" => "https://example.com", "raw" => true})
Seedling.MCP.read_resource(c, "test://one")
Seedling.MCP.get_prompt(c, "prompt", %{})
Seedling.MCP.subscribe(c, "test://one", "lyra") # persists; modern waits for ack
Seedling.MCP.unsubscribe(c, "test://one", "lyra")
Seedling.MCP.result_page(spill.path, offset: 0, limit: 8000) # byte paging on disk
```

`ensure_connection(name, supervisor: registered_name_or_pid, config: path)` returns or
starts a supervised configured client. `connect(name, config: path)` starts a standalone
linked client instead. Use `Supervisor.connections(sup)` to get current pids after child
restart. Parent/delegation should never unlink ad-hoc clients as a substitute for supervision.

Mailbox events: `{:mcp, server_name, method, params}`. Includes server notifications,
`connected`, `disconnected`, `recovered`, `subscription_restored`,
`subscription_filter_reduced`, and errors. All calls before ready return disconnected.
Legacy JSON-RPC errors preserved. In-flight calls fail immediately on disconnect.
Reconnect creates a fresh transport, re-probes the protocol and restores subscriptions.

## Reproducible official reference server

Default `config/mcp.json` is deliberately empty. `config/mcp-fetch.example.json` describes
real fetch, executable `/data/seedling/mcp-fetch/bin/mcp-server-fetch`.

Install: `apt-get install python3-venv` then `sh config/mcp-install-fetch.sh`.
Installer pins `mcp-server-fetch==2026.8.18` in its own durable venv. Installed/tested here.
Connect with `ensure_connection("fetch", config: "/app/config/mcp-fetch.example.json")`
or add its server entry to the main config for automatic boot. Dynamic clients survive
client crashes, but reboot restoration requires their entry in the main boot config.
No Node required: server falls back to pure-Python readability if absent. During testing
a sibling installed Node20, which breaks latest Readability.js dependencies requiring
Node22+. Use fetch `raw: true` for reliable HTML retrieval here; default markdown
conversion passed before Node install but now errors. This is upstream, not MCP framing.

Config shape: `{"mcpServers":{"name":{"command":"python3","args":["-m",
"mcp_server_fetch"],"env":{},"cwd":"/tmp"}}}`. HTTP uses `url` and optional static
`headers`. Commands are trusted local execution. Do not commit secrets.

## Version evidence and coverage

Checked official `https://modelcontextprotocol.io/specification/versioning.md` and
`/specification/latest.md` on 2026-10-08: CURRENT **2026-07-28**, not 2025-11-25.
Latest specification references `schema/2026-07-28/schema.ts`. Read lifecycle,
stdio/Streamable HTTP bindings, discovery, subscriptions, tools/resources/prompts,
metadata, progress and ping revision-change notes. Prior initial pin was corrected.

Client now probes `server/discover` with 2026-07-28 `_meta` protocolVersion,
clientCapabilities and clientInfo. Modern requests carry these per-request fields;
no initialize or legacy GET is sent. Durable subscriptions use long-lived
`subscriptions/listen`, ack, subscriptionId correlation, cancellation and reconnect.
Modern HTTP sends `Mcp-Method`, `Mcp-Name` and matching protocol header. After tools/list
(discovery), it mirrors validated `x-mcp-header` primitive/nested parameters; malformed
definitions are rejected from tools/list. Base64 sentinel format follows current spec.
Raw `request` permits advanced methods; no automatic MRTR/input-required orchestration,
cache freshness policy, roots, sampling, elicitation, tasks or OAuth advertised.

Non-modern discovery errors/timeouts fall back to legacy initialize (2025-11-25 request,
uses returned negotiated version). Legacy resource subscribe/unsubscribe, initialized,
HTTP sessions and GET SSE supported. Best-effort HTTP DELETE cleanup on closing legacy
session. Recognized modern -32020/-32021/-32022 probe errors do NOT silently fall back.
Only 2026-07-28 modern version supported; unsupported modern versions are surfaced.
Current protocol deliberately has NO sessions/GET/DELETE/Last-Event-ID. Legacy resumable
Last-Event-ID and deprecated HTTP+SSE are not implemented. Disconnect windows lose events.

## Bounded results and persistence

Results/notifications/status info larger than `max_result_bytes` (default 12000) spill as
JSON to `state_dir/results/` (mode 0600), returning path, bytes, 1000-character preview
and paging instructions. `result_page` reads bounded bytes, preserves UTF-8 page boundaries,
and returns next_offset; no full-file read required. Cursor retained on spilled list pages.
`page` provides character-based paging for an already-small in-memory result.
Spills survive client restart; no automatic expiration/retention (delete with File.rm).
Incomplete transport frames capped at 16 MB. Large complete stdio frames still require
transient decode memory but never flow uncapped to agent results/mailbox. Discovery is
one page by default; all:true explicit aggregate can be large (print via page).

Subscriptions/watchers stored atomically at `/data/mcp/<base64-server-name>.json` (or
state_dir). Single writer per server/state_dir; no multiwriter lock. Corrupt state currently
falls back to empty; filesystem write failures crash rather than falsely ack durability.
Replayed modern ack includes honored filter and reports reductions. A requested but
unsupported filter remains durable desired state so capability changes can restore it.
HTTP request/stream workers have 300s receive timeout; stream EOF reconnects, legacy GET
EOF retries at 1s, GET405 disables push. No OAuth refresh or auth discovery; headers static.

## Tests and live use

`MIX_ENV=test MCP_FETCH_COMMAND=/data/seedling/mcp-fetch/bin/mcp-server-fetch mix test
 test/mcp_test.exs test/mcp_http_test.exs test/mcp_modern_test.exs
 test/mcp_modern_http_test.exs test/mcp_reference_test.exs`

Real subprocess fixtures cover legacy/current discovery, resource reads, errors/timeouts,
server death, supervisor/client/agent restart, durable watchers/subscriptions, modern
correlation/ack and >60KB disk/UTF-8 paging. Port-0 HTTP fixtures cover legacy JSON/session/
POST SSE and modern real long-lived SSE push, mirrored headers, malformed tool filtering,
server-close recovery. Official fetch reference test actually fetches example.com; skips
unless MCP_FETCH_COMMAND set. No Nano module was loaded by this agent.

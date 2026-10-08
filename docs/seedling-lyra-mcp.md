# MCP

`Seedling.MCP` is the entry point; client and supervisor docs provide details.

```elixir
{:ok, sup} = Seedling.MCP.Supervisor.start_link(config: "config/mcp.json")
clients = Seedling.MCP.Supervisor.connections(sup)
c = clients["filesystem"]
Seedling.MCP.status(c) # wait until ready before requests
Seedling.MCP.discover(c) # paginated tools/resources/templates/prompts
Seedling.MCP.call_tool(c, "read_file", %{"path" => "/tmp/example"})
Seedling.MCP.read_resource(c, "test://one")
Seedling.MCP.subscribe(c, "test://one", "lyra")
Seedling.MCP.watch(c, "lyra") # all notifications, not persisted
Seedling.MCP.page(result, offset: 0, limit: 8000) # print this, not large raw results
```

`connect("server", config: path)` also starts an individual linked client. For boot
persistence add the MCP supervisor to application children (not automatically injected
into the harness). Its child ids are configured server names. Get current pids via
`connections/1` after child crashes. Config intentionally ships empty; commands are
trusted local execution, not a security boundary.

Config format is standard `{"mcpServers":{"name":{"command":"python3",
"args":["-m","mcp_server_fetch"],"env":{},"cwd":"/tmp"}}}`. HTTP instead uses
`{"url":"https://host/mcp","headers":{"Authorization":"Bearer ..."}}`.
Never commit secrets. Headers are static: no OAuth discovery/refresh implemented.

Mailbox events are `{:mcp, server_name, method, params}`. `watch` receives all;
subscriptions receive updates for their URI and connection/list/log/progress events.
Every delivery resolves agent name through `NanoAgent.whereis/1`, so agent PID changes
are safe. Subscriptions persist at `/data/mcp/<base64-server-name>.json` (or `state_dir`)
and replay after client or server restart. One client per server/state_dir; no multiwriter
locking. A corrupt state file is currently treated as empty. Filesystem persistence
failure crashes the client rather than falsely acknowledging durability.

Wire version: 2025-11-25 stable. Discovery of the public specification/latest on
2026-10-08 showed newer revision references in navigation; this implementation is
explicitly pinned, not claiming support for future/draft versions. No sampling, roots,
elicitation or experimental tasks capabilities advertised; server requests get -32601.
Raw JSON-RPC errors preserved. Transport disconnects immediately fail pending calls and
emit events; reconnect starts a fresh session and replays durable subscriptions.

StdIO uses newline-delimited UTF-8 JSON; stderr is not mixed into protocol stdout.
HTTP implements JSON or SSE POST responses, session-id and protocol headers, GET SSE
push streams, CRLF/multiline SSE decoding, and fresh initialization on HTTP failure.
405 GET disables push stream. No legacy HTTP+SSE transport, Last-Event-ID replay,
OAuth, or DELETE session cleanup. Restart can lose events in the disconnect window.
HTTP request workers have 300-second receive timeout; SSE EOF retries after one second.
Initial connection is asynchronous; calls before ready return `{:error,:disconnected}`.
Initialization/request timeouts are bounded; do not poll in an agent loop when `watch`
can notify readiness. Incoming incomplete frames capped at 16 MB; large complete StdIO
frames and discovery aggregates are not hard-capped. Use paging before printing.

Tests (isolated MIX_ENV=test):
- `mix test test/mcp_test.exs test/mcp_http_test.exs`: real Python subprocess fixture
  covers discovery, resource reads, JSON-RPC errors/timeouts, notifications, server death
  reconnect, durable client restart and agent-name rerouting. HTTP fixture uses Bandit
  port 0 and covers JSON, session propagation and POST SSE notification/response.
- `MCP_FETCH_COMMAND=/tmp/lyra-mcp/venv/bin/mcp-server-fetch mix test test/mcp_reference_test.exs`:
  actual official Python fetch reference server discovery + https://example.com fetch,
  passed (Readability falls back to Python without Node). Optional test skips without env.
  `mcp-server-fetch` installed in agent-private venv; not a project dependency.
No MCP or Nano module was loaded into the live node during development.

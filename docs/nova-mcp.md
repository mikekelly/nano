# Nano.MCP — nova-mcp implementation

MCP is a library callable from `eval`, not a new harness tool. It implements
**2025-11-25**, checked against upstream's `schema/2025-11-25/schema.ts` and
https://modelcontextprotocol.io/specification/2025-11-25 on 2026-10-07.
Initialization also accepts 2025-06-18, 2025-03-26 and 2024-11-05 on compatible
servers. This is a client, not an MCP server.

## First use

```elixir
{:ok, server} = Nano.MCP.connect("files")
Nano.MCP.status(server)                       # negotiated capabilities + server info
Nano.MCP.tools(server)                        # one bounded page, nextCursor preserved
Nano.MCP.resources(server)
Nano.MCP.resource_templates(server)
Nano.MCP.prompts(server)
Nano.MCP.call_tool(server, "read_file", %{"path" => "/tmp/example"})
Nano.MCP.read_resource(server, "file:///tmp/example")
Nano.MCP.get_prompt(server, "greeting", %{"name" => "world"})
Nano.MCP.subscribe(server, "file:///tmp/example", "my-agent")
# idle; receive {:mcp, "files", "notifications/resources/updated", %{"uri" => ...}}
Nano.MCP.unsubscribe(server, "file:///tmp/example", "my-agent")
```

The server argument can be its stable name or connection PID. Use the name if
code must keep working after the connection process itself is restarted.
`ready/2` waits for initialization, `status/1` does not wait, and `disconnect/1`
removes the supervised connection (configured servers reconnect on next boot).

## Configuration and lifecycle

`config/mcp.json` is tracked, initially empty. Add the `Nano.MCP` child to the
application supervision tree. It starts a registry, dynamic connection supervisor
and bootstrap loader. At boot the loader connects all configured servers and
restores subscriptions. `connect/2` also starts this tree lazily under
`Nano.Supervisor`, so adding the application child is not needed for first use,
but **is needed for unattended restoration on node boot**.

Example configuration (commands are trusted executable programs):

```json
{
  "mcpServers": {
    "files": {
      "command": "/usr/bin/npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
      "cwd": "/tmp"
    },
    "remote": {
      "url": "https://example.invalid/mcp",
      "headers": {"Authorization": "${MCP_AUTHORIZATION}"}
    }
  }
}
```

Never commit credentials. A whole `${ENV_NAME}` value in `headers` or stdio
`env` is expanded at transport use. The header example expects the environment
value to include the authorization scheme. HTTP redirects are disabled to avoid
forwarding credentials to another origin. OAuth discovery/login/token refresh is
not implemented: provision authorization externally. Legacy HTTP+SSE transport
(2024 separate `/sse` and `/messages` endpoints) is not implemented; use stdio or
**Streamable HTTP** at a single URL.

For temporary connections:

```elixir
Nano.MCP.connect("local-fixture",
  config: %{"command" => "python3", "args" => ["/tmp/server.py"]},
  state_dir: "/tmp/my-isolated-mcp-state")
```

Connection options: `config`, `config_path` (default `/app/config/mcp.json`),
`state_dir` (default `/data/mcp`), initialization wait `timeout` (15 seconds), and `recipient` (watch recipient).
Set `recipient: child_name` during delegation to avoid watching on behalf of the
setup caller, or `recipient: false` to disable automatic watching.
Supervisor options `config_path` and `state_dir` apply to boot-loaded servers.
`load_config/1` returns `{:ok, server_map}` or a file/JSON/config error.
Servers must emit newline-delimited JSON on stdio stdout; stderr is not treated
as protocol data. A connection initializes, sends `notifications/initialized`,
then starts its HTTP GET notification stream if supported. JSON and incremental
SSE POST responses are both supported, as are session ID/protocol headers,
HTTP 404 session expiry and GET 405 (no unsolicited stream). SSE data is
forwarded **before EOF**, not buffered until an infinite stream ends.

A dead stdio server fails all outstanding calls immediately, emits
`client/disconnected`, and reconnects with capped exponential backoff. HTTP POST
transport failure does the same. Resource subscriptions are replayed after each
successful initialization. HTTP GET failures emit `client/event_stream_error`
and retry. GET event-ID replay/Last-Event-ID is not implemented, so notifications
during a transport gap can be lost. Calls are not silently retried: a tool might
have side effects. Server-origin `ping` is answered; requests for client features
not advertised (sampling, roots, elicitation) get JSON-RPC method-not-found.

## Events and durability

All MCP notifications, including resource/tool/prompt list changes, logs and
progress, are forwarded unchanged (subject to byte bounding) as:

```elixir
{:mcp, server_name, method_string, params}
```

`watch(server, recipient)` watches **all** notifications and lifecycle events.
`connect/2` automatically watches on behalf of its caller. Resource subscribers
also receive their resource updates and disconnect/subscription-error events.
Membership changes are serialized per resource URI, preventing out-of-order RPC
responses from resurrecting stale subscriber membership.
An agent PID is automatically resolved to its registered stable agent name.
Harness eval runs in a Task: the task's `$callers` chain is inspected to resolve
its owning agent, so default subscribers/watchers and call telemetry reach the
agent mailbox rather than the short-lived eval task;
explicit stable names also work even when the agent is temporarily absent. These
names are persisted per server in mode-0600 JSON files, atomically renamed under
`state_dir`, and resolved using `NanoAgent.whereis/1` at event delivery. Therefore
subscriptions survive agent, connection and node restart. The server must be in
persisted configuration for automatic restoration after a full node boot.
Ordinary non-agent PIDs are ephemeral and not persisted. Agent absence does not
remove its subscription; unsubscribe explicitly when finished. Notifications are
not a durable queue and events while an agent is absent are not replayed.

Calls emit `client/request` (method only) and `client/result` (success boolean)
mailbox events, so actions and server pushes appear through the existing harness
mailbox/eval timeline without dashboard changes. Tool arguments, config/env values
and authorization headers are not copied into these telemetry events. Server
notifications themselves may contain sensitive data, as may tool responses: use
trusted servers and appropriate access controls.

## Results, paging, binary data and errors

Most calls return `{:ok, protocol_result}` or `{:error, reason}`. A tool's protocol
`isError: true` remains an ordinary successful JSON-RPC response, not a transport
error. RPC errors return `{:error, {:rpc, error_object}}`. Timeout returns
`{:error, :timeout}` and sends a cancellation notification; the connection stays
usable. Calls while disconnected return `{:error, :not_ready}`. Unsupported
resource subscriptions return `{:error, :unsupported_subscription}`.

Results over **16 KiB** are written to a private unique file, not silently cut:

```elixir
{:ok, %{spilled: true, path: path, bytes: total, preview: _}} = result
Nano.MCP.Result.page(path, offset: 0, limit: 8192)
# {:ok, %{data: json_bytes, next_offset: 8192}}; {:ok, :eof} at end
```

Spills default to `/tmp/nano-mcp-results`, mode 0600. Callers own their retention
and cleanup. `preview` is at most 2,000 bytes and may end mid-JSON/UTF-8; the full
JSON is always preserved. Large notification parameters use the same spill shape.
Binary/image/audio content remains protocol base64 in the JSON result or spill;
no decoding or accidental binary expansion is performed. Decode deliberately
using `Base.decode64/1` on a selected content `data` or resource `blob` field,
then write to your own task directory or construct `Nano.Image` as appropriate.

Listing functions retrieve **one page**, preserving the server's `nextCursor`:

```elixir
Nano.MCP.tools(server, cursor: next_cursor)
Nano.MCP.call_tool(server, "work", %{}, timeout: 60_000,
  progress_token: "job-1", max_bytes: 8192, spill_dir: "/tmp/my-task-results")
Nano.MCP.request(server, "ping", %{})
```

Request options: `timeout` (30 seconds), `max_bytes`, `spill_dir`, `meta` and
`progress_token` (sent in `_meta.progressToken`). Generic `request/4` enables
extensions without changes to the harness. No client sampling/roots/elicitation,
experimental task API, OAuth flow, legacy SSE transport, event replay, or automatic
binary-to-image conversion is claimed. Incoming frames are limited to 16 MiB;
this protects transport buffering independently of printed result limits.

## Validation

`MIX_ENV=test MIX_BUILD_ROOT=/tmp/nova-mcp/_build mix test test/mcp*test.exs`
passed **10 tests**. They use a local Python stdio JSON-RPC fixture and local
Bandit on port 0: lifecycle/initialization, live discovery/cursors, tools,
resources/prompts, mailbox list/progress/resource notifications, server ping,
RPC errors/timeouts/reconnect, restart-safe explicit and automatic identities,
spills/paging, config validation, incremental SSE, HTTP session/version headers,
and notifications delivered before a GET stream ends.

Full checkout suite passed **255 tests** at implementation time. A real, uncredentialed Streamable HTTP smoke test also passed against
`https://mcp.deepwiki.com/mcp` (DeepWiki 2.14.3): negotiated 2025-11-25, discovered
`ask_wiki_question`, `read_wiki_contents`, `read_wiki_structure`, and successfully
called `read_wiki_structure` for `modelcontextprotocol/modelcontextprotocol`
(one 1,594-byte text result, `isError: false`). It used an isolated temporary
state directory and no secrets. No credentialed server or npx reference server
was exercised; Node installation is not needed for these tests. Tests use unique temporary directories and ephemeral
ports, never `/data` or shared application environment. Integration entry point
for the main agent: add `Nano.MCP` to application children; its modules own no
harness changes.

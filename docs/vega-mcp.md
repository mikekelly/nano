# Vega.MCP — MCP tools and mailbox events

Discover from `Vega.MCP` module docs. Configuration: **`/app/priv/vega_mcp.json`**
(`mcpServers` map); no servers are launched merely by reading the file.

```elixir
Vega.MCP.servers()
Vega.MCP.connect("filesystem")
Vega.MCP.tools("filesystem")
Vega.MCP.call_tool("filesystem", "list_directory", %{"path" => "/tmp"})
Vega.MCP.resources("server")
Vega.MCP.resource_templates("server")
Vega.MCP.prompts("server")
Vega.MCP.get_prompt("server", "greeting", %{"name" => "Vega"})
Vega.MCP.read_resource("server", "resource://value")
Vega.MCP.watch("server", "agent-name")
Vega.MCP.subscribe("server", "resource://value", "agent-name")
# Ordinary events now wake the agent. Idle using the normal harness idle tool.
Vega.MCP.unsubscribe("server", "resource://value", "agent-name")
Vega.MCP.unwatch("server", "agent-name")
Vega.MCP.status("server")
Vega.MCP.disconnect("server")
```

`{:ok, value}` / `{:error, reason}` throughout; subscription/watch mutations return
`:ok`. List functions fetch **one** page. Pass the returned `nextCursor` to the same
list function to continue. `request/4` exposes other legacy JSON-RPC methods; unknown
client requests get a JSON-RPC MethodNotFound response, except `ping` is answered.
No sampling, elicitation, roots, or tasks capabilities are advertised.

## Protocol source and revision (network read 2026-10-07)

Fetched authoritative pages using HTTPS:

- https://modelcontextprotocol.io/specification/latest.md
- https://modelcontextprotocol.io/specification/2026-07-28/basic/lifecycle.md
- https://modelcontextprotocol.io/specification/2026-07-28/basic/transports.md
- https://modelcontextprotocol.io/specification/2025-11-25/basic/transports.md

**Important revision mismatch:** latest now identifies **2026-07-28**, a breaking
stateless/per-request-metadata protocol with `server/discover` and no initialization
handshake. This implementation deliberately provides the seeding's initialization,
persistent connection and subscription semantics for **2025-11-25**, negotiating
**2025-06-18** or **2025-03-26** when the server selects one. It does **not** claim to
implement the modern 2026-07-28 protocol. A modern-only server is unsupported; a
server exposing a legacy compatibility endpoint is usable. Updating to modern
requests/metadata and streaming subscriptions is future work, not silently emulated.
The old 2024 HTTP+SSE two-endpoint transport is also unsupported.

## Transports and configuration

stdio definitions have `command`, optional string-list `args`, optional string-map
`env`, optional `cwd`, and optional integer `result_limit`. Arguments go directly to
`Port.open` without a shell; stderr is not mixed into protocol stdout. As normal
subprocesses, servers inherit the VM environment plus configured overrides. Run only
trusted server executables and avoid giving untrusted servers sensitive environment.
The example uses `npx`, which requires Node/npm installed; dependencies are not
installed implicitly by Vega.MCP. Pin package versions for production.

Streamable HTTP definitions have `url` (`http` or `https`), optional `headers` map,
and `result_limit`. Example (no keys in git):

```elixir
Vega.MCP.connect("remote", %{"url" => "https://example.test/mcp",
  "headers" => %{"authorization" => "Bearer " <> System.fetch_env!("MCP_TOKEN")}})
```

Supports one POST per message, JSON and incrementally parsed SSE responses, a
long-lived GET SSE notification stream, session ID/version headers, and HTTP 405
(no independent stream). SSE GET reconnect uses `Last-Event-ID` and `retry` when
provided. No automatic POST retries: tool side effects must not run twice. Errors,
including expired session HTTP 404, fail pending calls and start a fresh handshake.
Authentication is explicit supplied headers; OAuth/token refresh and old two-endpoint
SSE are not provided. Redirects are disabled so authorization isn't forwarded to
another host. POST stream resumption isn't implemented; an interrupted call fails
rather than being replayed. No exactly-once event guarantee during transport downtime.

Connections are independently supervised with exponential reconnect (250ms to 30s),
request timeouts/cancellation, death notifications, and subscription restoration.
`connect` waits for initialization and returns an error promptly on failed launch;
the worker continues retrying until `disconnect`. A call in downtime returns
`:not_ready`; it is not invisibly queued or replayed. Up to 128 generic RPC requests
are pending; further requests return `:busy`. Concurrent mutations for the same
resource return `:subscription_busy`, so retry after the earlier operation finishes.

`Vega.MCP.start/0` lazily starts an unlinked supervision tree for eval use. For an
application-managed lifecycle, integrate `{Vega.MCP.Supervisor, []}` into the parent
application tree. This task changes **no** harness modules. Override config location
with application env `:nano, :vega_mcp_config`.

## Events, identity and persistence

Events look like:

```elixir
%{mcp: "server", method: "notifications/resources/updated",
  params: %{"uri" => "resource://value"}}
%{mcp: "server", method: "connection/dead", params: %{"reason" => "..."}}
```

Resource updates reach all named subscribers for that URI. `watch` additionally
forwards all notifications (list changes, logs, progress, etc.). Connection ready /
dead reports reach watchers and resource subscribers. Subscription restoration
failures emit `subscription/failed` and never silently discard durable interests.
Names are resolved by `NanoAgent.notify/2` at event delivery, not cached pids, so
agent process restart needs no re-subscribe. The harness logs these ordinary events
in the timeline. Agent eval calls/results are logged by the existing harness.

Interests (names + URIs only, not secrets/config) are atomically replaced in
`/data/vega-mcp/subscriptions.json`; application env `:vega_mcp_state_dir` overrides
this root. They survive connection/agent/state-process restarts. After a whole node
boot or deliberate `disconnect`, reconnect a server by name; saved interests restore
on handshake. Offline-agent events aren't queued by this module: subsequent events
reach its replacement, but events during the restart gap may be lost. No durable
server-config cache or automatic launch of all configured servers at node boot.

## Bounded results

Default JSON return/event cap is 16 KiB (configurable `result_limit`, clamped to
256..32768 bytes). Oversize maps/lists including embedded base64 binary become:

```elixir
{:ok, %{truncated: true, bytes: 123456, preview: "...", spill: "/data/vega-mcp/results/unique.json"}}
Vega.MCP.page(spill, offset: 0, limit: 8192)
```

Spills retain exact JSON. Pages are byte-oriented (UTF-8 codepoints can straddle a
page), at most 32 KiB. `next_offset: nil` indicates EOF. There is an 8 MiB inbound
frame/buffer bound for stdio/HTTP; exceeding it disconnects rather than allocating an
unbounded result. Spill files aren't garbage-collected; operators should rotate the
results directory as appropriate. State/spill filesystem errors are reported.

## Tests

```sh
MIX_ENV=test MIX_BUILD_ROOT=/tmp/vega-mcp-build ERL_FLAGS='+S 4:4' \
  mix test test/vega_mcp_test.exs test/vega_mcp_reference_test.exs
```

Hermetic integration uses a real Python OS subprocess and localhost HTTP server on
port 0, including fragmented POST SSE and independent GET push notifications.
Tests cover named-agent replacement, actual NanoAgent restart and timeline logging,
connection/state process death, OS server death/reconnect, restoration/unsubscribe,
JSON-RPC errors, protocol refusal/negotiation, pagination, concurrency, timeouts and
lossless spills. State/tmp directories are fresh per run; no live-node env is changed.

Official reference test is opt-in (skip is explicit otherwise), with no runtime npm
installation by the test:

```sh
npm install --prefix /tmp/vega-mcp-tools @modelcontextprotocol/server-filesystem@2026.8.31
VEGA_MCP_REFERENCE_NODE=/path/to/node \
VEGA_MCP_REFERENCE_FILESYSTEM=/tmp/vega-mcp-tools/node_modules/@modelcontextprotocol/server-filesystem/dist/index.js \
MIX_ENV=test ERL_FLAGS='+S 4:4' mix test test/vega_mcp_reference_test.exs
```

The filesystem test uses only its temporary allowed root and verifies discovery,
write/read and denied access outside that root. Push-event coverage uses the local
wire server; the official filesystem reference does not advertise subscriptions.

### Verified on 2026-10-07

- MCP focused suite with reference enabled: **17 passed** (16 hermetic + 1 official).
- Official `@modelcontextprotocol/server-filesystem` version **2026.8.31**, run by
  Node **v20.19.2**; legacy negotiation/discovery/write/read/path-denial all passed.
- Final full repository suite with the reference enabled: **264 passed**, no skips
  (25.4 seconds). Without the opt-in reference environment, that one test is
  explicitly skipped.
- Node runtime was installed as an allowed system package; npm dependencies were
  installed only under `/tmp/vega-mcp-tools`. No harness modules were loaded into
  the live VM, no live application settings were changed, and no credentials were
  needed. Production use of the `npx` sample still requires npm/npx on PATH.

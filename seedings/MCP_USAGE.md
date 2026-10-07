# MCP from eval

`Seedling.MCP` is the client; no harness or router changes are required. Messages forwarded
to named agents are ordinary mailbox events and therefore appear in their dashboard
**timeline**. No model call is needed to discover or operate a server.

## Connect and discover

Create a config under `/app`, using the conventional `mcpServers` object:

```json
{
  "mcpServers": {
    "files": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/app"],
      "cwd": "/app",
      "env": {}
    },
    "remote": {
      "url": "http://127.0.0.1:8080/mcp",
      "headers": {"Authorization": "Bearer REPLACE_ME"}
    }
  }
}
```

Install Node/npm separately if using the reference filesystem server. They are not a client
dependency; any executable speaking newline-delimited MCP JSON-RPC works. The config is
trusted: commands run as the node's OS user and URLs can access the node's network.
Never load a server config from an untrusted prompt without reviewing it.

```elixir
Seedling.MCP.load("/app/priv/seedling_mcp.json", notify: "my-agent")
# [{"files", {:ok, server_info}}, ...]

# Or connect one server directly:
Seedling.MCP.connect("files", %{"command" => "npx",
  "args" => ["-y", "@modelcontextprotocol/server-filesystem", "/app"]},
  notify: "my-agent", timeout: 15000)

Seedling.MCP.servers()
Seedling.MCP.info("files")
Seedling.MCP.tools("files")
Seedling.MCP.resources("files")
Seedling.MCP.resource_templates("files")
Seedling.MCP.prompts("files")
```

Results are `{:ok, map}` or `{:error, reason}`. JSON keys remain strings. Inventory calls
return **one server page**, including its `nextCursor`; continue explicitly with
`tools("files", cursor: cursor)` (likewise resources/templates/prompts). No automatic
full-inventory expansion. Capabilities/instructions in `info` are self-reported, not trusted
policy. Unsupported inventory methods return the server's JSON-RPC error.

```elixir
Seedling.MCP.call_tool("files", "read_text_file", %{"path" => "/app/README.md"})
Seedling.MCP.read_resource("remote", "example://status")
Seedling.MCP.get_prompt("remote", "summarize", %{"topic" => "MCP"})
# Generic escape hatch; do not manually initialize an already connected server:
Seedling.MCP.request("remote", "logging/setLevel", %{"level" => "info"})
```

Default request timeout is 30 seconds; override `timeout: 5000` on each call. Failed or
interrupted calls are **not replayed**: a tool may have had side effects before disconnect.
Tool results with `isError: true` are still protocol success `{:ok, result}`; check that field.

## Events, subscriptions and restarts

```elixir
Seedling.MCP.listen("remote", "my-agent")
Seedling.MCP.subscribe("remote", "example://status", "my-agent")
# :ok means desired subscription persisted, not that the server has acknowledged it.
Seedling.MCP.unsubscribe("remote", "example://status", "my-agent")
Seedling.MCP.unlisten("remote", "my-agent")
```

The recipient is the **agent name**, not `self()` from eval (which is a short-lived task).
The client resolves the name through `NanoAgent.whereis/1` on every delivery:

```elixir
{:mcp, "remote", "notifications/resources/updated", %{"uri" => "example://status"}}
{:mcp, "remote", "notifications/tools/list_changed", %{}}
{:mcp, "remote", "notifications/message", %{...}}
{:mcp, "remote", "notifications/progress", %{...}}
{:mcp, "remote", "connection/down", %{reason: "...", retry_ms: 1000}}
{:mcp, "remote", "connection/ready", %{}}
```

Resource updates reach subscribers to that URI, and all notifications/status reach listeners.
Modern subscription acknowledgments are forwarded too: check their accepted `notifications`
filter; unsupported event types may be omitted by the server. Legacy subscription replies
arrive as `subscription/result` events, including errors. Stdio stderr stays separate from
JSON-RPC stdout (it goes to the node's OS stderr). Invalid JSON produces a warning event.

A supervised manager retains connection config, listener names and subscription URIs in an
atomically replaced, mode-0600 JSON file. Default location:
`Application.get_env(:nano, :state_dir)/seedling_mcp.json` (fallback `/data/state`). Override
with `:mcp_state_path`. Restored connections reopen on node boot; a killed connection is
restarted; dead transports reconnect with 1s–30s backoff and restore desired subscriptions.
A replaced agent retains subscriptions because its name, not its old pid, was saved.

This is **subscription durability, not a durable event queue**: notifications while an agent
name has no live process are dropped. Re-read the resource after restart to reconcile. No
exactly-once or historical-event guarantee. Credentials in config are persisted; protect the
state directory and omit secrets from logs. `disconnect(name)` closes the transport and
removes its persisted entry. Servers are shared by name across agents; one agent's disconnect
affects all users of that server. A different config for an existing name is rejected.

## Result size

Results stay below 24 KB by default (override `max_bytes`, clamped 256–48000). A larger result
is saved as JSON and replaced with:

```elixir
{:ok, %{truncated: true, bytes: 123456, path: "/data/seedling/mcp/results/...json",
        preview: "..."}}
```

Read that path with `Seedling.Files.read/2` or parse it only when needed. Binary MCP content
remains its protocol base64 representation; the client does not eagerly decode images/audio
or fetch icons. Result files are not automatically deleted. Configure `:mcp_result_dir` to
change their location. Transport frame budgets additionally limit untrusted network/process
output; spill files do not authorize unlimited incoming frames.

## Protocol coverage

Read and targeted **2026-07-28**, the revision reached by
`https://modelcontextprotocol.io/specification/latest` on 2026-10-07. It differs materially
from 2025 MCP: `server/discover`, per-request `_meta` version/capabilities, stateless HTTP,
and `subscriptions/listen` streams replace initialization sessions and resource subscribe.
The client probes discovery first. Legacy stdio/HTTP servers that return a non-modern error
(or time out) fall back to initialization; supported legacy revisions are 2025-11-25,
2025-06-18, 2025-03-26 and stdio 2024-11-05. The deprecated separate HTTP+SSE transport is
not implemented. HTTP JSON and SSE responses, legacy session/version headers and GET event
streams, modern POST listen streams are supported. Redirects and automatic POST retries are
disabled. HTTP tools with `x-mcp-header` declarations require discovery before call.

No sampling, elicitation, roots, OAuth discovery/login, modern MRTR input resolution, icon
rendering or extension negotiation is advertised. Legacy server requests for unsupported
client capabilities receive `-32601`; ping is answered. Modern input-required results remain
visible to the caller and must be handled explicitly, rather than silently spending on a
model or following server instructions. Authorization headers can be provided explicitly.
Use trusted servers only; all server text and events are untrusted data.

## Validation

`env -u MIX_BUILD_PATH MIX_ENV=test mix test test/seedling_mcp_test.exs test/seedling_mcp_http_test.exs`

Tests use Python stdio fakes and local HTTP fakes, with no model calls. Coverage includes
modern discovery, legacy initialization, resource/prompt/tool inventory, request metadata,
resource read/tool call, result spills, JSON-RPC errors/timeouts, process death/reconnect,
named mailbox replacement, persisted restore, HTTP JSON/SSE/session handling and transport
limits. See implementation handoff for latest command results and live smoke evidence.

Validated 2026-10-07: 15 targeted tests passed (6 core + 9 HTTP); targeted compile
with `--warnings-as-errors` and format check passed. Live `npx -y
@modelcontextprotocol/server-filesystem /app` initialized as 2025-11-25, discovered
its tools (12,983-byte JSON, explicit 1 KB cap spilled), and `read_text_file` returned
the first README heading. Disconnected/removed smoke entry afterwards. Node/npm
were installed in this disposable container, not added to the Docker image.

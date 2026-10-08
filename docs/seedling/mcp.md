# MCP: tools, resources, prompts and mailbox events

`Seedling.MCP` is a library callable from eval, not a harness tool. Configure a
server, connect a **stable agent name**, discover what it provides, and subscribe
so that changes wake the agent. No model/provider calls are needed to operate it.

## Quick start

The application should supervise `{Seedling.MCP.Supervisor, []}`. This is the only
startup integration needed; MCP does not replace or reload harness modules.
For a manually started application child, use
`Supervisor.start_child(Nano.Supervisor, {Seedling.MCP.Supervisor, []})` once.
A manually installed child alone does **not** survive a node boot; add it to the
application's child list for that. MCP does not start global processes on import.

Edit `/app/priv/seedling/mcp.json` (checked-in server definitions; default empty):

```json
{
  "servers": {
    "files": {
      "transport": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp/work"],
      "cwd": "/tmp/work"
    },
    "remote": {
      "transport": "http",
      "url": "http://127.0.0.1:8000/mcp",
      "headers": {"authorization": {"env": "MCP_TOKEN"}}
    }
  }
}
```

The npx example requires Node/npx installed separately; the test suite does not.
`streamable_http` is an alias for `http`. `env` (stdio) and `headers` (HTTP) map
strings to literal strings or `{"env":"ENVIRONMENT_VARIABLE"}` references. Do not
commit tokens. Missing environment variables produce a visible connection failure.
Commands use an executable and argument vector, **not a shell**. Config is read at
connect and boot. To apply edits to a live connection, disconnect all its agents
and reconnect. Unknown names and missing executables are actionable errors.

```elixir
alias Seedling.MCP
MCP.servers()
{:ok, info} = MCP.connect("files", agent: "researcher")
{:ok, page} = MCP.tools("files")             # one server page, never all pages
MCP.tools("files", cursor: page["nextCursor"]) # when a cursor exists
MCP.resources("files")
MCP.resource_templates("files")
MCP.prompts("files")
MCP.call("files", "read_file", %{"path" => "/tmp/work/example.txt"})
MCP.read("files", "file:///tmp/work/example.txt")
MCP.get_prompt("files", "greeting", %{"name" => "reader"})
MCP.subscribe("files", "file:///tmp/work/example.txt", agent: "researcher")
# idle: resource changes arrive in the agent's ordinary mailbox
MCP.unsubscribe("files", "file:///tmp/work/example.txt", agent: "researcher")
MCP.status("files")
MCP.disconnect("files", agent: "researcher")
```

`connect/2` returns `{:ok, info}` after discovery/initialization. On a failed
attempt it returns `{:error, reason}` but the saved connection intent remains and
reconnection continues; `status/2` reports state. Calls while disconnected return
`{:error, {:not_ready, status}}`. Calls default to a 15-second timeout; pass
`timeout: milliseconds` to request functions. Unknown servers, anonymous pids,
JSON-RPC errors and transport failures are returned, not silently swallowed.

For delegated multi-server setup, prevent lifecycle events waking the child before
all servers are ready:

```elixir
MCP.connect("first", agent: "child", defer_events: true)
MCP.connect("second", agent: "child", defer_events: true)
MCP.release_events("child") # => :ok; release after ALL connects succeed
```

The hold applies per stable agent to all lifecycle/action/notification events,
including the periodic offline-queue flush; RPC readiness is not held. Release
drains the bounded queue and restores normal delivery. Last disconnect clears
hold/queued events. A setup owner must release or disconnect on failure; holds
are transient and are **not** persisted across manager/node restarts.

`request(server, method, params, opts)` is the composable escape hatch. Public
results are `{:ok, value}` / `{:error, reason}`; JSON-RPC error maps retain code,
message and data. Application-level `isError` or modern `resultType` fields remain
in the server's result; callers must inspect them. Neither transport errors nor
tool application errors cause automatic replay of calls.

## Bounds and paging

Normal results remain unchanged up to 8 KiB of pretty JSON (override `max_bytes:`,
clamped to 256..32768). Large results are saved as JSON and return:

```elixir
{:ok, %{truncated: true, path: path, bytes: total, preview: preview}}
{:ok, page} = MCP.result_page(path, offset: 0, limit: 4096)
MCP.result_page(path, offset: page.next_offset, limit: 4096)
```

Offsets are UTF-8 byte offsets; use the returned offset, not guessed offsets.
Pages are bounded to 16 KiB, preserve codepoint boundaries, and end with
`next_offset: nil`. Tool content, structured content, resource blobs and prompt
messages are kept in the spill verbatim; binary content is protocol base64, not
auto-decoded or printed. Files live under the node's configured `spill_dir/mcp`;
pass `spill_dir:` to isolate callers/tests. Operators own retention/deletion.

Lists respect the server's `nextCursor`: one request = one page. Oversized pages
spill rather than dropping entries or inventing cursors. There is a separate
8 MiB **wire-frame** ceiling: over-limit input disconnects visibly rather than
allocating unbounded data. There are at most 128 in-flight RPC requests per
connection; further calls receive `:too_many_requests`.

## Events and timeline

MCP delivers maps to the pid currently registered under
`Nano.Names.whereis_name({:agent, stable_name})`. It never saves an agent pid:

```elixir
%{mcp: "files", type: :notification,
  method: "notifications/resources/updated",
  params: %{"uri" => "file:///tmp/work/example.txt"}, at: "..."}
```

Other types include `:connecting`, `:connected`, `:disconnected`, `:request`,
`:response`, `:subscriptions`, `:subscription_closed`, `:protocol_warning`,
`:protocol_error` and `:transport_error`. Resource updates are routed only to
agents with that URI intent. List changes, logs, progress and connection/action
summaries go to all agents attached to that server. The harness records these
ordinary events in its existing history/timeline; no dashboard or harness code
changes are needed. Action summaries contain method and target, not credentials
or full arguments; response summaries contain outcome and byte count. An agent's
eval result remains the place to see actual tool output. Large notification
payloads spill, retaining type/method in the event.

If an agent is briefly absent, the manager buffers the latest 100 events per
stable name and retries delivery every 250 ms. This bounded queue is in memory:
older events may be dropped and queued events do **not** survive a node restart.
Live-agent mailbox sizes and timeline retention remain the harness's concern.
The API is a trusted node-wide library, not a per-agent authorization boundary.

## Durable intent and supervision

Connections and URI subscriptions are atomically written (synchronous file write
then rename) to `state_dir/mcp/intent.json` **before** success is returned.
`subscribe/3` returns `{:ok, %{durable: true, status: :pending, uri: uri}}`: this is
an acknowledgment of **local durable intent**, not proof the server accepted it.
A subsequent `:subscriptions` event reports the server's acknowledgment or
failure. For modern servers, inspect the acknowledged `notifications` filter:
the server may accept only a subset. Durable intent is retained if unsupported.

On boot, the manager reloads intent, connects configured servers, and restores
subscriptions without agents needing to call connect or subscribe again. A new
pid under the same agent name receives events. A malformed saved intent file is
not silently overwritten. Removing configuration does not erase intent.
`disconnect` deletes that agent's connection and all its subscription intent;
the last disconnect closes the server. `unsubscribe` removes just one agent's URI;
the server stays subscribed while another agent still needs it.

The one-for-all MCP supervisor contains a dynamic connection supervisor and the
manager. Connections retry OS death and initialization failure with exponential
backoff (100 ms to 30 s), fail outstanding calls promptly, and announce failures.
Client-process kills are supervised; linked HTTP workers and owned stdio ports
are cleaned up with the client. Reconnected clients rehydrate **current** intent,
not stale original start arguments. Side-effecting calls are never replayed.

For isolated instances:

```elixir
Seedling.MCP.Supervisor.start_link(instance: "test-unique", config_path: path,
  state_dir: unique_directory, resolver: fn stable_name -> lookup(stable_name) end)
MCP.connect("server", instance: "test-unique", agent: "stable-name")
```

All APIs accept `instance:`; production defaults to `:default`. Supervisor opts
`config_path:` and `state_dir:` belong to startup, not to `connect`.

## Protocol revision and transport coverage

Read from the official internet specification **2026-10-08**:

- https://modelcontextprotocol.io/specification/latest.md explicitly identifies
  authoritative schema revision **2026-07-28**.
- https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning
- https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio
- https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http
- https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions

This is a major change from the older initialization/session protocol. This
client supports both eras:

**Current 2026-07-28:** `server/discover` probe, required per-request `_meta`
protocol version/client identity/empty client capabilities, HTTP mirrored
protocol/method/name headers with Base64 sentinel encoding, and long-lived
`subscriptions/listen`. Notifications are correlated by subscription ID and
must follow acknowledgment. New subscriptions replace the previous stream.
HTTP receives both JSON replies and request-scoped SSE; no modern HTTP GET or
Last-Event-ID is used. Disconnected listen streams are reopened.

Modern HTTP `tools/list` caches input schemas, excludes invalid `x-mcp-header`
annotations with a warning, and mirrors discovered static primitive parameter
headers on calls (nested properties, safe integers, null omission, safe encoding).
**Discover the relevant tool page before calling an annotated HTTP tool.**
There is no automatic schema-pagination sweep or HeaderMismatch retry; a direct
call to an undiscovered annotated tool can fail for missing parameter headers.

**Legacy:** any non-modern discovery error or probe timeout falls back to
`initialize` with 2025-11-25, accepting negotiated 2025-11-25, 2025-06-18,
2025-03-26 or 2024-11-05. The initialized notification is sent before normal
calls. For HTTP it waits for the notification's 202 before returning readiness.
Session IDs are carried on subsequent requests; a session 404 triggers fresh
initialization. Resource subscription/unsubscription RPCs are restored, and an
optional GET/SSE channel forwards unsolicited notifications. GET 405 means no
unsolicited channel; calls still work. GET reconnects carry Last-Event-ID and
respect server SSE retry (bounded at 60 s). Deprecated separate HTTP+SSE
endpoints are **not** supported. Stdio uses newline JSON, leaving stderr
separate (inherited, not turned into JSON-RPC).

Config knobs: `protocol: "legacy"` bypasses probing for known legacy servers;
`probe_timeout_ms` defaults to 1500, `connect_timeout_ms` to 5000, and
`http_idle_timeout_ms` to 120000. HTTP disables redirects and automatic request
retry, so credentials are not forwarded to redirect destinations.

### Deliberate limitations

- This implements the core server-use/event subset, **not** every feature in the
  current specification. No OAuth discovery/browser authorization, client roots,
  sampling, elicitation UI, Tasks/MCP Apps extensions, caching policy, or automatic
  MRTR continuation. No such client capabilities are advertised; results asking
  for input are returned for the caller to handle. Legacy server-initiated client
  requests receive method-not-found, not a hanging promise.
- Only current 2026-07-28 is supported in the modern era; a recognized unsupported
  version error is surfaced, not downgraded into legacy semantics. Accepted older
  legacy revisions other than 2025-11-25 are not integration-tested.
- Stateless modern streams have no replay cursor; reconnect restores intent, not
  historical events. Legacy GET cursors are in memory; request-scoped legacy POST
  SSE resumability is not implemented. Retried tool calls would risk duplicate
  side effects, so interrupted calls fail without replay.
- Saved definitions are trusted executable/network configuration. Local stdio
  processes inherit the OS environment and have the node's privileges. HTTP uses
  explicit configured authentication only. Do not connect untrusted services or
  treat this client as a sandbox. No live third-party/reference npm server was run.
- The disk intent test proves two distinct BEAM lifetimes, not a Docker container
  crash or a disk/power-loss test. Persistence assumes the configured data volume
  survives boot. Application startup integration is performed by the parent, not
  by these owned MCP files.

## Actual validation

Run from the checkout with isolated test settings:

```sh
MIX_ENV=test MIX_BUILD_ROOT=/tmp/orion-mcp/.seedling-build mix test test/seedling/mcp*exs
```

The foundation's mix.exs clears MIX_BUILD_ROOT in test, so actual builds land in
this worktree's private `_build/test`, not `/app`'s build.

**16 tests passed** on 2026-10-08. The fixture is a real local Python OS process:
stdio and loopback HTTP servers (port **0**), unique temp directories per test.
It asserts current metadata/HTTP headers and legacy initialization/session order;
SSE data lines and chunk boundaries are split. Tests cover all four transport/era
combinations, tools/resources/templates/prompts, calls/error replies, progress/log
forwarding, binary/base64 resources, large spill pages, subscribe/unsubscribe,
stable-name agent replacement, complete MCP supervisor restart, client-process
kill, OS-process death/reconnect/no replay, timeouts, and multi-agent URI routing. Additional tests check
HTTP annotated headers, invalid schema rejection, encoded Unicode headers, UTF-8
paging, and a **second independent BEAM VM** restoring saved subscriptions with
no connect/subscribe calls. Tests spend no model calls and require only Python 3.

The complete foundation checkout suite also passed: **285 tests**, with two
pre-existing unused-variable/default-argument warnings and an expected
`:retry_start` agent log in a restart test. No MCP compilation warnings.

Follow-up regressions check multi-server deferred-event release, oversized
resource routing plus spill-failure safety, and HTTP worker cleanup on a killed
client. HTTP fixture teardown explicitly sends identity-checked OS TERM and
waits for exit: Port.close alone does not terminate a Python HTTP listen loop.
The initial suites passed assertions but left 27 orphan HTTP fixtures, which
were identity/PPID-checked and terminated; subsequent teardown assertions pass.

An initial legacy HTTP readiness test failed because readiness preceded the
initialized notification completion; fixed and retested. A subsequent strict
boolean (`not` applied to a port) bug while adding schema caching was fixed and
retested. These were real failures, not skipped tests.

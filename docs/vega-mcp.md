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
list function to continue. `request/4` exposes other JSON-RPC methods. In legacy mode unknown
client requests get a JSON-RPC MethodNotFound response, except `ping` is answered. Modern server-initiated requests are forbidden by the
protocol and cause a reported disconnect, not a client response.
No sampling, elicitation, roots, or tasks capabilities are advertised.

## Protocol source and revision (network read 2026-10-07)

Fetched authoritative pages using HTTPS:

- https://modelcontextprotocol.io/specification/latest.md
- https://modelcontextprotocol.io/specification/2026-07-28/basic/lifecycle.md
- https://modelcontextprotocol.io/specification/2026-07-28/basic/transports.md
- https://modelcontextprotocol.io/specification/2025-11-25/basic/transports.md
- https://modelcontextprotocol.io/specification/2026-07-28/server/discover.md
- https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions.md
- https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http.md
- https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio.md
- https://modelcontextprotocol.io/specification/2026-07-28/basic/index.md

**Current revision support:** **2026-07-28** is implemented as an explicit modern
mode alongside legacy **2025-11-25**, **2025-06-18**, and **2025-03-26**. The default
remains legacy for existing ecosystem/reference compatibility. Set a server definition's
`"protocol": "2026-07-28"` to select the current protocol:

```elixir
Vega.MCP.connect("current", %{"url" => "https://example.test/mcp",
  "protocol" => "2026-07-28"})
# stdio uses exactly the same protocol option.
```

Modern mode probes `server/discover` (not `initialize`), supplies required version /
capabilities metadata plus client identity on **every** request, and uses mandatory
`Mcp-Method` / `Mcp-Name` HTTP headers with ASCII/base64 sentinel encoding. Modern
connections never issue `notifications/initialized`, GET streams, session IDs, or
`Last-Event-ID`. `connect` returns the discovered capabilities/identity with a normalized
`protocolVersion` field for callers. Unsupported modern versions return an explicit error;
there is no automatic era guessing/fallback. To change a live named connection's
configuration/protocol, disconnect it before connecting again. Choose a legacy protocol option for a
legacy-only server. Legacy negotiation can accept any of the three supported legacy
revisions. The old 2024 HTTP+SSE two-endpoint transport is unsupported.

Modern `subscribe` / `watch` use long-lived **`subscriptions/listen`** requests (POST
SSE or stdio) with explicit URI / list-change filters. Their acknowledgment and every
pushed notification are correlated by `io.modelcontextprotocol/subscriptionId`.
Notifications before ACK, stale IDs, and events outside the acknowledged filter are
ignored. ACK subset omissions produce `subscription/failed`; a rejected URI returns
`:subscription_not_acknowledged`, while its durable interest remains visible and can be
removed with `unsubscribe`. Modern subscriptions cancel by closing the HTTP stream or
sending stdio cancellation, and reopen after transport/server/graceful stream closure.
No unadvertised sampling, roots, elicitation, tasks or MRTR capabilities are claimed;
modern input-required workflows / extensions need a future adapter.

Modern HTTP supports tool parameter **`x-mcp-header`** annotations, including nested
properties, safe primitive types and exact paths. Invalid names/types/placement or
case-insensitive duplicate headers exclude the invalid tool from `tools/list`, log a
warning and emit `tool/rejected` to watchers. Tool calls automatically discover schemas
(including at most 32 pages) when needed before issuing a side-effecting call. Discovery
and the eventual tool share the original request deadline; timed-out discovery never
launches a delayed tool. List-change events invalidate the header-schema cache. Header
mismatch errors are returned for explicit caller review/retry, never silently replayed.

## Transports and configuration


stdio definitions have `command`, optional string-list `args`, optional string-map
`env`, optional `cwd`, and optional integer `result_limit` and `protocol`. Arguments go directly to
`Port.open` without a shell; stderr is not mixed into protocol stdout. As normal
subprocesses, servers inherit the VM environment plus configured overrides. Run only
trusted server executables and avoid giving untrusted servers sensitive environment.
The example uses `npx`, which requires Node/npm installed; dependencies are not
installed implicitly by Vega.MCP. Pin package versions for production.

Streamable HTTP definitions have `url` (`http` or `https`), optional `headers` map,
`result_limit`, and `protocol`. Example (no keys in git):

```elixir
Vega.MCP.connect("remote", %{"url" => "https://example.test/mcp",
  "headers" => %{"authorization" => "Bearer " <> System.fetch_env!("MCP_TOKEN")}})
```

**Legacy HTTP** supports one POST per message, JSON and incrementally parsed SSE responses, a
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
`connect` waits for initialization or modern discovery and returns an error promptly on failed launch;
the worker continues retrying until `disconnect`. A call in downtime returns
`:not_ready`; it is not invisibly queued or replayed. Up to 128 generic RPC requests
are pending; further requests return `:busy`. Concurrent legacy mutations for the same
resource (or any modern mutation while its listen ACK is pending) return `:subscription_busy`, so retry after the earlier operation finishes.

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
  mix test test/vega_mcp_test.exs test/vega_mcp_modern_test.exs test/vega_mcp_reference_test.exs test/vega_mcp_redaction_test.exs
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

- MCP focused suite with reference enabled after modern followup: **31 passed**
  (16 legacy hermetic + 9 current hermetic + 5 credential hardening +
  1 official legacy-compatible server).
- Official `@modelcontextprotocol/server-filesystem` version **2026.8.31**, run by
  Node **v20.19.2**; legacy negotiation/discovery/write/read/path-denial all passed.
- Final full repository suite with the reference enabled: **278 passed**, no skips
  (28.2 seconds), including current-protocol stream closure and simulated
  credential-bearing crash reports. Without the opt-in reference environment, that one test is
  explicitly skipped.
- Node runtime was installed as an allowed system package; npm dependencies were
  installed only under `/tmp/vega-mcp-tools`. No harness modules were loaded into
  the live VM, no live application settings were changed, and no credentials were
  needed. Production use of the `npx` sample still requires npm/npx on PATH.

## Eval-safe deadlines and background completion

Default generic/tool RPC deadline is **20 seconds** (21-second call envelope), and
connect/subscribe/watch envelopes are at most **25 seconds**, below the harness's
usual 30-second eval limit. Discovery/ACK deadlines are 15 seconds. Explicit request
`timeout:` accepts 1..300000ms. Longer work should use the supervised background API,
which returns immediately and reports to a **name**, so agent/eval exit does not kill it:

```elixir
{:ok, ref} = Vega.MCP.call_tool_async("server", "slow_tool", %{}, "agent-name",
  timeout: 120_000)
# Or Vega.MCP.request_async(server, method, params, agent_name, opts)
# Later event:
%{mcp: "server", method: "request/completed", request_method: "tools/call",
  ref: ref, result: {:ok, bounded_result}}
```

The MCP supervisor and children use the stable `:user` group leader, not a transient
eval IO process. Background requests are under their own Task.Supervisor and reset
their group leader as well. A completion still can be lost if no agent process owns
the target name at that precise delivery time; no offline queue is claimed.

## Credential-report hardening

Connection child start/restart arguments contain **only the public server name**.
Definitions (including HTTP auth headers, stdio env and argv) are held in a private
in-memory `Vega.MCP.Config` GenServer, not DynamicSupervisor child specifications or
subscription files. Connection restart retrieves the definition by name. A whole
MCP subtree restart loses this private cache and requires explicit `connect`; if only
the config process restarts, existing connections retain their definitions until
reconnected, and an explicit `connect` rehydrates the cache for future worker restarts.

`format_status/1` on Connection/Config/State returns small nonsecret summaries and
redacts last messages, debug logs and reasons. Abnormal `terminate` additionally
replaces the actual exit reason with `{:mcp_service_failure, kind}` and drains pending
mailbox payloads: formatting the GenServer report alone would not protect subsequent
Supervisor/proc_lib reports or original exception stacktrace arguments. Detailed
crash state/exception values are intentionally sacrificed for report safety. Transport
and spawn failures return error **classes**, never interpolated exception text with
headers/env/argv. Incidental RPC errors, connection/subscription failure events and protocol log/progress
notifications scrub configured header/env/argv string values and Bearer/key-value components before
bounding/spilling; normal successful tool/resource data is deliberately unchanged.

Tests use only random **fake** credentials in a separate test VM. They inspect raw
supervisor restart specifications, formatted status, and actual GenServer/Supervisor/
proc_lib reports, with SASL reporting enabled and restored only in that test VM. They
also prove worker restart still fetches the private definition, subscription JSON has
no auth value, and a server's echoed fake credential is scrubbed from both an RPC error and a pushed
log-message event before it reaches an agent/provider context.

This is protection against **incidental reports**, not a sandbox or a root-agent
access control boundary: trusted root agents can explicitly fetch configs or call
`:sys.get_state`; raw `:sys.trace`/custom tracing, deliberate printing of secret values,
server-controlled successful results, and a server's own stderr are outside this
report-redaction guarantee. Run only trusted stdio executables (they inherit the VM
environment). The library does not invent a secret-on-disk auth store.

**Upgrade:** stop the existing MCP subtree *before* loading these hardened modules,
then restart it and connect the configured names. Old DynamicSupervisor specifications
contain raw configs and cannot be made safe simply by hot-loading a new worker callback.

## MCP media and explicit native vision

Known tool `{type: "image" | "audio", data: "<bare base64>", mimeType: ...}`
parts and resource `{uri: ..., blob: "<base64>"}` contents are normalized **before**
JSON preview/spill and event delivery. The original `data`/`blob` field is removed
and replaced by `media: %{type: "mcp_media_ref", id: ..., kind: ..., mimeType: ...,
bytes: ..., verification: "deferred", visible: false}`. Text, citations, annotations,
resource URIs and outgoing MCP request/wire framing remain unchanged. This is a
normalized library return shape, not a claim the model saw pixels. Successful RPCs,
notifications and background completions cannot incidentally print those bare base64
fields into the provider context or timeline. Ordinary text is not guessed to be
base64 or rewritten.

```elixir
{:ok, result} = Vega.MCP.call_tool("vega-filesystem", "read_media_file",
  %{"path" => "/app/example.png"})
ref = hd(result["content"])["media"]
Vega.MCP.media_info(ref) # metadata only, no payload or arbitrary path
Vega.MCP.media_page(limit: 20, offset: 0) # metadata-only cache listing
Vega.MCP.view_image(ref) # explicit intent, not automatic context/vision cost
```

The media cache is under `<vega_mcp_state_dir>/media`: directory **0700**, decoded
payload and metadata files **0600**. IDs are opaque content-addressed hashes bound
to bytes + canonical MIME/kind, not caller-supplied paths. Default hard limits:
**3,750,000 decoded bytes per file**, **5,000,000 encoded bytes per part**,
**20 media parts per result/event**, **64,000,000 cache payload bytes** and
**128 cache entries**. Admissions are serialized, deduplicated and quota checked;
cache exhaustion returns `mcp_media_error` metadata, never the original payload.
Invalid/empty/oversized base64 likewise becomes small explicit error metadata, with
`visible: false`. Audio and other binary blobs use opaque binary descriptors; no
image-view claim is made. Cache sidecars do not contain base64/payload. Directory
reload charges orphan payloads against quota even if their sidecar is unavailable.
There is no automatic eviction while older result refs may be in use; delete a
specific cached ref with `Vega.MCP.Media.delete(ref)` or manage this private directory
as an operator. Deletion makes old MCP refs explicitly unavailable; it does not delete
an already imported immutable `Vega.Images` attachment.

Pixel decoding is **deferred** until `view_image`, so a connection worker does not
run native image codecs. On explicit view, the helper verifies the private payload
identity, calls optional **`Vega.Images.import_file(path)`**, checks canonical MIME
and raw hash, then **`Vega.Images.view(image_ref)`** to queue the verified native
attachment. It reuses the strict image seeding; there is no MCP decoder implementation
or header-only validation bypass. A malformed PNG can be cached as unverified bytes
but cannot become visible without that strict decoder. Missing Images support returns
`:images_unavailable`; a missing decoder, invalid pixels, corrupt payload, MIME/hash
mismatch, or missing cache returns an explicit error, never a fictional successful
view. Media Cache `format_status` and abnormal termination use the same raw-message/
reason/log redaction as credential-bearing services.

Verification (2026-10-07): standalone MCP full suite **284 passed, 1 skipped**
(28.6s), including official filesystem `read_media_file` returning a genuine 2x2 PNG
as a small opaque ref without any bare base64. Six media tests cover result/event/
async/spill normalization, text/citation retention, private permissions, both quotas,
disk restart, malformed/oversized inputs and cheap metadata pages. The one explicit
skip is native Images integration because the standalone MCP branch does not include
that sibling module; it runs automatically on the integrated tree and checks strict
native view plus malformed-pixel refusal. Reference integration also calls native
view when Images is present. Images references are queued only by explicit view intent.

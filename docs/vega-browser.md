# Vega.Browser: interactive Lightpanda

```elixir
{:ok, b} = Vega.Browser.start(node: "/tmp/vega-browser-tools/node", agent: "vega")
{:ok, _} = Vega.Browser.navigate(b, "https://example.com")
{:ok, snapshot} = Vega.Browser.dom(b) # default 8,000 Unicode characters
Vega.Browser.dom(b, mode: :html, offset: snapshot["next"] || 0)
Vega.Browser.fill(b, "input[name=q]", "hello")
Vega.Browser.click(b, "button[type=submit]")
Vega.Browser.evaluate(b, "document.title")
Vega.Browser.screenshot(b) # {:ok, %{image: Images_ref, rendering: :lightpanda_text_layout}}
# or explicit unsupported error; NOT a CSS/raster screenshot
Vega.Browser.stop(b)
```

Requires a native **Node >=22** (built-in WebSocket, no npm packages) and
`/usr/local/bin/lightpanda`. Node lookup: `node:` option, `VEGA_BROWSER_NODE`,
then PATH. The development native ARM64 runtime is `/tmp/vega-browser-tools/node`;
it is not shipped in git. Lightpanda can be overridden with `lightpanda:`.
The packaged script is `priv/vega_browser.mjs`, override with `script:` only for
trusted deployment/tests. Existing Vega.Web remains HTTP/Markdown oriented.

All public operations return `{:ok, result}` / `{:error, reason}`. CDP and JS
errors are string-key maps (`kind`, `message`, `method` as applicable). Missing
selectors are JS errors, never silent success. `click` uses DOM `.click()`;
`fill` sets `.value` and emits bubbling input/change, not trusted mouse/keyboard
input. Rich React-controlled inputs, hover, layout, viewport, keyboard, file
upload, cross-origin frames, downloads, CAPTCHA and navigation auto-wait after
click are not implemented. Call evaluate/poll for your explicit condition.
`navigate` polls `document.readyState` complete, not network idle or asynchronous
app readiness. DOM text uses textContent (not visual innerText/readability);
scripts/styles may occur. Paging re-snapshots DOM: changes between reads can
shift offsets. Evaluate returns JSON-by-value, undefined maps to nil; cyclic
objects / functions / JS exceptions are not serializable successes.

## Lifecycle, bounds, safety

Each session creates its own Lightpanda browser process, persistent CDP target,
and loopback token-authenticated control bridge. Control listener uses port 0;
CDP reserves an ephemeral loopback port then releases it before launching
Lightpanda (a small bind race yields startup failure, never fixed port 9222).
CDP itself is unauthenticated on loopback: this is a trusted-machine capability,
not a public proxy or sandbox. HTTP(S) URLs without userinfo only; private and
loopback destinations deliberately allowed. Page scripts execute in Lightpanda;
external page contents are data, not instructions. Arbitrary evaluate expressions
come from the caller. Do not expose this API to unauthenticated users.

`Vega.Tasks` owns the Node bridge and Lightpanda process group, with guardian
cleanup after controller death. Default lifetime **600,000 ms**, customizable
`lifetime:` (including :infinity at caller risk). Handles survive agent/eval
restarts, not backend/BEAM/container restarts. Save `b.dir` and `resume(dir)` to
recover; resume only reconstructs a handle, operations check task liveness.
On crash/deadline start a new session; no automatic session replay. `agent:`
requests restart-safe named **Vega.Tasks** completion events `{:vega_task, record}`,
not a new Browser event. Without name `notify:` defaults caller pid. Use
`status(b)` / `Vega.Tasks.read(b.task)` for bounded diagnostics. This delegates
supervision/cleanup to Tasks rather than adding global application children.

Default session metadata `/tmp/vega-browser-sessions/<random>` is mode 0700,
config/token file mode 0600. `root:` can change it. Task logs and metadata remain
after stop for recovery/debugging; caller removes old directories. Handles
include a secret token; do not print or publish them. No cookies/session persistence
across new browser processes. All startup shell arguments are POSIX quoted.
Files.write is used for config/record creation, Tasks for shell lifecycle, Images
for screenshot validation/import; no duplicate shell or image infrastructure.

One command at a time; concurrent operations return `kind: busy`, not queue
unbounded work. Request cap 100,000 bytes, CDP incoming/result cap 6 MB;
ordinary result cap **50,000 bytes** with explicit result_too_large error.
DOM limit 1..16,000 chars (default 8,000), zero-based offset. CDP command deadline
10 seconds; Req receive/connect deadline default 15 seconds, allowed 1..25,000 ms.
Navigation ready-state polling can take longer than a caller's deadline; a client
timeout is not rollback/cancellation. Use stop if browser state must be discarded.
Bridge startup deadline 12.5 seconds; startup failure carries a task directory.
Images enforces its existing size/dimension caps on actual PNGs. A screenshot
error must not be interpreted as an image. The installed Lightpanda 1.0.0
DOES produce PNGs, but its embedded usage documentation explains that screenshots
render **text layout**, not the page's CSS/visual pixels. This library labels
results `rendering: :lightpanda_text_layout` and nests the Images ref at `image:`
to avoid claiming Chromium-style rasterization. No placeholder is generated by
this library. Fetch the returned image ref with Vega.Images.fetch/1.

## Verification

Run with native Node and Lightpanda installed:

```
VEGA_BROWSER_NODE=/tmp/vega-browser-tools/node MIX_ENV=test \
 MIX_BUILD_ROOT=/tmp/vega-browser/_build mix test test/vega_browser_test.exs test/vega_browser_start_test.exs
```

Tests use a real port-zero localhost HTML/JS fixture and unique temporary roots.
They exercise JS-derived DOM, actual form submit via click, value/event dispatch,
HTML and Unicode pagination, missing selectors, screenshot protocol probe,
handle recovery, task completion/cleanup, and prerequisite/option errors.
Screenshot branch validates PNG bytes through Images or prints actual unsupported
protocol error. A runtime absent means the real test is not exercised (test emits
an explicit note), not evidence of browser success.

Actually performed on installed Lightpanda **1.0.0** / native Node **v22.21.1**:
three focused tests passed (latest seed 981940, including PNG chunk CRC and
zlib decompression validation). Real JS fixture submitted the form,
changed DOM, and produced a **1920x1080, 12,540-byte text-layout PNG**, validated
and imported through Images. Before/after image hashes differed (not a static
placeholder). Initiating process exited before operations; handle recovery and
process-group cleanup succeeded. Request/result oversize checks and failed
bridge startup diagnostics passed. Outbound https://example.com navigation
succeeded with title Example Domain and 1920x1080 PNG of 59,520 bytes. PNG
metadata/byte validity is verified; no claim of CSS/raster accuracy or human
visual inspection. Unsupported-backend screenshot branch is implemented but
not exercised by this supporting binary. No live modules were loaded.

Full isolated checkout suite: **321 passed**, 25.0 seconds (seed 156198),
exit 0. Existing seed-suite unused-variable/default warnings and intentional
retry_start termination are not failures. Subsequent focused run includes
stronger PNG chunk/decompression checks above.

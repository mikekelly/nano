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
`/usr/local/bin/lightpanda`. Node lookup precedence (read-only): explicit `node:`
option; exact string node setting `Nano.Settings.get("VEGA_BROWSER_NODE")`;
environment `VEGA_BROWSER_NODE`; `/data/vega-browser-tools/node22` if a regular
file; then PATH `node22` (image native pinned Node22); finally PATH `node`. Empty/whitespace setting/environment values mean unset. Explicit
options (even nil/invalid) take precedence and fail rather than silently falling
through. A nonblank but invalid configured path also fails honestly.
`node_runtime/1` reports the selected path without installing/changing anything.
The parent installed a durable native ARM64 v22.21.1 copy at the stable /data path;
`start()` works on this node without options or environment mutation, despite
system /usr/bin/node being20. The development /tmp copy is not needed in production.
Neither executable is shipped in git. Lightpanda overrides: `binary:` or legacy
`lightpanda:`. Chromium is optional as documented below.
The packaged script is `priv/vega_browser.mjs`, override with `script:` only for
trusted deployment/tests. Existing Vega.Web remains HTTP/Markdown oriented.

All public operations return `{:ok, result}` / `{:error, reason}`. CDP and JS
errors are string-key maps (`kind`, `message`, `method` as applicable). Missing
selectors are JS errors, never silent success. `click` uses DOM `.click()`;
`fill` sets `.value` and emits bubbling input/change, not trusted mouse/keyboard
input. Rich React-controlled input handling, hover convenience, file upload, cross-origin
frame helpers, downloads, CAPTCHA and navigation auto-wait after click are not
implemented. Chromium viewport, trusted keyboard and CSS-pixel screenshots are
implemented as described below; Lightpanda is not a CSS layout renderer. Call evaluate/poll for your explicit condition.
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

## Optional Chromium CSS/keyboard backend

```elixir
{:ok, b} = Vega.Browser.start(backend: :chromium, binary: "/usr/bin/chromium",
  node: "/tmp/vega-browser-tools/node", agent: "vega")
Vega.Browser.navigate(b, "http://127.0.0.1:4000/bots")
Vega.Browser.viewport(b, 1280, 800)
Vega.Browser.viewport(b, 390, 844, mobile: true)
Vega.Browser.evaluate(b, "document.querySelector('textarea').focus(); true")
Vega.Browser.press(b, "Tab")
Vega.Browser.press(b, "Enter")
Vega.Browser.screenshot(b) # {:ok, %{image: Images_ref, rendering: :css_pixels}}
Vega.Browser.command(b, "Browser.grantPermissions",
  %{origin: "http://127.0.0.1:4000", permissions: ["notifications"]}, browser_scope: true)
Vega.Browser.stop(b)
```

Default backend remains **:lightpanda**, with truthful :lightpanda_text_layout
label. Chromium uses the identical task-guarded bridge/API, unique loopback CDP
port, a fresh task-local profile, --headless=new, and **--no-sandbox** (required
for this root container). It is not a security sandbox, and page scripts execute
as root: use only in the trusted agent environment. Chromium profile persists
under session directory for diagnosis, not shared with another session.

`command/4` exposes bounded generic CDP to avoid inventing separate wrappers for
every protocol operation. Default attaches target session; `browser_scope: true`
uses the browser endpoint for Browser.* methods. Unsupported CDP commands return
honest backend errors. This is powerful: command calls can alter this session's
state and permissions, not the node's shared settings. External CDP attach is not
implemented (we deliberately own and clean only our task's browser).

`viewport/4` sets CSS dimensions 1..2000, scale 1, optional `mobile: true`.
`press/3` generates CDP keyDown/keyUp with printable text, Enter/Tab/Escape,
Backspace/Delete/arrow keys; optional `modifiers:` follows CDP bitmask
(Alt=1,Ctrl=2,Meta=4,Shift=8). Focus first. The fixture validates `isTrusted`
keyboard events and native implicit Enter form submission. Click/fill retain
DOM semantics above; for trusted coordinate clicks use command Input.dispatchMouseEvent
with evaluated bounding boxes. No automatic mouse or app-readiness assumptions.

Notifications: Browser.grantPermissions grants **this isolated origin/session**
permission; this tests the actual Notification constructor/permission state.
Headless environments may not deliver OS notifications or show events. Do not
claim desktop popup, click delivery, service worker push, or reboot persistence
from granted permission alone. GUI QA can intercept window.Notification while
preserving the real constructor to inspect options without claiming OS delivery.

### Chromium verification actually performed

Installed Debian ARM64 Chromium **154.0.8037.92** (apt); native Node v22.21.1.
Four focused tests passed (seed 366004, 0.9 sec): original Lightpanda tests plus
real Chromium fixture. CSS media breakpoint changed green desktop1000x700 to
red mobile390x700, real CSS PNG hashes/dimensions differed; trusted key A + Enter
submitted the native form. Browser.grantPermissions yielded granted; actual
Notification constructor succeeded and `onshow` fired **true** after500ms.
This does not establish a visible OS desktop popup or clicked notification.

Opt-in `priv/vega_browser_qa.exs` also drove the **live** consumer `/bots` via
Chromium on this container. It is a standalone `mix run --no-start` script,
not a test that silently targets a production server. Defaults localhost4000,
override `VEGA_BROWSER_QA_URL`. It sends no chat, creates no bot/session, does
not alter notification settings checkboxes; only opens views/forms and grants
permissions inside its disposable browser profile.

Actual live QA: desktop1280x800 three chat rows/six message nodes, no horizontal
overflow or operator timeline nodes; real Ctrl+1 twice selected Muse+Dot chips.
Mobile390x844 CSS scrollWidth390 and hidden sidebar while inchat; Escape closed
the popover, ArrowDown+Enter opened an **unsaved** create-bot form, Back returned
to chat list. Real notification permission button UI displayed enabled/granted;
window errors array empty. Six PNGs preserved for visual review under unique
`/tmp/vega-browser-tools/qa/...` dirs; actual sample
`/tmp/vega-browser-tools/qa/Xb0LtGotxrY/desktop-conversation.png` (96,198 bytes)
and `mobile-two-chips.png` (37,210 bytes). QA evidence is DOM/CSS/events/PNG bytes;
this agent did not claim human visual inspection. Parent can view with Images.
No Nano modules or node settings were loaded/changed by this followup. Apt
installed browser/dependencies; browser/session processes all task-group owned.

Full isolated followup suite: **322 passed**, 26.2 seconds (seed 853860),
exit0. A temporary QA filename warning was removed by moving the opt-in
script from test/ to priv/; existing seed-suite warnings/retry_start are not
failures. Live QA was repeated with strict no-overflow/no-timeline/error-free
assertions, also exit0; latest artifacts `/tmp/vega-browser-tools/qa/UFWmxObuXgc`.

## Pinned runtime installation on a fresh ARM64 image

`start/1` never auto-installs/downloads runtimes, mutates environment, or changes
node settings. Keep system Node20 for other capabilities; install the Browser
runtime separately. For this Debian ARM64 container, an operator can explicitly
run (root needed to write the stable /data path):

```sh
work=$(mktemp -d /tmp/vega-browser-install-XXXXXXXX)
cd "$work"
curl -fSLO https://nodejs.org/dist/v22.21.1/node-v22.21.1-linux-arm64.tar.xz
echo 'e660365729b434af422bcd2e8e14228637ecf24a1de2cd7c916ad48f2a0521e1  node-v22.21.1-linux-arm64.tar.xz' | sha256sum -c -
tar -xJf node-v22.21.1-linux-arm64.tar.xz
install -d -m 0755 /data/vega-browser-tools
install -m 0755 node-v22.21.1-linux-arm64/bin/node /data/vega-browser-tools/node22
/data/vega-browser-tools/node22 --version # v22.21.1
# Optional CSS backend: apt-get update && apt-get install -y chromium
```

Archive digest was compared to Node's official v22.21.1 SHASUMS256.txt on this
node; downloaded bytes matched. For x86_64 use the matching linux-x64 artifact
and its **different** official pinned digest; don't run ARM64 bytes on x64 or
vice versa. The durable copy needs a compatible glibc base image. Installation
is an explicit provisioning step, not a dependency bundled in the source commit.

Default selection followup verification: six focused tests passed, seed786713,
with VEGA_BROWSER_NODE **unset** in the isolated subprocess. Default start used
the stable native /data copy and evaluated 6*7=42. Resolver tests verified
explicit option precedence, exact string node-setting precedence, and blank
setting fallback; settings mutations were confined to that isolated test BEAM,
never the running node. Live node settings/environment were only read, not changed.

Image fallback followup: packaged `/usr/local/bin/node22` is now preferred over
system PATH `node` when /data is fresh/empty. Exact opts/setting/env precedence
is unchanged. The parent added a checksum-pinned Dockerfile provisioning recipe;
that Docker build was **not** run here. Current copied native image-path Node22
reports v22.21.1, while `/usr/bin/node` stays20 for MCP. Deterministic fallback
tests use a missing task-local path (no shared /data files moved) to verify
image-node22 before system-node and stable-file before image.

### Final live UI recheck (2026-10-08)

After the parent loaded SVG glyph/privacy/credential UI fixes, the child reran
Chromium against the live `/bots` without chat/settings mutation. Desktop1280x800
reported3rows/14message nodes (a separate authorized peer demo was active), no
horizontal overflow, no operator timeline. Mobile390x844 reported scrollWidth390
and hidden sidebar inchat. Ctrl+1 still selected Muse/Dot, Escape dismissed
recipient choices, ArrowDown+Enter opened the unsaved create form, Back returned
to list. Notification permission UI granted/enabled, no window errors. Latest
six artifacts: `/tmp/vega-browser-tools/qa/M_uo1oArywo/*.png`.

Also verified **live library composition**, without a module reload:
`Vega.Browser.start(backend: :chromium)` chose the durable default runtime;
`{:ok, shot} = Vega.Browser.screenshot(b)` followed by
`Vega.Images.view(shot.image)` successfully attached desktop and mobile PNGs
by native immutable ref. This agent could actually inspect those final image
attachments: custom face/icons rendered; messages/header/composer and mobile
list/settings were clean consumer UI rather than operator/eval timeline.
Additional direct-composition artifact copies are under
`/tmp/vega-browser-tools/final-live-qa/UFVmt4SAIQL_/`.
Earlier verification above did not imply visual inspection; final attachments do.

The standalone QA and real-browser tests now use `node_runtime()` rather than a
hardcoded development /tmp path, so packaged node22/durable defaults are usable
on a fresh provisioned image. Seven focused tests passed seed882448 with runtime
environment unset; the default-runtime live QA exited0. No live modules/settings
were modified; disposable browser processes were stopped. Notifications checked
permission and local fixture onshow, not OS popup/click/push/reboot delivery.

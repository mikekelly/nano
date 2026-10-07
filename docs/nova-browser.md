# Interactive Lightpanda browser

`Nano.Browser` is a library callable from eval. No dependencies or application
supervisor edits are required. Start a background owner (unlinked), or use
`start_link/1` / `{Nano.Browser, []}` under your supervisor:

```elixir
{:ok, browser} = Nano.Browser.start()
Nano.Browser.navigate(browser, "https://example.com")
Nano.Browser.evaluate(browser, "document.title")
Nano.Browser.fill(browser, "input[name=q]", "Elixir")
Nano.Browser.click(browser, "button[type=submit]")
{:ok, page} = Nano.Browser.snapshot(browser)
Nano.Browser.snapshot(browser, offset: page["next_offset"])
Nano.Browser.stop(browser)
```

Start uses installed `lightpanda serve`, loopback and an ephemeral port. Port
reservation is released before spawn (a small bind race remains). The owner
terminates only its own OS process on normal stop. An unlinked port-owner watcher monitors the session and terminates its own
child even after an untrappable session `:kill`. Whole-node/container failure
still cannot guarantee cleanup: this is not restart-persistent lifecycle management. `executable` selects an alternative binary. `connect(ws_url)` creates
a fresh target/session in an existing local CDP service; it never kills that
service. Only `ws://127.0.0.1` is supported; remote/TLS endpoints are rejected.

`command(pid, method, params, timeout: 15000)` exposes raw CDP; evaluate returns
`{:ok, value}` or explicit JavaScript/CDP errors. Transport errors/timeouts close
the session, rather than attempting to reuse a potentially desynchronized socket.
Frames are capped at 5 MB; fragmented frames are unsupported. Arbitrary evaluate
and raw command results are NOT readable-output capped: use snapshot for reading.
CDP events are consumed internally, not delivered to callers. Navigation is a CDP
navigation acknowledgment, not a guarantee that asynchronous application work has
settled. Poll a page condition with evaluate when necessary. Click/fill use DOM
JS, not trusted mouse/keyboard events; sites may treat them differently.

Snapshot returns string-keyed URL, title, text, total, offset and next_offset.
Default cap 12,000 UTF-8 bytes; maximum 30,000. Offsets count JavaScript UTF-16
units. It uses innerText with textContent fallback, NOT Mozilla Readability,
Markdown, screenshot or accessibility rendering. DOM mutation between pages can
change offsets; snapshots are live, not cached. Very small byte caps may not fit
one Unicode character. This is not an SSRF sandbox: browser navigation and page
JavaScript can access local/network resources.

Tests use local port-zero services only. Five focused tests cover invalid
endpoints, missing executable, a forged mocked handshake, and real Lightpanda JS
form navigation/evaluate/click/fill/snapshot/CDP error behavior when the installed
binary exists, plus forced-session-kill child cleanup. No paid services or global environment changes.

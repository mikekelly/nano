# nova-web: web reading, Exa search and research

Discoverable entry points: `Nano.Web`, `Nano.Search`, `Nano.Lightpanda` module docs.
No supervision or dependency changes are required; all are libraries callable from eval.

## Read and cite a page

```elixir
{:ok, page} = Nano.Web.fetch("https://elixir-lang.org/docs/")
page.text # numbered lines, with source URL in page.url
{:ok, next} = Nano.Web.read(page.id, offset: page.next_offset)
```

Only continue when `next_offset` is non-nil. Defaults are 100 lines / 12,000 bytes;
hard slice caps are 2,000 lines / 30,000 bytes. `limit`, `max_bytes`, and `offset`
customize the slice. A single oversized line returns `{:error, {:line_too_large,
line, bytes}}`, rather than silently cutting it. An invalid offset reports total
lines. Pages include id, URL, title, fetched timestamp, truncation and next offset.
Cite the URL and line range (plus timestamp if the page may change).

HTTP fetch defaults to a 20-second receive timeout and five-second connection
timeout, with no automatic retries. `timeout` changes the receive timeout. HTML
extraction removes script/style/navigation/header/footer and keeps block breaks
and link targets. It is intentionally lightweight, **not Mozilla Readability**:
complex/malformed HTML and unusual entities may need browser rendering or Exa.
The title defaults to the source URL for ordinary HTTP pages.

```elixir
Nano.Web.fetch("https://example.com", browser: true)
Nano.Lightpanda.fetch("https://example.com", timeout: 15_000) # raw markdown
```

Lightpanda uses an argument vector (no shell), GNU timeout, and kill-after=1s;
`executable` can select a binary. Missing binary, process failure, timeout, and
unsupported schemes are error values. Interactive CDP clicks/forms/server lifecycle
are not implemented. Browser stderr remains operator-visible, not mixed into pages.

HTTP and browser caches are separate SHA256 ids. Default cache directory is
`/tmp/nano-web-cache`; supply `cache_dir: "/data/your-agent/web"` for persistent
state and use the same option for subsequent reads/contents/research. Writes are
atomic with random exclusive temporary files. Cached fetches are reused for one hour (`ttl` seconds); `refresh: true`
forces network access. `read` intentionally can read an old cached snapshot.
Default retention is 100 pages (`cache_entries`), evicting oldest file timestamps
on store. Concurrent writers may transiently exceed that bound. Storage/fetch
limit is five MB per page (`max_download_bytes`). HTTP bodies are accumulated through a capped Req streaming sink (compression
is disabled); exceeding the cap halts reading. Lightpanda stdout is consumed
incrementally through a capped port. Closing the port on overflow stops local
reading; GNU timeout remains the OS process lifetime backstop. These limits bound
stored bodies, not total browser process memory or an SSRF sandbox. Only http/https schemes are accepted; private/local URLs are not blocked.
PDFs and other binary media return explicit unsupported errors. Dedicated PDF,
repository and video processing is deferred; textual GitHub raw URLs work normally.

## Search and ground an answer

```elixir
{:ok, hits} = Nano.Search.search("Elixir official documentation")
{:ok, pages} = Nano.Search.contents(hd(hits.results).url)
{:ok, grounded} = Nano.Search.answer("Where are Elixir's official docs?")
```

`EXA_API_KEY` is read from the environment (or explicit `api_key`). Without it,
all Exa operations return `{:error, :missing_api_key}`; there is no substitute
search-engine scraper. Search requests five results by default (`limit`), asks
only for highlights and discards full text. Output is capped at ten results,
titles at 300 characters, and two 500-character highlights per hit. Contents
stores clean text and returns readable page handles, not unbounded bodies.
Answers preserve provider citation ids/URLs and bound answer text to 12,000
characters, citations to ten. These are provider-grounded results, not a promise
of truth: open cited URLs and verify the relevant passages.

Optional `params` map passes provider parameters to search, answer and research.
`base_url`, `api_key`, and `req_options` permit isolated test transports without
changing application or global environment. Never print options containing keys.
Transport failures return `{:error, :network_error}`; non-2xx responses return
`{:error, %{status: status, retry_after: headers}}`. Raw error bodies/exceptions
are deliberately omitted to avoid accidental credential disclosure. No retries
are automatic, especially on potentially billable calls.

## Async research

Exa's current docs (read 2026-10-07 from `https://exa.ai/docs/llms.txt`,
`https://exa.ai/docs/agent/quickstart.md`) use **POST /agent/runs** and
**GET /agent/runs/:id**, replacing the legacy research surface.

```elixir
{:ok, job} = Nano.Search.research("Find primary sources for the history of Elixir",
  params: %{"effort" => "auto"}, cache_dir: "/data/your-agent/web")
# End turn / idle. A later event is:
# {:nano_research, job.ref, {:ok, %{id: run_id, status: "completed", page: page}}}
```

The unlinked worker makes the create request and polls in the background; the
initial call is immediate. After creation it sends `{:nano_research_started, ref,
run_id}` so callers can save the id for recovery if polling or the node fails. Completion stores the whole provider run as readable
pretty JSON, including `output.text`, `output.structured`, `output.grounding`,
metadata and costs, and sends a bounded page handle. Options: `notify` pid or stable agent name
(default: agent name resolved from eval Task `$callers`, else caller pid), `poll_interval` ms (3,000), `research_timeout` ms (900,000).
Failed/cancelled runs send error values with the run id. Local deadline sends
`{:error, %{reason: :research_timeout, id: id}}`; recover it via
`research_status(id)`. That explicit status function returns the raw provider
map; use it only when the full response is wanted. Local timeout/worker death
does **not** cancel the remote billable run. Named notifications re-resolve the agent pid at delivery and retry registration
for `notify_timeout` milliseconds (default 30,000), surviving ordinary agent
restarts; worker rescue/catch sends a terminal safe error on unexpected failure.
The worker is not persisted or supervised: a node restart loses its notification. `Process.exit(job.pid, :kill)`
stops local polling only. A transient polling error ends local observation;
explicit status lets callers recover, without hiding billable retries.

## Verification

- Isolated `MIX_ENV=test MIX_BUILD_ROOT=/tmp/nova-web/_build mix test`: 255 passed
  (including the original 10 new mocked tests); existing suite warnings only.
- Final expanded targeted suite: 16 passed (concurrent store, ephemeral eval
  task, replacement named target, worker exception, HTTP and browser byte caps
  and browser timeout regressions included).
- Real HTTP example.com fetch: success, bounded readable text.
- Real Lightpanda example.com render: success, bounded markdown.
- Real Exa search: two official Elixir URLs returned.
- Real Exa contents: official docs stored, 81 lines.
- Real Exa answer: official documentation URL with eight citations.
- Research creation/poll/completion/failure/deadline tested with mocked services;
  no real high-cost research run was started. Interactive CDP not tested/built.

Tests use unique temp directories and per-request Plug mocks; no shared env,
fixed ports, real keys or live services are required by the suite.

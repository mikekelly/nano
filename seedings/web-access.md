# Seeding: web access

Agents should be able to search the web and read pages. The reference is pi's
`pi-web-access` package (source: https://github.com/nicobailon/pi-web-access; docs at
https://pi.dev/packages/pi-web-access). Port its behaviour to Elixir functions callable
from `eval`, keeping the same names where they fit.

## The reference, in brief

- `web_search` — queries one of many search providers (it supports Exa, Brave, Tavily,
  Kagi, OpenAI and others); parameters include the query or queries, number of results
  (default 5, max 20), a recency filter, a domain filter, the provider, and whether to
  include page content.
- `fetch_content` — fetches one or more URLs and returns readable content; handles plain
  pages, PDFs, GitHub repositories (by cloning) and video (via a vision model); modes for
  readable text, raw, or an answer to a prompt about the page.
- `get_search_content` — reads back stored content from an earlier search by response id,
  with offset/limit paging or a text search within it.
- `source_check` — gathers evidence for a claim and returns passages with a status
  (supported, contradicted, unclear, missing evidence).

It fetches over plain HTTP first and falls back through readability extraction, PDF
extraction and hosted extractors when that fails; results are cached for an hour with a
bounded cache; content is sliced to about 30,000 characters by default; requests time out
at 30 seconds.

## What to build here

- The four functions above as an Elixir module, with `fetch_content` and `web_search`
  first; use `EXA_API_KEY` from the environment for search when present (see `search.md`),
  and say clearly which providers are available on this node and which are not.
- Readable extraction of HTML to text or Markdown done on the node; PDFs if a tool can be
  installed in the container; skip video.
- The same caching, slicing and timeout behaviour, with the limits in one place.
- Paged access to long content so an agent never has to pull a whole page into its context.

## What counts as done

An agent can search for something, open the best result, read it in pages, and cite a
passage — all from `eval`, with the calls and their sizes visible in its timeline.

## Related

- Builds on: [guidance.md](guidance.md) (paged reads keep context small), [background-tasks.md](background-tasks.md) (clones and slow fetches).
- Pairs with: [search.md](search.md) (Exa as the search provider), [mcp.md](mcp.md), [bots.md](bots.md) (bots that browse).
- In the seed: the result-size limit `RESULT_MAX_BYTES` ([SPEC.md, Container, configuration and limits](../SPEC.md#container-configuration-and-limits)); `Req` is already a dependency ([mix.exs](../mix.exs)).
- Runs: `porter` (pi's tools ported; the fetching patterns it used) and `gardener` (`Nano.Web`, keyless fallback) in [RUNS.md](RUNS.md); branches `seedling/porter-pi-tools`, `seedling/gardener-five-capabilities`.

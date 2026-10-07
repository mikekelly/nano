# Seeding: search and research with Exa

Needs `EXA_API_KEY` in `.env`; the node passes it through. If it is absent, say so and
stop.

Exa (https://exa.ai; the API is described at https://exa.ai/docs/llms.txt) is a search
engine with an API at `https://api.exa.ai`, authenticated with `x-api-key: $EXA_API_KEY`:

- `POST /search` — natural-language web search with clean page content in the response;
  filters by date, domain and type; optional summaries and highlights.
- `POST /contents` — full contents, summaries and metadata for given URLs.
- `POST /answer` — an answer to a question grounded in search results, with citations.
- `POST /runs` — the research agent: an asynchronous run for deep research, list-building
  and enrichment that returns structured output; poll it or wait for it.

## What to build

- One module with a function per endpoint, callable from `eval`, returning plain terms;
  errors (rate limits, bad key) returned, never raised.
- **Delegation to Exa's research agent**: a way to hand a research question to `/runs`
  with a requested output shape, carry on, and be told by a mailbox event when it is done
  — so an agent can delegate research exactly as it would to a sub-agent (see
  `delegation.md`), and the result arrives as an `<event>`.
- Breadcrumbs: one place that says what search can do here, with an example per call.
- Keep responses small by default (titles and highlights), with a second call for full
  content, so searching does not flood the agent's context.

## What counts as done

An agent asked a question it cannot answer from the node searches, reads, and answers with
citations; and a research run started in one turn is received as an event in a later one.

## Related

- Builds on: [web-access.md](web-access.md) (reading what search finds), [delegation.md](delegation.md) (a research run is delegation), [guidance.md](guidance.md) (small responses by default).
- Used by: [bots.md](bots.md) (memory and research for bots).
- In the seed: keys arrive through the environment and compose passthrough ([docker-compose.yml](../docker-compose.yml), [.env.example](../.env.example)); the agent can read them ([SPEC.md, limits](../SPEC.md#container-configuration-and-limits)).
- Runs: not yet run (no key); `gardener` wired Exa into `Nano.Web` for when a key appears ([RUNS.md](RUNS.md)).

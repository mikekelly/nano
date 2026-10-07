# Seeding: web access

## Outcome

Agents can search the web and read pages from `eval`. When this is done, an agent can
search for something, open the best result, read it in pages that never flood its
context, and cite a passage — with the calls and their sizes visible in its timeline —
and a page that needs JavaScript to render is as readable as one that does not.

## Considerations

- Most pages need no browser: fetch over HTTP and extract the readable part. Some do;
  Lightpanda is in the image (`lightpanda fetch --dump markdown URL` renders a page with
  JavaScript, and `lightpanda serve` exposes a CDP server on 9222 that Puppeteer- or
  Playwright-style clients can drive for clicks and forms).
- Search needs a provider. With `EXA_API_KEY` present, Exa is available ([search.md](search.md));
  without a key, say plainly what is and isn't possible rather than scraping a search
  engine that will rate-limit the node.
- Bounding output is the whole game: slice long content, page it, cache what was fetched
  so a second look is free, and time out. The heuristics coding agents use are in
  [guidance.md](guidance.md).
- PDFs, GitHub repositories and video are each their own problem; decide which are worth
  it here.

## Inspiration

- pi's `pi-web-access` package (https://github.com/nicobailon/pi-web-access, docs at
  https://pi.dev/packages/pi-web-access): four operations — search, fetch content, read
  back stored content by id, and gather evidence for a claim — with HTTP-first fetching,
  readability fallbacks, a one-hour bounded cache, ~30,000-character slices and 30-second
  timeouts. A good shape to learn from; not a requirement to copy.
- Mozilla Readability for extraction; Markdown as the reading format for a model.

How you build it is yours to decide.

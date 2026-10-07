# Seeding: web access

## Outcome

Agents can search the web and read pages from `eval`. When this is done, an agent can
search for something, open the best result, read it in pages that never flood its
context, and cite a passage, so what it reports can be checked — with the calls and their
sizes visible in its timeline, where operators can see what reading the web costs — and a
page that needs JavaScript to render is as readable as one that does not, since many
pages fetched without it are an empty shell that looks like a successful fetch.

## Considerations

- Most pages need no browser: fetch over HTTP and extract the readable part, which is
  faster and lighter than a browser and has fewer ways to fail. Some do; Lightpanda is in
  the image (`lightpanda fetch --dump markdown URL` renders a page with JavaScript, and
  `lightpanda serve` exposes a CDP server on 9222 that Puppeteer- or Playwright-style
  clients can drive for clicks and forms).
- Search needs a provider. With an `EXA_API_KEY` among the node's settings, Exa is
  available ([search.md](search.md)); without a key, say plainly what is and isn't possible rather
  than scraping a search engine that will rate-limit the node, and every agent on it.
- Bounding output is the whole game: a page is often larger than everything else in a
  task, so slice long content and page it; cache what was fetched so a second look is free;
  and time out, because a hung fetch holds the eval until the harness kills it at its
  timeout and its work is lost. The heuristics coding agents use are in
  [guidance.md](guidance.md).
- PDFs, GitHub repositories and video are each their own problem, with their own tools to
  install and keep working; decide which are worth it here.

## Inspiration

- pi's `pi-web-access` package (https://github.com/nicobailon/pi-web-access, docs at
  https://pi.dev/packages/pi-web-access): four operations — search, fetch content, read
  back stored content by id, and gather evidence for a claim — with HTTP-first fetching,
  readability fallbacks, a one-hour bounded cache, ~30,000-character slices and 30-second
  timeouts. A good shape to learn from; not a requirement to copy.
- Mozilla Readability for extraction; Markdown as the reading format for a model.

How you build it is yours to decide.

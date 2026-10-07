# Seeding: search and research

Needs `EXA_API_KEY` in `.env`; the node passes it through. If it is absent, say so and
stop: there is nothing real to build against, and a stand-in would only look like search.

## Outcome

Agents can search the web and hand off research from `eval`. When this is done, an agent
asked a question it cannot answer from the node searches, reads, and answers with
citations, so the answer can be checked; and a research job started in one turn is
received as an event in a later one, so handing research to a service works the way
handing a task to a sub-agent does ([delegation.md](delegation.md)). A research run takes
far longer than an eval may (30 s by default) and the agent should not be stuck waiting
for it.

## Considerations

- Exa (https://exa.ai; API described at https://exa.ai/docs/llms.txt) is the provider the
  operators have a key for. Its API at `https://api.exa.ai` offers search with clean page
  content, contents for given URLs, grounded answers with citations, and asynchronous
  research runs that return structured output. Read its docs from the node; they change.
- Search results are large; by default return titles, highlights and ids, and fetch full
  content only on a second call, so a search does not fill the agent's context.
- Errors (rate limits, a bad key) should be returned as values, never raised: a value lets
  the caller decide (wait, retry, say so), while a raise ends the eval and costs a
  stacktrace in context.
- A long research run is a background job: something must notice it finishing and tell
  the agent by a mailbox message, or the agent has to spend turns polling for it.

## Inspiration

- The search half of pi's `pi-web-access` ([web-access.md](web-access.md)).
- The seed's `idle` with `wakeup_after` as a way to wait cheaply.

How you build it is yours to decide.

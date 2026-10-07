# Seeding: tracing with Langfuse

Needs Langfuse running next to the node; the operators will start whatever compose file
you write for it (see below). Keys are created in Langfuse's UI and put in `.env` as
`LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_HOST`.

Langfuse (https://langfuse.com) is an open-source LLM observability platform. Self-hosting
with docker compose (https://langfuse.com/self-hosting/docker-compose) brings up six
services — web (the UI and API, port 3000), worker, PostgreSQL, ClickHouse, Redis and MinIO
— with secrets to set. Applications send traces through its SDKs or its ingestion API with
the project's keys.

## What to build

- A compose file under `/app` (for example `docker-compose.langfuse.yml`) that runs
  Langfuse on the same compose network as the node, with instructions for the operator.
- A tracer in the node that sends, for every agent: a trace per turn; a generation per
  model request with the model, the messages sent, the response, token usage, cost,
  latency and provider; a span per tool call with its arguments and result; events for
  mailbox events, harness notes, restarts and halts. Use the agent's name and id, the
  request id and the log seq so a trace can be matched to the JSONL log.
- Sending must never slow or block an agent: buffer and send in a separate process, drop
  with a logged warning if Langfuse is unreachable.
- A link from an agent's page on the dashboard to its traces, if that is cheap.

## What counts as done

With Langfuse up and keys in `.env`, a conversation with an agent appears in Langfuse as a
trace with its generations and tool spans, and the numbers match the agent's own log.

## Related

- Builds on: the per-agent JSONL log and its entry types ([SPEC.md, OpenRouter and the harness log](../SPEC.md#openrouter-and-the-harness-log)), which is what the traces mirror; [lib/nano/log.ex](../lib/nano/log.ex).
- Pairs with: [goals.md](goals.md) and [delegation.md](delegation.md) (traces across a parent and its children), [bots.md](bots.md) (sessions as traces).
- Runs: not yet run (no service); `gardener` left a `docker-compose.langfuse.yml` on its branch ([RUNS.md](RUNS.md)).

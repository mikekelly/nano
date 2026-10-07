# Seeding: tracing

Needs Langfuse running next to the node and its keys in `.env` (`LANGFUSE_PUBLIC_KEY`,
`LANGFUSE_SECRET_KEY`, `LANGFUSE_HOST`); the operators will start whatever compose file
you write for it. If they are absent, say so and stop.

## Outcome

Every agent's activity can be followed in Langfuse (https://langfuse.com), an open-source
LLM observability platform, as traces: each turn with its model requests (messages sent,
response, tokens, cost, latency, provider), each tool call with arguments and result, and
the events, notes, restarts and halts around them — matchable to the agent's own JSONL
log. When this is done, a conversation with an agent appears in Langfuse with the same
numbers the dashboard shows, and sending traces never slows or blocks an agent.

## Considerations

- Self-hosting Langfuse with docker compose (https://langfuse.com/self-hosting/docker-compose)
  means six services — web (UI and API, port 3000), worker, PostgreSQL, ClickHouse, Redis,
  MinIO — with secrets to set; the node reaches it by service name on the compose network.
- Traces can be sent through an SDK or the ingestion API; there is no Elixir SDK from
  Langfuse, so the API is the likely route.
- The seed already logs every one of these moments as a structured entry with a seq;
  a tracer that subscribes to the log and sends is one process and touches nothing else.
- Buffer, batch and drop with a warning when Langfuse is unreachable; the log is the
  durable record, Langfuse is a view.

## Inspiration

- The log entry table in [SPEC.md](../SPEC.md#openrouter-and-the-harness-log).
- Langfuse's data model: traces, observations (generations, spans, events), scores.

How you build it is yours to decide.

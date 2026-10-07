# Seeding: MCP, and MCP events

The node should be able to use Model Context Protocol servers, and agents should receive
what those servers push as ordinary mailbox events.

## Client

- Connect to MCP servers described in a config file under `/app` (name, transport —
  stdio command or HTTP URL — and any environment it needs). Connections are supervised and
  reconnect.
- Expose each server's **tools**, **resources** and **prompts** as functions an agent can
  call from `eval`: list them, read a resource, call a tool with arguments and get the
  result, get a prompt. Tool results and resources come back as plain Elixir terms (text,
  and references for anything binary), truncated the way eval results are.
- An agent must be able to discover what is connected and what each server offers without
  being told: one call that returns the catalogue, and a breadcrumb to it.

## Events

- Servers send notifications: a resource changed, the tool list changed, log messages,
  progress on a long call. Deliver these to subscribed agents as mailbox messages, so they
  arrive as `<event>`s like everything else — nothing new in the harness, only a process
  that forwards them.
- An agent subscribes and unsubscribes from `eval`; subscriptions survive the agent's
  restart.

## Scope

Implement the protocol version current at the time (read the specification at
modelcontextprotocol.io from the node), the stdio and streamable-HTTP transports, and
enough of initialisation, capabilities and JSON-RPC to interoperate with a real server.
Test against at least one public reference server (for example a filesystem or fetch
server run with `npx`, if Node can be installed in the container) and against a fake in
tests.

## What counts as done

An agent can connect a server from config, list its tools, call one, read a resource,
subscribe to a resource, and see a change to it arrive as an event — with the whole
sequence visible in its timeline on the dashboard.

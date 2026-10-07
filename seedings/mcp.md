# Seeding: MCP, and MCP events

## Outcome

Agents on this node can use Model Context Protocol servers, and what those servers push
reaches agents as ordinary mailbox events. When this is done, an agent can connect a
server described in a config file under `/app` (so the set of servers survives restarts,
shows in `git diff` and is there for any agent to find), find out what it offers (tools,
resources, prompts) without being told, since servers differ and change, call a tool and
read a resource from `eval`, subscribe to a resource, and see a change to it arrive as an
`<event>`, so it can idle until something happens instead of spending turns polling — with
the whole sequence visible in its timeline on the dashboard, where operators can see what
it did through a server. Subscriptions survive the agent's restart; otherwise a restarted
agent stops hearing about changes it relies on and never knows it.

## Considerations

- The protocol is specified at https://modelcontextprotocol.io (JSON-RPC, initialisation
  and capabilities, two transports in common use: stdio and streamable HTTP). Build to the
  revision current when you read it, and say which, so the next agent knows what to check
  against when it moves on.
- Notifications (resource changed, tool list changed, log messages, progress) are the
  "events" half; the seed's rule is that anything an agent should hear about arrives in its
  mailbox, so a forwarding process is enough — nothing in the harness needs to change.
- Results come back as text and sometimes binary; the seed's result cap and spill files
  apply to whatever an agent prints, so keep results small and paged by default: a
  large result costs context on every later call, and a cut one may lose what mattered.
- A stdio server is a long-running OS process; connections need supervising and
  reconnecting, and a server that dies should be visible, not silent, or agents wait on
  calls that will never answer.
- Reference servers exist for testing (for example a filesystem or fetch server run with
  `npx`); Node is not in the image but can be installed as root.

## Inspiration

- The MCP specification and its reference servers (github.com/modelcontextprotocol).
- Existing Elixir MCP clients and servers on Hex, for what the protocol looks like in
  this language.

How you build it is yours to decide.

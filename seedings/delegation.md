# Seeding: delegation

Agents must be able to start sub-agents that are set up for a job, hand them work, and get
results back, without the parent's context paying for the child's.

## Starting a sub-agent

One function, callable from `eval`, that starts a sub-agent and returns a handle (its name
is enough). Its options:

- **System prompt file** — a path to a Mustache template. The template can include other
  templates or plain text files as partials, so prompts are composed from reusable parts
  (an "identity" partial, a "node facts" partial, a job-specific body). Rendered once at
  start with the same facts the harness renders into the default prompt.
- **Pre-reading** — a list of file paths. The harness adds each file's contents to the
  sub-agent's context before its first turn, as `<file path="..." hash="...">...</file>`,
  where `hash` is a content hash so the agent can tell later whether the file changed.
- **LLM provider and model name** — which provider to call and which model; the default is
  the node's default. The provider abstraction should make a second provider a small
  addition, not a rewrite.
- **Effort** — the reasoning level (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`,
  `max`).
- **Worktree head** — a git SHA. When given, the sub-agent gets its own git worktree of
  `/app` checked out at that SHA, and works there; when not given, no worktree is made and
  it works in `/app` like everyone else.
- **Prompt** — an optional first message. When blank the sub-agent starts idle and waits.
- **MCP servers** — an optional list of MCP servers to connect for the sub-agent (see
  `mcp.md`); their tools and events are available to it from its first turn.

## Working with it

- The parent addresses the sub-agent by name and talks to it by sending messages; the
  sub-agent replies to the pid or name it was given. Define one message shape for
  "here is a task", "here is a result" and "I am done", and document it where a fresh
  agent will find it.
- The parent can wait for a result without spending turns: `idle` with a wakeup, or a
  helper that blocks until a reply arrives or a timeout passes.
- Sub-agents inherit budgets or are given their own; running out must be reported to the
  parent, not just logged.
- The dashboard shows which agent started which (`started_by` exists already); make sure
  what you build keeps that true.

## What counts as done

A parent agent can, from one eval, start a sub-agent with a composed prompt, pre-reading
and a worktree, give it a task, continue with its own work, receive the result as a message
and show it. All of it tested; the message protocol and the options written up where the
next agent will find them.

## Related

- Builds on: [guidance.md](guidance.md) (role and abstraction level; defend your context), [mcp.md](mcp.md) (servers for the child), [background-tasks.md](background-tasks.md) (waiting without spending turns).
- Used by: [bots.md](bots.md) (one agent per bot or per session), [search.md](search.md) (research runs as delegation).
- In the seed: `NanoAgent.start/1` and `started_by` in [lib/nano_agent.ex](../lib/nano_agent.ex); agents addressed by name ([SPEC.md, Operator access](../SPEC.md#operator-access)); the prompt template and its placeholders ([priv/system_prompt.txt](../priv/system_prompt.txt), [SPEC.md, System prompt](../SPEC.md#system-prompt)).
- Runs: `reviewer` (sub-agents never reported; budgets) and `gardener` (`Nano.Delegation`, a watcher reports on a child's behalf) in [RUNS.md](RUNS.md); branches `seedling/reviewer-harness-review`, `seedling/gardener-five-capabilities`.

# Seedings

The thesis and the spec's own experiments are in SPEC.md; the vocabulary: `main` is the *seed*, the minimal harness; a *seeding* is a design spec we
plant in an agent, asking it to grow a capability the seed deliberately lacks; a *seedling*
is the branch that grows (`seedling/<agent>-<what>`, never merged into `main`).

Each seeding is a high-level spec for one capability of a fuller harness. It states the
**outcome** — what must be true when the work is done — then **considerations** worth
weighing and **inspiration** worth reading, and stops there: how to get to the outcome is
the agent's decision, and every seeding says so. The agent reads the spec from `/app`
and builds the capability in the checkout, as modules under `/app/lib` plus whatever else
it needs, following `guidance.md`, which goes with every seeding.

## Planting one

Start a fresh agent with generous limits (turns and tokens 0, context 1,000,000) and send
it, from an operator user, a first message that points at the files rather than pasting
them — the agent reads what it needs:

```
This message is from the people who run this node. Please read /app/seedings/guidance.md
and then /app/seedings/delegation.md, and build what the second one describes. When it
works, or if you conclude it can't be done, send a message to the sender_pid of this
message saying what you built and how to use it.
```

Record the run in `RUNS.md` on the `runs` branch, not here (which seeding, which model, what
grew, cost), push the seedling branch, and reset the checkout to `main` for the next run.

## Seedings

| File | Capability |
| --- | --- |
| [`guidance.md`](guidance.md) | How to build any of them: lean prompts, breadcrumbs, progressive disclosure |
| [`delegation.md`](delegation.md) | Start sub-agents with their own prompt, pre-reading, model, worktree and MCP servers |
| [`mcp.md`](mcp.md) | Speak MCP: use servers' tools and resources, receive their events as mailbox events |
| [`web-access.md`](web-access.md) | Browse and search the web (a port of pi-web-access) |
| [`search.md`](search.md) | Search and research with Exa, including handing work to its research agent |
| [`tracing.md`](tracing.md) | Trace every model call and tool call into Langfuse |
| [`goals.md`](goals.md) | Set, keep and review goals across turns, restarts and agents |
| [`background-tasks.md`](background-tasks.md) | Run shell commands in the background and be told when they finish |
| [`bots.md`](bots.md) | A consumer chat GUI over named bots with identity, per-session context, cross-session memory, autocompaction and cheap decision models |

Some seedings need something only the operators can supply, and say so at the top: an API
key in `.env` (`EXA_API_KEY`), or a service started next to the node (Langfuse). Keep every
seeding true of the running system.

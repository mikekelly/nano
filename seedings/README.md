# Seedings

The vocabulary: `main` is the *seed*, the minimal harness; a *seeding* is a design spec
planted in an agent, asking it to grow a capability the seed deliberately lacks; a *seedling*
is the branch that grows (`seedling/<agent>-<what>`, never merged into `main`).

Each seeding is a high-level spec for one capability of a fuller harness. It states the
**outcome** — what must be true when the work is done — then **considerations** worth
weighing and **inspiration** worth reading, and stops there: how to get to the outcome is
the agent's decision, and every seeding says so. The agent reads the spec from `/app`
and builds the capability in the checkout, as modules under `/app/lib` plus whatever else
it needs, following `guidance.md`, which goes with every seeding.

Each seeding says why each of its parts matters, so an agent can decide what to keep, adapt
or drop for its own situation.

## Seedings

| File | Capability |
| --- | --- |
| [`guidance.md`](guidance.md) | How to build any of them: lean prompts, breadcrumbs, progressive disclosure |
| [`delegation.md`](delegation.md) | Start sub-agents with their own prompt, pre-reading, model, worktree and MCP servers |
| [`mcp.md`](mcp.md) | Speak MCP: use servers' tools and resources, receive their events as mailbox events |
| [`web-access.md`](web-access.md) | Browse and search the web (a port of pi-web-access) |
| [`search.md`](search.md) | Search and research with Exa, including handing work to its research agent |
| [`goals.md`](goals.md) | Set, keep and review goals across turns, restarts and agents |
| [`background-tasks.md`](background-tasks.md) | Run shell commands in the background and be told when they finish |
| [`images.md`](images.md) | See images that arrive in messages and look at image files, on models that can |
| [`bots.md`](bots.md) | A consumer chat GUI over named bots with identity, per-session context, cross-session memory, autocompaction and cheap decision models |

Some seedings need something only the operators can supply, and say so at the top: an API
key in `.env` (`EXA_API_KEY`). Keep every seeding true of the running system: the agent
acts on what it reads here.

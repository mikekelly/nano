# Seeding docs

The vocabulary: `main` is the *seed*, the minimal harness; a *seeding doc* is a design
spec planted in an agent, asking it to grow a capability the seed deliberately lacks; a *seedling*
is the branch that grows (`seedling/<agent>-<what>`, never merged into `main`).

Each seeding doc is a high-level spec for one capability of a fuller harness. It states the
**outcome** — what must be true when the work is done — then **considerations** worth
weighing and **inspiration** worth reading, and stops there: how to get to the outcome is
the agent's decision, and every seeding doc says so. The agent reads the spec from `/app`
and builds the capability in the checkout, as modules under `/app/lib` plus whatever else
it needs, following `guidance.md`, which goes with every seeding doc.

Each seeding doc says why each of its parts matters, so an agent can decide what to keep, adapt
or drop for its own situation.

## The seeding docs

| File | Capability |
| --- | --- |
| [`guidance.md`](guidance.md) | How to build any of them: lean prompts, breadcrumbs, progressive disclosure |
| [`compaction.md`](compaction.md) | Compact every agent's conversation automatically before its context fills, so it stays itself and keeps working |
| [`delegation.md`](delegation.md) | Start sub-agents with their own prompt, pre-reading, model, worktree and MCP servers |
| [`mcp.md`](mcp.md) | Speak MCP: use servers' tools and resources, receive their events as mailbox events |
| [`web-access.md`](web-access.md) | Browse and search the web (a port of pi-web-access) |
| [`search.md`](search.md) | Search and research with Exa, including handing work to its research agent |
| [`goals.md`](goals.md) | Set, keep and review goals across turns, restarts and agents |
| [`background-tasks.md`](background-tasks.md) | Run shell commands in the background and be told when they finish |
| [`images.md`](images.md) | See images that arrive in messages and look at image files, on models that can |
| [`safety-net.md`](safety-net.md) | Recover by itself from the worst: a locked-up node, a node that cannot boot, deleted credentials |
| [`bots.md`](bots.md) | A consumer chat GUI over named bots with identity, per-session context, cross-session memory, autocompaction and cheap decision models |

### Experimental

Each of these tests a hypothesis rather than describing a settled capability: build one
when asked to, so that it can be measured.

| File | Hypothesis |
| --- | --- |
| [`experimental/front-of-mind.md`](experimental/front-of-mind.md) | A short note of what an agent must not lose sight of, kept near the tip of its context by *context bobbing* (re-asserted whenever it sinks too deep), with an optional drift check by a decision model, keeps it on course |
| [`experimental/flywheel.md`](experimental/flywheel.md) | Planning a project, encoding it as a graph of self-contained work units, and letting interchangeable agents pull from it and review each other with fresh eyes delivers more working software per token than the same agents given the brief alone |

Some seeding docs need something only the operators can supply, and say so at the top: an API
key, which the operators supply as a node setting under its usual name (`EXA_API_KEY`). The
node's settings (`Nano.Ops.settings/0`, or `GET /api/settings`) show which are set. Keep every seeding doc true of the running system: the agent
acts on what it reads here.

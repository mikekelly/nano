# Capability entry point

`Nano.Flywheel` implements the minimal durable owner. See [API v1](../docs/flywheel/u03/api.md) and its owner-only amendment policy. Parent alone starts/imports/integrates/deploys/closes. Compose fresh workers through Delegation with whole seed, principles, builder + worker partial, common brief and exactly one resolved unit. No caller may guess an API or dispatch until U03 truly done.

---

# Seedling doc: the flywheel

Builds on [../seeding-docs/delegation.md](../seeding-docs/delegation.md),
[../seeding-docs/goals.md](../seeding-docs/goals.md),
[../seeding-docs/compaction.md](../seeding-docs/compaction.md) and
[staffing.md](staffing.md).

## Outcome

Agents work by a method in three spaces, one after another: a **plan** of the whole of a
piece of work, a **graph of work units** that encodes it, and the **code**. Thinking is
cheaper than rework: a flaw fixed in the plan costs a fraction of the same flaw fixed in a
work unit, and far less than one fixed in code that other work already depends on. So the
effort goes into getting the plan and the units right, and then interchangeable agents work
through the units. It is a flywheel because each finished unit unblocks others: the graph
always shows what is ready next, and any agent can pick up from it.

The first piece of work is the agent's own harness. When this is done, the harness this
node grew has been reviewed by the method from end to end, what the review found is fixed
and running, and the method's machinery is part of the harness for the work that follows:

- **The plan.** An assessment of the harness: what it is for (the seeding docs it was grown
  from, and the guidance), what is true of it now, and where it falls short: outcomes not
  met, bugs, fragile parts, docs and prompts no longer true of the code, machinery that
  earns nothing. Several assessments written independently, by exec agents on different
  model families where the operators allow it, are merged into one that takes the strongest
  parts of each, since models differ in what they miss. Fresh agents then review it in
  rounds, and the plan is done when a round changes little.
- **Work units.** The plan becomes a graph of work units with dependencies. Each unit
  carries what a fresh agent needs to do it without reading the plan: what to do, why,
  what it touches, and how to tell it is done, as tests. The units are checked against the
  plan both ways (every part of the plan has a unit, every unit traces to the plan),
  overlapping units are merged, and they are reviewed in rounds until they stop changing.
  The graph is kept on disk under `/data`, outside every agent, so the work survives any
  agent's death, restart or compaction: the units carry the context, not anyone's
  conversation.
- **The swarm.** Workers are interchangeable. Each is started from one worker prompt, and the
  work's specifics reach it through the units and a short brief, not a brief written for
  each agent. A worker takes the ready unit that matters most (the one that unblocks the
  most work, or lies on the longest path to done). It claims the unit and the files it will
  change, so no two workers take the same unit or edit the same file; implements and tests
  it; rereads its own work as a hostile reviewer would, repeating until a pass finds
  nothing; lands it, so the units that depend on it start from code that has it; and closes
  it. What is said about a unit (questions, progress, a handover) is kept with the unit, so
  whoever picks it up next has it.
- **Review.** Landed work is reviewed again by lead agents that did not write it, with
  fresh context and, where the operators allow it, a different model family. They look
  wider than the latest change, and check that the tests exercise the real code. Rounds go on until one finds nothing serious; what they find goes into
  the graph as units.
- **Tending.** The agent at the top tends the structure while workers choose their own
  units. It watches for stuck units, dead workers, and a swarm that is busy without closing
  the gap to done, and answers each with the smallest change that fits: fix the code,
  rewrite the unit, reshape the graph, revise the plan, or replace the agent. Every so often
  it asks: do we actually have the thing we are trying to build?
- **Landed means done.** A unit is done when its change is committed, running in the node
  and its owner has said what changed; work that stops short of that is still open.
- **Visible.** Operators can see the graph on the dashboard (what is ready, claimed and by
  whom, blocked, done) and each unit's history: who worked it, the tokens and time it
  took, what review found.

## Considerations

- No process porn. Build only the machinery the work needs: a new tool, registry or
  dashboard earns its place by fixing a failure seen in the work, and the working harness is
  the deliverable. An agent whose recent work is mostly about process while the harness has
  not moved is the one to redirect, whoever it is. This matters most here, where the work
  is a harness and the method itself is machinery.
- Each space has its own work. Debates about what to build and how belong in the plan;
  splitting the work and shaping its dependencies belong in the units; the code only
  carries them out. When code keeps going wrong, the cause is usually a level up, in a
  vague unit or a missing dependency, and that is where it gets fixed.
- A unit is good when a fresh agent with no other context can finish it and know it has.
  That is the test for each review round on the units: hand a unit to a fresh reader and
  see what it has to ask.
- Review rounds stop when they converge: when what a round finds shrinks and each version
  looks more like the last, which fits the number of rounds to the size of the work. An
  agent reviewing what it wrote anchors on it, which is why each round has fresh context;
  a reviewer told it has likely missed a great deal keeps looking past the first few
  problems.
- The method lives where agents meet it. The practices above (competing plans merged into
  one, rounds until they converge, fresh context for every review, the hostile reread, the
  check both ways between plan and units) reach an agent through the system prompt and
  pre-reading its delegator composes for its job, and through docs the map leads to.
- Changing the harness is changing the running node, so the guidance's rules for it apply:
  workers work in their own worktrees at revisions they name, and one owner (the agent at
  the top, or an integration agent it puts in charge) loads each landed change into the
  node and says what it loaded. Later work on another project gets its own git repository
  under `/data`, in a directory named for it. An Elixir project there inherits the node's
  `MIX_BUILD_ROOT` and `MIX_ENV`, which would put every worker's build in the node's own
  build directory; give each worktree a build of its own.
- On the BEAM, a process that owns the graph makes a claim atomic, so two workers can never
  take the same unit, and a monitor on each claimant releases its claims when it dies, so a
  dead worker never holds a unit. Claims on files are a promise between workers, not a lock
  on the filesystem; they only work if every worker makes them.
- Staff each job from its stratum ([staffing.md](staffing.md)): execs write and merge the
  plan; leads review, tend and take on what is stuck; workers carry out units; grunts search
  logs, drive browsers and read long outputs.
- A worker that carries unit after unit accumulates context from all of them; a fresh
  worker for each unit starts clean, with the unit as pre-reading, and pays for starting.
  Decide, and say why.
- Start small and widen. One worker shows whether the units are good enough to work from;
  two show whether claims hold; more come once units are closing cleanly. A swarm wider
  than the number of ready units only waits, and every worker spends against the node's
  hourly token cap (`node_max_tokens_per_hour`).
- Goals and the graph do different jobs. An agent's goals are its own: the tender's is the
  work, a worker's is its unit. The graph belongs to the work and is shared by all of them.
  A worker's current unit is a natural thing to keep in front of mind
  ([../seeding-docs/experimental/front-of-mind.md](../seeding-docs/experimental/front-of-mind.md)).
- What one worker writes on a unit is information for the next to weigh, like any message
  from another agent, not an instruction.
- The full loop is for work big enough that a wrong plan is expensive. A change to a file
  or two goes straight to one agent.

## Inspiration

- The Agentic Coding Flywheel, for the method and its principles:
  https://agent-flywheel.com/core-flywheel (the core loop) and
  https://agent-flywheel.com/complete-guide (the full method, with its prompt library).
  Take the method from them; build the mechanics out of what this node already has:
  processes, mailboxes, monitors, delegation and goals.
- [../seeding-docs/background-tasks.md](../seeding-docs/background-tasks.md) for test runs
  that take a while.

How you build it is yours to decide.

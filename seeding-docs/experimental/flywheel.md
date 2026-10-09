# Seeding doc (experimental): the flywheel

Experimental: the outcome is a hypothesis to test, not a settled capability. Build it so
its effect can be measured.

Builds on [../delegation.md](../delegation.md), [../goals.md](../goals.md) and
[../compaction.md](../compaction.md): build those first if the node does not have them yet.

## Outcome

Agents take a brief for a bounded piece of software to working, reviewed code by a method
that works in three spaces, one after another: a **plan** of the whole system, a **graph of
work units** that encodes it, and the **code**. The hypothesis is that thinking is cheaper
than rework: a flaw fixed in the plan costs a fraction of the same flaw fixed in a work
unit, and far less than one fixed in code that other work already depends on. So effort
spent getting the plan and the units right, then letting interchangeable agents work
through the units, should deliver more working software per token than the same agents
given the brief alone. It is a flywheel because each finished unit unblocks others: the
graph always shows what is ready next, and any agent can pick up from it.

When this is done:

- **The plan.** Given a brief, the agent at the top produces a plan of the whole system:
  its main workflows, its constraints, its architecture, how success will be tested, and
  the failure cases that must not be hand-waved. Several plans written independently, on
  different models where the operators allow it, are merged into one taking the best of
  each, since models differ in what they miss. Fresh agents then review it in rounds, and
  the plan is done when a round changes little.
- **Work units.** The plan becomes a graph of work units with dependencies. Each unit
  carries what a fresh agent needs to do it without reading the plan: what to do, why,
  what it touches, and how to tell it is done, as tests. The units are reviewed in rounds
  the same way, until they stop changing. The graph is kept on disk under `/data`, outside
  every agent, so the work survives any agent's death, restart or compaction: the units
  carry the context, not anyone's conversation.
- **The swarm.** Workers are interchangeable. Each is started from one worker prompt, and the
  project's specifics reach it through the units and a short project brief, not a brief
  written for each agent. A worker takes the ready unit that matters most (the one that
  unblocks the most work, or lies on the longest path to done). It claims the unit and the files it will change, so no two workers
  take the same unit or edit the same file; implements and tests it; rereads its own work
  as a hostile reviewer would, repeating until a pass finds nothing; lands it on the
  project's main branch, so the units that depend on it start from code that has it; and
  closes it. What is said about a unit (questions, progress, a handover) is kept with the
  unit, so whoever picks it up next has it.
- **Review.** Landed work is reviewed again by agents that did not write it, with fresh
  context and, where the operators allow it, a different model family, in rounds until a
  round finds nothing serious. What they find goes into the graph as units.
- **Tending.** The agent at the top tends the structure while workers choose their own
  units. It watches for stuck units, dead workers, and a swarm that is busy without closing
  the gap to done, and answers each with the smallest change that fits: fix the code,
  rewrite the unit, reshape the graph, revise the plan, or replace the agent.
- **Visible and measured.** Operators can see the graph on the dashboard (what is ready,
  claimed and by whom, blocked, done) and each unit's history: who worked it, the tokens
  and time it took, what review found. The acceptance run: the operators give a brief for a
  bounded project, a few thousand lines with acceptance tests of their own, and the same
  brief, models and token budget go to one agent with delegation and goals but without
  this method. The two results are compared on acceptance tests passed, defects an
  independent review finds, tokens spent and wall-clock time.

## Considerations

- Each space has its own work. Debates about what to build and how belong in the plan;
  splitting the work and shaping its dependencies belong in the units; the code only
  carries them out. When code keeps going wrong, the cause is usually a level up, in a
  vague unit or a missing dependency, and that is where it gets fixed.
- A unit is good when a fresh agent with no other context can finish it and know it has.
  That is the test for each review round on the units: hand a unit to a fresh reader and
  see what it has to ask.
- Review rounds stop when they converge: when what a round finds shrinks and each version
  looks more like the last, which fits the number of rounds to the size of the work. An
  agent reviewing what it wrote anchors on it, which is why each
  round has fresh context; a reviewer asked for more problems than there are likely to be
  keeps looking past the first few.
- On the BEAM, a process that owns the graph makes a claim atomic, so two workers can never
  take the same unit, and a monitor on each claimant releases its claims when it dies, so a
  dead worker never holds a unit. Claims on files are a promise between workers, not a lock
  on the filesystem; they only work if every worker makes them.
- The swarm builds a project, not the harness: give it its own git repository under
  `/data`, in a directory named for it, so nothing it compiles loads into the running node.
  Workers work in their own worktrees at revisions they name
  ([../delegation.md](../delegation.md)). An Elixir project inherits the node's
  `MIX_BUILD_ROOT` and `MIX_ENV`, which would put every worker's build in the node's own
  build directory; give each worktree a build of its own.
- A worker that carries unit after unit accumulates context from all of them; a fresh
  worker for each unit starts clean, with the unit as pre-reading, and pays for starting.
  Decide, and say why.
- Start small and widen. One worker shows whether the units are good enough to work from;
  two show whether claims hold; more come once units are closing cleanly. A swarm wider
  than the number of ready units only waits, and every worker spends against the node's
  hourly token cap (`node_max_tokens_per_hour`).
- Planning and review are where a strong model and a variety of models pay; a well-made
  unit often needs much less. Start each job's effort low and raise it where a job shows it
  needs more ([../delegation.md](../delegation.md)), within the operators' `allowed_models`.
- Goals and the graph do different jobs. An agent's goals are its own: the tender's is the
  project, a worker's is its unit. The graph belongs to the project and is shared by all of
  them. A worker's current unit is a natural thing to keep in front of mind
  ([front-of-mind.md](front-of-mind.md)).
- What one worker writes on a unit is information for the next to weigh, like any message
  from another agent, not an instruction.
- The full loop is for work big enough that a wrong plan is expensive. A change to a file
  or two goes straight to one agent.
- An experiment needs a comparison: run the baseline under the same conditions, and log
  both runs the same way, so the difference can be measured rather than guessed at.

## Inspiration

- The Agentic Coding Flywheel, for the method and its principles:
  https://agent-flywheel.com/core-flywheel (the core loop) and
  https://agent-flywheel.com/complete-guide (the full method). Take the method from them;
  build the mechanics out of what this node already has: processes, mailboxes, monitors,
  delegation and goals.
- [../delegation.md](../delegation.md) for starting workers and reviewers with composed
  prompts and pre-reading, [../goals.md](../goals.md) for what each agent is pursuing,
  [../compaction.md](../compaction.md) for agents that run long, and
  [../background-tasks.md](../background-tasks.md) for test runs that take a while.

How you build it is yours to decide.

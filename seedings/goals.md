# Seeding: goal setting

Agents should be able to set goals, keep them across turns, restarts and node restarts,
break them down, review them, and show them.

## What to build

- A goal store an agent uses from `eval`: create a goal with a statement and an optional
  parent; mark progress and status (open, done, blocked, abandoned) with a note; list what
  is open; see the tree. Goals belong to an agent but can be read by any agent, so a
  sub-agent can see what its parent is after.
- Persistence under `/data` or in the agent's saved state, so goals survive restarts; the
  restart note already restores history, and the agent should find its goals where it left
  them.
- A review habit that costs little: the agent decides when (for example, at each wakeup,
  or every N turns, or when an `idle` would otherwise be the end of the turn) to look at
  its open goals and either act, re-plan or mark something done. This is the agent's own
  loop, written as code it calls, not a harness rule.
- Visible: open goals shown on the agent's page (the dashboard reads plain functions, so a
  small addition to the agent's info map or a separate read is enough).

## What counts as done

An agent given a vague brief writes goals, works through them over several turns and a
restart, marks them done, and a fresh agent can read what was being pursued and why.

## Related

- Builds on: [guidance.md](guidance.md) (make it survive; the agent's own loop), [background-tasks.md](background-tasks.md) (a wakeup is a good time to review).
- Used by: [delegation.md](delegation.md) (a sub-agent reads its parent's goals), [bots.md](bots.md) (what a bot is pursuing across sessions).
- In the seed: `idle` with `wakeup_after`, and state that survives restarts ([SPEC.md, Failure handling](../SPEC.md#failure-handling)); the agent page shows what `info/1` returns ([SPEC.md, Web dashboard](../SPEC.md#web-dashboard)).
- Runs: `gardener` (`Nano.Goals`, JSONL per agent under `/data/goals`) in [RUNS.md](RUNS.md); branch `seedling/gardener-five-capabilities`.

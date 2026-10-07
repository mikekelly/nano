# Seeding: delegation

## Outcome

An agent can hand work to other agents without its own context paying for theirs. When
this is done, a parent agent can, from one eval, start a sub-agent that is set up for a
job, give it a task, carry on with its own work, and receive the result as a message — and
a sub-agent that runs out of budget or dies is reported to its parent, not just logged.

What "set up for a job" has to cover (these are the outcomes the operators need; how they
are expressed is yours):

- a system prompt composed from reusable parts, so a job prompt can be assembled from an
  identity, the node's facts and a job body rather than written whole each time;
- pre-reading: files the sub-agent has in its context before its first turn, marked so it
  can tell later whether a file changed;
- which provider and model it runs on and at what reasoning effort, defaulting to the
  node's;
- an isolated working copy of `/app` at a given git revision when the job needs one, and
  none when it does not;
- an optional first message, or starting idle;
- optional MCP servers it can use from its first turn (see [mcp.md](mcp.md)).

The parent must be able to wait for a result without spending turns, to address the
sub-agent by name, and to find the message shapes it needs without being told.

## Considerations

- Erlang messages carry no sender; a protocol has to put the reply address in the message.
  The seed's `say` convention (`%{message:, sender_pid:}`) is one precedent.
- Budgets: sub-agents started with the default limits ran out before reporting in an
  earlier run; whoever starts an agent is responsible for what it is allowed to spend and
  for hearing about it when it is spent.
- The seed already records which agent started which (`started_by`) and shows it on the
  dashboard; anything built should keep that true.
- Mustache (https://mustache.github.io) is one well-known way to compose prompts from
  partials; the operators mentioned it, and it is not a requirement.
- Git worktrees (`git worktree add`) give an isolated checkout cheaply; they share the
  repository, so a sub-agent's commits are visible to the parent.
- The parent's context is the thing being protected; measure what a delegation costs the
  parent in tokens, not just whether it works.

## Inspiration

- How coding agents delegate: Claude Code's sub-agents (a brief, an isolated context, a
  report back), pi's sessions; the common shape is one message in, one summary out.

How you build it is yours to decide. Record the choices and the message shapes where the
next agent will find them.

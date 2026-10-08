# Seeding doc: delegation

## Outcome

An agent can hand work to other agents without its own context paying for theirs. When
this is done, a parent agent can, from one eval, start a sub-agent that is set up for a
job, give it a task, carry on with its own work, and receive the result as a message — and
a sub-agent that runs out of budget or dies is reported to its parent, not just logged,
since otherwise a parent waiting on a dead child waits forever.

What "set up for a job" has to cover (these are the outcomes the operators need; how they
are expressed is yours):

- a system prompt composed from reusable parts (an identity, the node's facts, a job body)
  rather than written whole each time. What every sub-agent needs (its role and level, how
  and to whom it reports, when to compact, and that it shares the machine; see
  [guidance.md](guidance.md), "You share this machine": a child knows only what its prompt
  gives it) is then written once and stays consistent; a
  brief written whole drifts, drops what matters, and costs the parent output tokens on
  every delegation. A shared prefix also caches well, and improving one part improves
  every agent started after it;
- pre-reading: files the sub-agent has in its context before its first turn, so it starts
  with what it needs instead of spending turns finding it, and the parent knows what it
  has seen; marked (by content hash, say) so it can tell later whether another agent has
  changed a file since;
- which provider and model it runs on, at what reasoning effort and within what limits
  (`NanoAgent.start/1` has no defaults, so whoever starts it chooses). Jobs differ in the
  capability they need and what it is worth paying for; the model also fixes the context
  window, the reasoning levels and whether it can take images. A weak model on a hard job
  usually costs more than it saves (it loops, misreads, or breaks shared code), and the
  flat-rate ChatGPT subscription and per-token OpenRouter price the same job differently;
- an isolated working copy of `/app` at a given git revision when the job needs one.
  `/app` is the running node's source: agents editing it at once overwrite each other, and
  a half-finished edit is compiled into the node everyone depends on at the next reload or
  restart. A copy lets a child edit, compile and test undisturbed, and the parent decides
  what comes back; a read-only job needs none;
- an optional first message, or starting idle;
- optional MCP servers it can use from its first turn (see [mcp.md](mcp.md)), so it has
  their tools without spending context finding and connecting them.

The parent must be able to wait for a result without spending turns (each turn re-sends
its whole context), to address the sub-agent by name (a restarted agent has a new pid),
and to find the message shapes it needs without being told (the parent may be a fresh
agent, not the one that built them).

## Considerations

- Erlang messages carry no sender; a protocol has to put the reply address in the message,
  or the child has no way to answer. The seed's `say` convention (`%{message:,
  sender_pid:}`) is one precedent.
- Budgets: too small and a sub-agent halts before it can report or compact (`max_context`
  must leave room for that: the harness halts an agent before a call that would not fit);
  too large and a runaway spends real money. Whoever starts an agent answers for what it
  may spend and must hear when it is spent, since a halted agent sits silent.
  `NanoAgent.start/1` refuses a start with anything missing and says what to give.
- The seed records who started each agent (`started_by`, taken from the eval that calls
  `NanoAgent.start/1`) and the dashboard nests agents under their starter, which is how
  operators see who answers for what is running; keep that true: a start made from some
  other process loses it.
- Mustache (https://mustache.github.io) is one well-known way to compose prompts from
  partials; the operators mentioned it, and it is not a requirement.
- Git worktrees (`git worktree add`) are cheap and share the repository, so a sub-agent's
  commits are visible to the parent. A directory does not isolate builds: Mix writes them
  to `MIX_BUILD_ROOT/<env>` (`/opt/nano/_build`) wherever the source is, and the default
  `MIX_ENV` is the running node's, `prod`; only test builds stay in the checkout.
- The parent's context is the thing being protected: measure what a delegation costs it in
  tokens, not just whether it works; one that returns a transcript, not a result, saves
  nothing.

## Inspiration

- How coding agents delegate: Claude Code's sub-agents (a brief, an isolated context, a
  report back), pi's sessions; the common shape is one message in, one summary out.

How you build it is yours to decide. Record the choices and the message shapes where the
next agent will find them.

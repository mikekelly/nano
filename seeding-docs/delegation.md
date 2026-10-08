# Seeding doc: delegation

## Outcome

An agent can hand work to other agents without its own context paying for theirs. When
this is done, a parent agent can, from one eval, start a sub-agent that is set up for a
job, give it a task, carry on with its own work, and receive the result as a message — and
a sub-agent that runs out of budget or dies is reported to its parent, not just logged,
since otherwise a parent waiting on a dead child waits forever.

What "set up for a job" has to cover (these are the outcomes the operators need; how they
are expressed is yours):

- a system prompt composed from reusable parts (partials: the node's facts, the operating
  principles, a flavour such as builder, reviewer or bot, the job) rather than written whole
  each time. Composing it is how the delegator fits the prompt to the kind of agent it is
  starting: the parts that agent will need and none it will not, since each costs context on
  every call and one that does not apply distracts. A child that may itself delegate also
  needs the guidance on composing prompts, so that it fits its own children's in turn. A child knows only what its prompt gives it, so what every
  sub-agent needs (its role and level, how and to whom it reports, the operating principles
  in [guidance.md](guidance.md)) is written once and stays aligned across every agent: a
  brief written whole drifts, drops what matters, and costs the parent output tokens on
  every delegation. Partials also let agent flavours be composed for the task at hand rather
  than written from scratch; a shared prefix caches well; and improving one part improves
  every agent started after it;
- pre-reading: files the sub-agent has in its context before its first turn, so it starts
  with what it needs instead of spending turns finding it, and the parent knows what it
  has seen; marked (by content hash, say) so it can tell later whether another agent has
  changed a file since;
- which provider and model it runs on, and at what reasoning effort: the choices that differ
  from job to job. Jobs differ in the capability they need and what it is worth paying for;
  the model also fixes the context window, the reasoning levels and whether it can take
  images. A weak model or a low effort on a hard job costs more than it saves (it loops,
  misreads, or breaks shared code), and a high effort on a simple one costs time and budget
  for nothing: start low, and raise the effort for a job that has shown it needs more. The
  flat-rate ChatGPT subscription and per-token OpenRouter price the same job differently,
  and the operators may allow only some models and levels (the `allowed_models` setting);
- the limits, which are the same for every sub-agent and so are set once, in the code: its
  model's whole context window (`Nano.Model.lookup/1` gives the model's `context_length`),
  and no turn or token budget, since a budget cuts a job off part-way, often just before it
  reports. `NanoAgent.start/1` takes every limit explicitly; delegation passes these;
- an isolated working copy of `/app` when the job needs one, at a revision the delegator
  always names: there is no default. `/app` is the running node's source: agents editing it
  at once overwrite each other, and a half-finished edit is compiled into the node everyone
  depends on at the next reload or restart. A copy lets a child edit, compile and test
  undisturbed, and the parent decides what comes back; a read-only job needs none. Where the
  child starts is a real decision, not a detail: the delegator's own HEAD may hold
  uncommitted or half-done work, the child may need `main`, a shared foundation, or a
  sibling's branch, and a silent default would start it somewhere nobody chose;
- an optional first message, or starting idle;
- optional MCP servers it can use from its first turn (see [mcp.md](mcp.md)), so it has
  their tools without spending context finding and connecting them.

The parent must be able to wait for a result without spending turns (each turn re-sends
its whole context), to address the sub-agent by name (a restarted agent has a new pid),
and to find the message shapes it needs without being told (the parent may be a fresh
agent, not the one that built them).

## Sub-agents' system prompts

Every agent started on this node is a sub-agent of something: a builder started by its
parent, a bot started by the bots product, a session agent started by a service. Each knows
only what its system prompt tells it, takes all of it as true, and works from it on every
turn, so the prompt decides more of how well it works than anything else it is given. When
this is done, every agent's prompt is true of its harness and fitted to its job:

- **True of its harness and environment.** What reaches the agent and how (an event from its
  mailbox, a note from the harness), what it can do (its tools: `eval` and `idle` on the
  seed's harness, or whatever its harness gives it), who hears what it writes (on this
  harness, nobody: only a message sent from `eval` reaches anyone), its limits, and to whom
  it reports. The seed's template (`prompts/seed.txt`) is a truthful account of `NanoAgent`,
  kept true as the harness changes; an agent on that harness gets it, as a part, or a prompt
  that says the same things as truthfully. A prompt and its harness change together: give an
  agent a tool, or a different harness, and its prompt says so.
- **In the terms of the agent's own world.** What the agent does is described as the agent
  meets it: a bot is in a chat with a person and perhaps other bots, it reads the
  conversation as a conversation, it speaks with one call and stays quiet by not making it.
  The mechanics only code needs (tokens, routing, acknowledgements, retries) stay in the
  code, behind that one call: every rule of a protocol a prompt asks the agent to follow is
  one it can get wrong on any turn.
- **Who it is, first.** Its role, or for a bot its identity and voice, in prose, at the top,
  where the model attends most; then how its world works; then its job.
- **Fitted.** Only the parts this agent needs: a chat bot needs how to be good company in a
  conversation (answering when spoken to, building on others, giving way, saying less rather
  than more), not the principles for building and delegating.
- **In the voice wanted back.** The agent writes like what it reads: a brief in plain,
  warm prose gets an agent that works that way; constraints stated once, with their reason,
  keep it careful without making it guarded.
- **Tried.** A prompt is tested like code: start an agent with it, give it the situations
  it is for (for a bot, a group chat where it is and is not addressed), and read what it
  does.

## Considerations

- Erlang messages carry no sender; a protocol has to put the reply address in the message,
  or the child has no way to answer. The seed's `say` convention (`%{message:,
  sender_pid:}`) is one precedent.
- Whoever starts an agent must hear when it halts or dies, since a halted agent sits
  silent. Spending across the node is bounded by its hourly token cap
  (`node_max_tokens_per_hour`), which halts every agent that reaches it until an operator
  un-halts it, and by the operators.
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

How you build it is yours to decide. Make the message shapes discoverable from the code itself (its module docs), where the
next agent will find them.

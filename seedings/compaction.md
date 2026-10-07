# Seeding: compaction

## Outcome

An agent can work for as long as its job takes, not only until its context is full. Every
agent's conversation only grows, and when it nears the agent's context limit the harness
stops calling the model: without compaction, an agent's working life ends there, mid-task,
unable even to report what it found. When this is done, an agent's conversation is
compacted automatically before every model call that would otherwise leave too little room:
the older part is replaced by a summary of what matters (decisions, commitments, open
questions, what it has built and where things are) and the most recent part is kept as it
was, so the agent can carry on mid-thought. It stays the same agent, with the same name,
pid and mailbox, so the people, sub-agents and processes that reach it, and the ones it
started that report to it, carry on as before. It is told plainly, in the conversation,
that its history was compacted, by what, and where the full record is. This works for every
agent on the node, including sub-agents, without any of them having to remember to do it —
tested on a real agent whose context crosses the threshold, not only in unit tests.

## Considerations

- Automatic, not left to the model: the agent that most needs compacting is the one deep in
  a task, least likely to stop and do housekeeping, and once the harness has halted it for
  its context it can do nothing at all. So the check runs before each model call.
- The threshold is a reserve in tokens, not a fraction: what the compaction itself will
  take, plus room for the next reply. pi, a coding agent whose harness compacts this way,
  compacts when the context passes the window minus 16,384 tokens, lets the summary use up
  to about 13,000 of them, and keeps the last 20,000 tokens of the conversation verbatim:
  94% of a 272,000-token window. Compacting much earlier throws away context the agent
  could still use; much later and the summary has no room.
- The summary is best made by a separate model call with a capped output, so it never
  competes with the agent's own turn for room. Which model makes it, and what it costs,
  matter: compaction runs for every long-lived agent on the node.
- A compacted conversation must still be valid for the provider: every tool call keeps its
  result (providers refuse a call without one), so the cut between summary and kept turns
  falls between exchanges, never inside one.
- The conversation lives in the agent's state, and the harness acts on it every turn, so
  changing it must not race a model request or an eval in flight; and whatever the harness
  derives from it (the context used, which its pre-call check reads) has to be true again
  afterwards, or the agent stays halted.
- The harness's pre-call check is the last line of defence against a request the model
  cannot take; compaction should make it rarely needed, not loosen it.
- Compaction resets the provider's cached prefix, so the next call is paid in full; that is
  another reason not to compact sooner than needed.
- What the agent keeps on disk (notes, goals, its index) survives compaction untouched,
  which is why keeping them current makes a compaction cheap and safe. The log under
  `/data/logs` keeps the whole conversation, so nothing is lost to operators.
- The note telling the agent its history was compacted must be true about who did it and
  why: an agent that believes a person intervened acts differently from one that knows the
  harness did.
- If summarising fails (a provider error, a summary too long), the agent must not be left
  halted silently; it should be clear to it, and to operators, what happened.

## Inspiration

- pi's compaction (github.com/badlogic/pi-mono, `packages/coding-agent/src/core/compaction/`):
  `shouldCompact`, the cut-point search, and the summary prompt.
- Claude Code's and Codex's automatic compaction, for what a good summary keeps.
- [goals.md](goals.md): goals on disk are what a summary can point to instead of repeat.

How you build it is yours to decide.

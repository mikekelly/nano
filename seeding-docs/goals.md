# Seeding doc: goal setting

## Outcome

Agents can set goals, keep them across turns, restarts and node restarts, break them
down, review them cheaply, and show them. A goal kept only in the conversation sinks as
the context grows and is lost when it is compacted; one broken into steps can be checked
off and shared a piece at a time. When this is done, an agent given a vague brief writes
goals, works through them over several turns and a restart, marks them done, a fresh
agent can read what was being pursued and why (the why is what lets it judge whether a
goal still applies), and the agent's open goals are visible on its page, so operators can
see what it is pursuing without reading its log.

## Considerations

- Goals belong to an agent but should be readable by others, so a sub-agent can see what
  its parent is after ([delegation.md](delegation.md)) and make the choices the parent
  would.
- Persistence is on the agent: `/data` survives everything short of removing the volume;
  an agent's saved state survives restarts and node restarts.
- Reviewing goals costs context every time; the agent decides when (at each wakeup,
  every so many turns, before an `idle`), and the review should be a small summary, not
  the whole tree.
- A goal stated once sinks as the conversation grows past it. Context bobbing, the
  technique behind front of mind ([experimental/front-of-mind.md](experimental/front-of-mind.md)),
  re-asserts information at the tip of the context whenever it sinks too deep; goals could
  use it too, keeping the current goal and its next step in view without repeating the tree.
- The dashboard reads plain functions; showing goals means exposing them where the agent
  page can read them cheaply, since it renders live, in the same node as the agents, and
  a slow or blocking read slows the page or hangs it.

## Inspiration

- Task lists in coding agents (Claude Code's todo tool, pi's plan mode): a flat list with
  status, kept visible, updated as a matter of habit.
- The seed's `idle` with `wakeup_after`, which gives an agent a moment to review.

How you build it is yours to decide.

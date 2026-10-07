# Seeding: goal setting

## Outcome

Agents can set goals, keep them across turns, restarts and node restarts, break them
down, review them cheaply, and show them. When this is done, an agent given a vague brief
writes goals, works through them over several turns and a restart, marks them done, a
fresh agent can read what was being pursued and why, and the agent's open goals are
visible on its page.

## Considerations

- Goals belong to an agent but should be readable by others, so a sub-agent can see what
  its parent is after ([delegation.md](delegation.md)).
- Persistence is on the agent: `/data` survives everything short of removing the volume;
  an agent's saved state survives restarts and node restarts.
- Reviewing goals costs context every time; the agent decides when (at each wakeup,
  every so many turns, before an `idle`), and the review should be a small summary, not
  the whole tree.
- The dashboard reads plain functions; showing goals means exposing them where the agent
  page can read them cheaply.

## Inspiration

- Task lists in coding agents (Claude Code's todo tool, pi's plan mode): a flat list with
  status, kept visible, updated as a matter of habit.
- The seed's `idle` with `wakeup_after`, which gives an agent a moment to review.

How you build it is yours to decide.

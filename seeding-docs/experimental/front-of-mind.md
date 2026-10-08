# Seeding doc (experimental): front of mind

Experimental: the outcome is a hypothesis to test, not a settled capability. Build it so
its effect can be measured.

## Outcome

An agent keeps a short note of what it must not lose sight of, and the harness keeps that
note near the tip of its context using a technique called **context bobbing**: information
is deliberately re-asserted at the tip of the context whenever it has sunk too deep, so
the agent stays on course. The hypothesis is that a model attends most to what is recent,
so a plan, a constraint or a question stated once, early, fades as the conversation grows
past it; re-asserting a few hundred words at the right moments should keep the agent on
course for very little context.

When this is done:

- **The note.** From `eval`, an agent can set its front-of-mind note, replace it and clear
  it. It holds at most 1,000 characters, so it stays cheap to repeat and forces a choice
  about what matters most now. It survives the agent's restarts and its compactions.
- **Context bobbing.** While a note is set, the harness tracks how far, in tokens, its most
  recent appearance is from the tip of the context. When that distance passes a threshold,
  the harness shows the note again, as something arriving in the conversation, plainly
  marked as the agent's own note re-shown by the harness, with when it was written. Right
  after a compaction, it is shown again at once.
- **Drift (the advanced version).** Occasionally, a cheap decision model judges how far the
  agent's recent activity has drifted from what its note says, and when drift is likely,
  the next bob says so (for example, with the model's probability), so the agent can return
  to it or deliberately update the note.
- **Measured.** Every bob and every drift judgement is visible on the agent's timeline and
  in its log, with the distance or probability that triggered it, so operators can see
  whether it helps.

## Considerations

- The threshold is the main dial. Too small and the note crowds the context and repeats
  itself; too large and it has already faded before it comes back. Measure distance in
  tokens from the tip, which the harness can estimate from the context it already tracks,
  not in turns, since turns vary enormously in size.
- A bob appends to the conversation, so the provider's cached prefix still holds; it costs
  only its own tokens each time.
- Mid-turn, an agent can make many model calls without anything arriving from its mailbox;
  decide where a bob goes so that it reaches the model when it is needed, not only at the
  next message.
- The note is the agent's own words. It must never read as an instruction from the
  operators or anyone else: an agent that takes its own words for an outside order acts on
  false authority. Say whose it is and when it was written.
- Context bobbing is a technique, not something only this note can use. Goals
  ([../goals.md](../goals.md)) are the obvious next user: the current goal and its next
  step could bob the same way, drawn from the goal system rather than copied into the note.
  Front of mind is the one thing that matters now, which may be a constraint, a warning or a
  question rather than a goal; goals are the durable tree of what the agent is pursuing and
  why. Built as a reusable mechanism, the two complement each other.
- A drift judgement is a small, recurring classification: well below what the agent's own
  model should be spent on, and beyond deterministic code (see "decision models" in
  [../guidance.md](../guidance.md); the operators may have supplied Jev credentials as the
  node setting `TYPESAFE_API_KEY`). Its input is the note and a compact account of recent
  activity, not the whole context. It should never change the note itself: drift is
  sometimes the right call, and only the agent can decide which.
- An experiment needs a comparison. Being able to turn bobbing and the drift check on and
  off for an agent, and logging both, is what lets someone tell whether it made a
  difference.

## Inspiration

- Coding agents that keep a short to-do list or plan and remind the model of it as work
  goes on.
- "Lost in the Middle: How Language Models Use Long Contexts" (Liu et al., 2023), on how
  attention to information depends on where it sits in a long context.
- [../goals.md](../goals.md), the natural second user of the technique, and
  [../compaction.md](../compaction.md) for what survives a compaction.

How you build it is yours to decide.

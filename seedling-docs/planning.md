# Seedling doc: planning

Builds on [../seeding-docs/delegation.md](../seeding-docs/delegation.md),
[../seeding-docs/goals.md](../seeding-docs/goals.md) and [staffing.md](staffing.md).

## Outcome

An agent turns a substantial piece of work into a plan, then self-contained tasks, then
verified results. The plan makes expensive mistakes visible before other work depends on
them. The amount of planning fits the uncertainty and consequence of the job; a small,
clear change can go straight to one agent.

When this is done:

- **An evidenced plan.** The outcome, constraints, current state, uncertainties and evidence
  of completion are explicit. For consequential or uncertain work, independent assessments
  are synthesized and challenged by fresh reviewers. Observations, guesses and decisions
  with their reasons remain distinguishable.
- **Executable tasks.** Each task carries what to do, why, dependencies, owned scope,
  starting revision where relevant, and acceptance criteria. A fresh agent can finish it
  and establish completion without inheriting the planner's conversation. Overlapping
  tasks are combined or ordered. Shared foundations land before work that needs them.
- **A delegation plan.** Agents choose the level of abstraction at which they can own an
  outcome and delegate specifics below it. The plan includes which work stays with its
  owner, which is delegated, sequencing and concurrency, staffing level and the rationale
  for each boundary. It accounts for the orientation each child needs: reading the same
  code, reconstructing the same state and learning the same constraints are real costs.
  Work with substantial orientation overlap normally stays together as one delegation
  with several subtasks. Splitting it needs a benefit that justifies the repeated spend.
- **Coverage.** Every requirement has a task or an explicit disposition, and every task
  serves a requirement. External obligations and blocked outcomes stay visible rather
  than being silently counted as complete.
- **Continuity.** Plans, decisions, task progress, questions and evidence survive the
  responsible agent's death, restart or compaction. Another agent can continue from those
  records. Reports
  from previous workers retain their provenance and are information to weigh.
- **Review and completion.** Authors check their own work; consequential changes receive
  independent review of the actual boundaries and interactions, including whether tests
  exercise the real behavior. Findings become explicit work. Review converges when no
  serious unresolved finding remains and a fresh pass changes little. A task is complete
  when its agreed evidence exists and its result reaches the intended destination; for
  this harness, that includes committed, running, verified code and an operator report.
- **Tending.** An owner watches progress toward the outcome, blocked dependencies, dead
  workers and repeated failures. It responds at the level that needs changing: the code,
  the task, a dependency, the plan or staffing. Operators can see what is done, active,
  blocked and still unverified, with the evidence behind each claim.

## Considerations

- Use layered delegation with as few layers as the work needs. A parent owns the broader
  outcome and resolves trade-offs; children own coherent specifics and may delegate
  further when that helps. Each layer must contribute a decision, integration or review
  that earns its cost. Simple work needs no delegation, and a lead who only relays messages
  adds ceremony.
- Delegate at the right level, using the task contracts in
  [../seeding-docs/delegation.md](../seeding-docs/delegation.md). Roles and model choices
  come from [staffing.md](staffing.md). A child's abstraction level and model capability
  are related choices, not reasons to create a fixed hierarchy for every job.
- Plan boundaries around orientation overlap as well as output scope. Several edits in
  one subsystem may belong to one child even when they produce separate commits. Parallel
  work is worthwhile when reduced elapsed time, independent scrutiny or distinct expertise
  outweighs duplicate orientation, handoffs and integration. Estimate those costs briefly;
  elaborate delegation paperwork can cost more than the work it organizes.
- Give children the relevant entry points, shared findings and decisions with their
  evidence, rather than asking each to rediscover them. Preserve enough source access for
  them to check assumptions. Reuse an oriented agent for related follow-up work when its
  context remains useful; independent review still needs an independent judgment.
- Start with enough work to prove that tasks are understandable and ownership holds.
  Widen concurrency as independent tasks close cleanly. More workers than ready work
  spend context waiting; shared files, builds and live deployment can limit concurrency.
- Keep coordination replaceable. A worker should not need the original planner's memory
  to proceed. Name who integrates changes and who can take over that responsibility;
  avoid relaying messages that already have a stable destination.
- Stop checks when they establish the agreed evidence. Repeat them for new changes,
  failures or unresolved concerns, rather than to generate another reassuring pass.
- Judge the method by verified outcomes, elapsed time, tokens, operator intervention and
  rework. Distinguish cached input, uncached input and output. Record planning, execution
  and review costs separately, so machinery and ceremony must pay for themselves.
  Include child orientation and handoff costs, not just the parent's saved tokens. Use
  repeated orientation, unnecessary layers and avoidable integration work to improve the
  next delegation plan.
- When implementation repeatedly fails, question the task and its assumptions before
  assigning more attempts. A vague contract or missing dependency is repaired upstream.
- For changes to the running harness, one named integration owner controls deployment.
  Recovery must remain available independently of the services the change can interrupt.

## Inspiration

- [../seeding-docs/guidance.md](../seeding-docs/guidance.md) on shared foundations,
  operating at the right level and preserving context.

How you build it is yours to decide.

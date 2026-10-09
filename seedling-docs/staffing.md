# Seedling doc: staffing

Builds on [../seeding-docs/delegation.md](../seeding-docs/delegation.md).

## Outcome

Every agent that starts another staffs the job from a short, shared **staffing matrix**: a
handful of model-and-effort pairs, chosen for value from public benchmarks and what this
node's providers serve, each placed in one of four strata by the level of work it is fit
for:

- **Exec**: architectural deliberation, high-level brainstorming, planning the whole of a
  piece of work, judging between competing plans; the work of a CEO, CTO or CPO.
- **Lead**: planning execution and overseeing it, code and design review, debugging that
  has stopped making progress; the work of an engineering or design lead.
- **Worker**: implementing a feature, designing a screen, debugging; the work of an
  engineer or a designer.
- **Grunt**: work that reads or writes a great many tokens, where low reasoning at a low
  price per token is the right trade: driving a browser, searching through logs, reading
  long outputs for one thing.

When this is done, the matrix is on disk, dated, with where each number came from, and
linked from the map; a delegator can name a stratum where it would name a model and gets
that stratum's pair; each stratum spans more than one model family where the operators
allow it, so plans and reviews from different models do not share blind spots; and the
operators can see the matrix and why each pair is in it: its scores, its cost per task, its
speed, and what it beat.

## Considerations

- Value is effectiveness for the cost of a task. A model that reasons at length costs more
  per task than its price per token suggests, and one that loops costs more than one that
  finishes. Artificial Analysis publishes what running its index cost each model at each
  effort, which is a cost per task.
- Effectiveness has more than one measure, and the strata need different ones: a coding
  index for workers on code; performance on real work tasks for leads and execs writing
  plans, reviews and documents; broad intelligence for exec deliberation. Rank each stratum
  by the measure that matches its work.
- Effort is half the choice. The same model at different efforts sits at different points
  of cost, quality and wall-clock time, and work that waits on an agent waits on its effort.
  Multi-step, goal-directed agentic work builds its own chain of thought across its turns,
  so deep reasoning on every call rarely pays there. A short job writing or editing a plan
  or a specific document gains more from high effort, when its content demands it.
- Price is not always the list price. Models served under a flat-rate subscription (the
  ChatGPT one this node can connect) cost nothing per task within the plan's usage limits:
  a large subsidy, which makes the limits and the speed the constraints for those models
  rather than the money. Per-token providers charge for every task.
- Only what this node can run counts: models its connected providers serve
  (`Nano.Model`) at the levels the operators allow (`allowed_models`).
- Benchmarks age and new models arrive often, so make refreshing the matrix cheap. The
  node's own logs (tokens, turns and time per job, and how each job ended) show how a pair
  does on this node's work, and can correct what the benchmarks say.
- The operators may already have staffed some levels ("Staff each job by its level" in
  [../seeding-docs/guidance.md](../seeding-docs/guidance.md)); the matrix starts from their
  choices and fills in the rest.
- A short list is the point: a few pairs per stratum keep the choice quick and the
  reasons legible.

## Inspiration

- Artificial Analysis (https://artificialanalysis.ai/models): intelligence, coding and
  work-task indices, the cost to run them, and speed, per model and reasoning effort.
- [../seeding-docs/delegation.md](../seeding-docs/delegation.md) on choosing a model and an
  effort for each job, and `Nano.Model` for what each model allows.

How you build it is yours to decide.

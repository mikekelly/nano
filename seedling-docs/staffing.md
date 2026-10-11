# Seedling doc: staffing

Builds on [../seeding-docs/delegation.md](../seeding-docs/delegation.md).

## Outcome

Every agent that starts another staffs the job from a short, shared **staffing matrix**: a
short, opinionated list of model-and-effort choices for each connected provider (OpenAI
and OpenRouter), balancing reasoning capability and task success against cost per completed
task. Each choice fits one or more of four strata:

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
linked from the map; a delegator can name a provider and stratum and get its recommended
pair. Each entry names a default and, where justified, a small number of alternatives
with clear reasons to use them. Across the available providers, the choices offer different
model families for plans and independent reviews where the operators allow it. Operators
can see why each choice won, its evidence and limitations, and what would justify changing
it. New releases and evidence from Nano's own work can update the choices cheaply, without
changing delegators or rewriting the system.

## Considerations

- Value is effectiveness for the cost of a task. A model that reasons at length costs more
  per task than its price per token suggests, and one that loops costs more than one that
  finishes. Artificial Analysis publishes what running its index cost each model at each
  effort, which is a cost per task.
- Choose the evaluations before ranking models. Identify the actual tasks and failure
  costs for each stratum, then select a small set of relevant benchmarks and publications.
  Explain their fit, coverage gaps, freshness and independence. General intelligence and
  coding scores alone do not establish architectural judgment, delegation or review
  quality; use representative tasks to cover those gaps.
- Use several kinds of evidence: providers' model comparisons and system cards,
  independent benchmark reports, and observed results on this node. Provider comparisons
  can expose useful distinctions between coding, knowledge work, computer use and visual
  reasoning that one aggregate index hides. Preserve who published each result and its
  methodology; a provider's comparison is evidence to assess, not a neutral ranking.
- A score belongs to an evaluation configuration. Record the exact model, reasoning
  effort, benchmark version and subset, tool access, harness and relevant footnotes where
  supplied. Max and xhigh, with and without tools, and different computer-use subsets are
  different conditions. Compare matched conditions where possible; mark missing scores
  and unresolved differences rather than merging them into an apparent winner. Conflicting
  published numbers retain their separate sources and dates until explained.
- Effort is half the choice. The same model at different efforts sits at different points
  of cost, quality and wall-clock time, and work that waits on an agent waits on its effort.
  Start from the operators' permitted pairs and measure whether more effort reduces
  failures or rework enough to justify its time and usage. A job's role does not by itself
  establish the effort it needs.
- Price is not always the list price. Models served under a flat-rate subscription (the
  ChatGPT one this node can connect) have no marginal API charge within the plan's usage
  limits, but the subscription, usage limits and elapsed time still matter. Per-token
  providers charge for every task. Keep public benchmark cost separate from measured
  cost and performance on this node's provider.
- Only what this node can run counts: models its connected providers serve
  (`Nano.Model`) at the levels the operators allow (`allowed_models`).
- Benchmarks age and new models arrive often, so make refreshing the matrix cheap. The
  node's own logs (tokens, turns and time per job, and how each job ended) show how a pair
  does on this node's work, and can correct what the benchmarks say.
- Refresh when relevant models, provider availability, pricing or evaluation evidence
  change, or when Nano's outcomes challenge a recommendation. Keep dated evidence and a
  brief reason for each revision. Compare similar task types and include failures, retries
  and rework in cost per completed task; use provider-reported token usage where available.
  Distinguish model performance from provider or harness failures. A single anecdote should
  not silently overturn a choice, and an update should not require an exhaustive benchmark
  run. Validate the affected choices and retain the previous recommendation for comparison.
- Public results nominate candidates; representative tasks on the actual provider and
  harness establish whether a pair fits a role here. Include correctness, time, usage,
  retries, rework and intervention. Coding strength alone does not establish planning or
  review quality, and a cheaper model's large-output job can still require substantial
  reasoning. Choose for the job rather than treating a product tier as a stratum.
- The operators may already have staffed some levels ("Staff each job by its level" in
  [../seeding-docs/guidance.md](../seeding-docs/guidance.md)); the matrix starts from their
  choices and fills in the rest.
- A short list is the point: a few pairs per provider, reused across strata where suitable,
  keep the choice quick and the reasons legible. Make a recommendation even when evidence
  is incomplete, marking its uncertainty; do not leave delegators with a leaderboard to
  interpret for every job.
- Strata describe work, not an agent hierarchy. One pair may serve several strata under
  the operators' constraints. Preserve those constraints and mark missing measurements
  or unavailable model-family diversity honestly; do not invent rankings to fill the map.

## Inspiration

- Providers' model comparison tables, release evaluations and system cards, including
  [Anthropic's Sonnet comparison](https://www.anthropic.com/claude-sonnet-5-5) and other providers' own
  evaluation reports. Read the methodology and footnotes as well as the headline scores.
- [Artificial Analysis methodology](https://artificialanalysis.ai/methodology) and
  [capability indices](https://artificialanalysis.ai/methodology/capability-indices):
  cross-provider evidence, costs and speed; inspect the component evaluations.
- [AA-Briefcase](https://artificialanalysis.ai/evaluations/aa-briefcase) and
  [GDPval-AA](https://artificialanalysis.ai/evaluations/gdpval-aa): knowledge work and
  useful deliverables.
- [Terminal-Bench](https://www.tbench.ai/),
  [FrontierCode](https://cognition.com/frontiercode) and
  [CursorBench](https://cursor.com/cursorbench): complementary evidence about terminal
  work, mergeable code and coding in an agent environment.
- [METR time horizons](https://metr.org/time-horizons/): sustained task completion;
  the horizon describes difficulty in human working time, not agent runtime.
- [OSWorld](https://github.com/xlang-ai/OSWorld-V2): computer use where the job needs it.
  These are starting points for selecting evidence, not a permanent required benchmark set.
- [../seeding-docs/delegation.md](../seeding-docs/delegation.md) on choosing a model and an
  effort for each job, and `Nano.Model` for what each model allows.

How you build it is yours to decide.

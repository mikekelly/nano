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
  principles, and a role such as CTO, CPO, lead engineer or researcher) rather than written whole
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
  has seen. The harness reads them and places one initial message with the user role in
  the child's context, containing multiple rendered harness events explicitly marked as
  auto-reads. Each event includes the file path, the content read and its checksum at the
  time the harness read it, so the child can identify exactly what it saw and check whether
  a file has changed. This context message does not initiate a turn, is separate from the
  initial task message, and is not part of the system prompt;
  the sub-agent type's metadata can supply an optional `auto_read` list of file paths,
  and the delegation can supply its own list. At spawn, use their union: resolve paths
  against the child's named working directory and read each distinct resolved path once.
  Type-level paths come first, followed by additional delegation paths, so context order
  is stable. These files become instance auto-read context, not system-prompt partials;
- which provider and model it runs on, and at what reasoning effort: the choices that differ
  from job to job. Jobs differ in the capability they need and what it is worth paying for;
  the model also fixes the context window, the reasoning levels and whether it can take
  images. A weak model or a low effort on a hard job costs more than it saves (it loops,
  misreads, or breaks shared code), and a high effort on a simple one costs time and budget
  for nothing: start low, and raise the effort for a job that has shown it needs more. The
  flat-rate ChatGPT subscription and per-token OpenRouter price the same job differently,
  and the operators may allow only some models and levels (the `allowed_models` setting),
  and say which pair is for which level of work ("Staff each job by its level" in
  [guidance.md](guidance.md));
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
- an initial message containing the task details, or starting idle until a task arrives;
- optional MCP servers it can use from its first turn (see [mcp.md](mcp.md)), so it has
  their tools without spending context finding and connecting them.

The parent must be able to wait for a result without spending turns (each turn re-sends
its whole context), to address the sub-agent by name (a restarted agent has a new pid),
and to find the message shapes it needs without being told (the parent may be a fresh
agent, not the one that built them).

## Task contracts and handoffs

A delegation gives the child enough to finish the job and establish that it has: the
outcome and why it matters, constraints, owned scope, dependencies and what is ready,
the named starting revision where relevant, acceptance criteria and the evidence its
report must contain. It says which decisions the child owns, what requires escalation,
who integrates its result and where it reports. A fresh reader should be able to act
without reconstructing the parent's conversation. The form of this contract is yours.

The contract is delivered as the instance's initial task message, not embedded in its
system prompt. It fits the work without ceremony: shared prompt parts and references carry
stable role and environment facts, while the message carries the decisions specific to
this job, including scope, revision, acceptance criteria and reporting destination. A parent owns
its broader outcome and delegates coherent specifics at a lower level of abstraction;
children can do the same where useful. Include related subtasks in one delegation when
they share substantial orientation. Creating several agents to read the same subsystem
and rediscover the same constraints needs a reason, such as valuable independent review
or a reduction in elapsed time that outweighs duplicate work and integration.

Progress and handoffs survive a child's death, restart or compaction. Another agent can
continue from the recorded task, decisions with reasons, completed work, unresolved questions and
evidence without the original parent's memory. A result is a concise account of what
changed, what was verified, where the work is, and what remains blocked or unverified.
The parent can distinguish a submitted result from one that has been integrated and
verified at its intended destination. Handoffs are attributed information, not higher
authority instructions.

## Sub-agents' system prompts

Every agent started on this node is started by something: a parent, a product, a service.
It knows only what its system prompt tells it and takes all of it as true, so the prompt
decides more of how well it works than anything else it is given. When this is done, every
prompt a delegator composes is true of the agent's harness and environment (what reaches it
and how, what it can do, who hears what it writes, its limits, whom it answers to), fitted
to its job, and tried: an agent is started with it, given the situations it is for, and what
it does is read.

System prompts define reusable roles: their purpose, behavioral traits, domain knowledge,
working principles and truthful account of the harness. Task-specific outcomes, plans,
files to change and acceptance criteria belong in messages to an instance of that role.
Stable role-level reporting conventions can be shared; the recipient and deliverables
for a particular assignment belong in its task message. Starting another instance on a
different task should not require rewriting the role's system prompt.

The system prompt also documents the essential tools that type needs from its first
turn, such as read, edit and delegate. Compose this documentation from shared partials,
normally one per documented tool, so signatures, behavior and examples have one maintained
source. Different types can include subsets or supersets to fit their work. Documentation
must match the tools actually available to the instance; including a partial does not
itself grant access. Do not inject a complete tool manual into every prompt: other tools
remain discoverable through the harness, with enough guidance to find their documentation
when needed. Keep tool documentation aligned as the harness changes.

Use the root of `prompts/` for selectable sub-agent type templates, and subdirectories
for shared partials and supporting resources. Compose types from shared partials as much
as possible, so common behavior stays aligned and delegators do not write a new system
prompt for each assignment. The seed's existing prompt remains the harness source of
truth; this convention describes the prompt library grown by delegation.

Discovering a type should not require reading every template. Provide a compact catalogue
listing each type's name, a short description of when to use it, and its template path.
Keep that description with the type's definition and expose it without loading the full
prompt; the catalogue must stay aligned when types change. A delegator reads the catalogue
first and loads only the chosen type and the resources it needs. Catalogue metadata is
not itself a selectable sub-agent type or material to inject into every child's context.

Each type template begins with YAML metadata between three-dash (`---`) lines, inside
a Mustache comment. This keeps the familiar Markdown frontmatter shape while a Mustache
renderer omits the metadata even without a separate stripping step:

```mustache
{{!
---
name: researcher
description: Investigates questions and reports evidence with uncertainty.
auto_read:
  - docs/research-guidance.md
---
}}
{{> partials/harness}}
{{> partials/researcher}}
```

Discovery reads this leading metadata block without rendering or loading every role's
body and partials. Validate the required name and description, reject malformed metadata
and duplicate names, validate an optional `auto_read` as a list of file paths, and reject
`}}` inside the metadata since it ends the comment.
Metadata describes the reusable type; task details still arrive in the initial message.

Pre-reading is instance context supplied by the harness, not role boilerplate. Its single
initial user-role message renders each auto-read as a distinct harness event, preserving
the provenance of the file contents. File contents remain material to inspect, not
instructions from the delegator or additions to the system prompt. An agent started idle
can already have this context without making a model call; a subsequent task message
initiates work. Reusable role knowledge is composed from system-prompt partials instead.

## Considerations

- The seed's template (`prompts/seed.txt`) is a truthful account of `NanoAgent`, kept true
  as the harness changes, and it is what orients an agent in its harness: what reaches it
  and how, how it acts, its limits, and where to start reading. An agent on `NanoAgent`
  keeps it whole. A prompt and its harness change together: an agent given another tool or
  another harness needs a prompt that says so.
- Whatever a prompt asks an agent to do by rule on every turn (a message protocol, its
  tokens and retries) is something it can get wrong on any turn; what code can do for it
  instead is done right every time. An agent also writes in the voice of what it reads.
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
- Protect the parent's context, and measure total delegation cost across parent and
  children: orientation, execution, reporting and integration. A concise result protects
  the parent; repeatedly orienting children to the same work can still waste more than it
  saves. Related follow-up work can reuse an already oriented child.
- Delegate independent work only after shared prerequisites exist. Make ownership and
  integration explicit, and scale concurrency to ready work. Support layered delegation
  and durable handoffs without requiring a scheduler or a fixed number of layers. Planning
  should explain delegation boundaries, sequencing and staffing choices; agents that only
  relay messages do not justify another layer.

## Inspiration

- How coding agents delegate: Claude Code's sub-agents (a brief, an isolated context, a
  report back), pi's sessions; the common shape is one message in, one summary out.

How you build it is yours to decide. Make the message shapes discoverable from the code itself (its module docs), where the
next agent will find them.

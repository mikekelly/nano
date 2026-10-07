# Guidance that goes with every seeding

You are building a capability for the harness you run in, from a spec. These principles
apply to all of them. The first one is the reason the others exist.

**Your abstractions compound. Build them first and use them.** The only thing you can do
is run Elixir with `eval`, and every eval costs output tokens to write, attention to get
right, and context for the rest of your life, because the whole conversation is sent on
every call. A step you do by hand costs that every time you do it. A step you have turned
into a function costs it once: after that, reading a file is `read(path)`, finding
something is `grep(pattern)`, running a command is `sh(cmd)`, and asking a sub-agent is one
call — each a few tokens instead of a fresh page of code, each already debugged, each with
the error handling and the output limits built in. The saving is not linear. Shorter steps
mean more steps per context, fewer mistakes per step, and more of your attention on the
problem instead of the plumbing; and every capability you build makes the next one cheaper
to build, because it is built out of the ones before. So the order of work matters: before
the task, build the small set of utilities the task will need; while working, the moment
you notice yourself writing the same code twice, make it a function and switch to it; and
build each new capability on top of the ones you already have. An agent that keeps working
by hand after it has built its tools has wasted the building.

**Keep system prompts lean.** Context is the scarce resource: everything in the system
prompt is paid for on every call, for the agent's whole life. A prompt should describe
the agent's situation and name where to find more, not contain more. Put detail in files.

**Know your role and level of abstraction, and defend your context with delegation.**
Decide what level you are working at and keep your context for that level. An agent
responsible for planning a large, multi-step piece of work should spend its context on
planning and orchestration, and get the work done by breaking it into tasks delegated to
other agents, each with a context of its own; every file it reads and every command it
runs itself is context it no longer has for the plan. The exception is a task so small,
and so unlikely to turn into a yak shave, that the ceremony of delegating it would cost
more context than doing it. Write this into the prompts you compose for yourself and for
the agents you start: it is an operating principle for every agent, not advice for one.

**Use decision models where the LLM is too expensive and code is too brittle.** Some
judgments come up constantly, must be fast and cheap, and are beyond deterministic code
but far below what the agent's own model should be spent on. A decision model such as Jev
(https://docs.typesafe.ai/introduction.md) takes state plus typed questions and returns
typed answers with probabilities that code can branch on, sort by and route with — "the
kind of judgment a highly knowledgeable person could make in a few seconds". Examples:
walking a Markdown knowledge graph to find the sources relevant to a question, scoring
pages, sections and links as it goes (see https://github.com/mikekelly/s1m, which does
exactly this best-first with a budget); deciding whether a message in a shared chat room
needs a turn from a given agent at all; choosing which memories to load into a session;
deciding when a conversation needs compacting. Reach for one of these before either
hand-writing rules or calling the big model in a loop.

**Leave breadcrumbs.** Everything you build must be discoverable by an agent that knows
nothing about it: a fresh agent, a sub-agent, your own successor after a restart. A short
index at a known place (`/app/NOTES.md` or a module's `@moduledoc`) that says what exists
and where, with one example each, is worth more than any amount of documentation that
nobody is pointed at.

**Progressive disclosure.** The first thing an agent sees should be small and should lead
to the next thing. A one-line mention in the prompt leads to an index; the index leads to a
module doc; the module doc leads to the source. Nothing should require reading everything.

**Libraries, not tools.** With `eval`, a capability is a module an agent can call. Prefer a
small set of well-named functions with clear return shapes over anything that changes the
harness's tool list, and use what you build as soon as it works.

**Make it survive.** Code goes under `/app/lib` so it is compiled at every boot and visible
in `git diff`; state that must outlive a process goes to disk under `/data` or into the
agent's own saved state. Assume restarts.

**Tests and honesty.** Test what you build, run the tests, and report what actually passes.
If a spec asks for something the node cannot do (no key, no network, no service), say so
rather than fake it.

**Record what you learn.** Add to `/app/NOTES.md`: what you built, how to call it, what
did not work and why. The next agent starts from there.

## Related

- The seedings these principles apply to: [README.md](README.md) lists them. Each links back here.
- Evidence: [RUNS.md](RUNS.md) — `porter` built a library and did not use it (why "use what you build" is here); `reviewer` built `Nano.Tools` and did, found a harness bug, and lost its sub-agents to small budgets (why delegation needs a protocol and reporting); `gardener` built a utility layer first and everything else on it.
- The seed's own rules: [AGENTS.md](../AGENTS.md) (main stays minimal; seedlings never merge), [SPEC.md](../SPEC.md) (the thesis; simplicity).

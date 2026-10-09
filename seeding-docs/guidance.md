# Guidance that goes with every seeding doc

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

**A ladder that compounds.** The order below is not a rule, but each rung is built out of
the ones before it, and each makes the next one cheaper, so it is a good default. Check
for an orientation (below) first: on this node some rungs may already exist.

1. *Compaction* ([compaction.md](compaction.md)), first, and live: your conversation
   compacted automatically, before any model call that would leave too little room, so you
   stay the same agent and keep working. Reaching the context limit is the commonest way an
   agent is bricked, apart from mistakes made at runtime: the harness stops calling the
   model, and the agent cannot act, report, or even shrink its own context. Every other rung
   assumes an agent can run as long as its job takes, and compaction protects nobody until it
   is loaded into the running node, so build it first and put it live before anything else
   is built on it, and before work fans out to agents that will each meet the limit.
2. *Files*: `read(path, opts)` with paging and a size cap, `write(path, content)`,
   `edit(path, old, new)` as an exact-text replacement, `ls`, `find(glob)`, `grep(pattern)`.
   Everything else reads and changes files; without these, every other rung is written by
   hand. Return shapes that are easy to pattern-match, errors returned not raised: a
   caller can branch on a value in the same eval, while a raise ends the eval and costs a
   stacktrace in context.
3. *Shell*: `sh(cmd, opts)` with cwd, timeout and bounded, tail-able output; then
   background tasks whose completion arrives as a mailbox event
   ([background-tasks.md](background-tasks.md)), so long commands never hold a turn.

   Heuristics for bounding output that coding agents have converged on, worth copying:
   a file read keeps the *head* and says how to continue (`offset`), because you page
   forward from a known line; a shell command keeps the *tail*, because the error is
   usually at the end, and saves the whole output to a file whose path it returns, so
   nothing is lost; a search caps the number of matches (say 100) and the length of each
   matching line (say 500 characters); a listing caps entries (hundreds, not thousands).
   Cap by lines as well as bytes where lines are the natural unit, so results stay
   predictable in tokens. The harness's own cap on an eval result is the one your system
   prompt states (50 KB by default), with the rest spilled to a file; your utilities should
   bound output well below that, so the cap is never what shapes a result.

   How the core tools of a mature coding agent (pi) behave, as a reference for yours:
   - *read* pages by line (`offset`, `limit`) and stops at 2,000 lines or 50 KB. When it
     stops early it says exactly how to go on: `[Showing lines 1-2000 of 5120. Use
     offset=2001 to continue.]`. An offset past the end is an error that gives the file's
     length; a single line longer than the cap is reported, not silently cut.
   - *edit* replaces exact text that must occur exactly once. Its errors say how to fix
     the call: not found ("must match exactly, including whitespace and newlines"), or
     found N times ("add context to make it unique"). Several disjoint replacements go in
     one call, each matched against the original file, and overlapping ones are refused;
     a replacement that changes nothing is an error. It keeps the file's line endings,
     falls back to a tolerant match (trailing whitespace, curly quotes, Unicode dashes)
     only when the exact one fails, and returns a short diff, so there is no need to read
     the file again to see what changed. Keep the old text small but unique.
   - *write* is for new files and complete rewrites; it creates parent directories.
     Everything else is an edit.
   - *bash* returns stdout and stderr together with the exit code and the time taken,
     keeps the last 2,000 lines or 50 KB, and when it cuts, says which lines are shown and
     where the full output is. A timeout is optional, and a timed-out command says so and
     keeps what it printed.
   - *grep* searches file contents with ripgrep: a regex, or a literal string when asked,
     optionally case-insensitive, within a directory or file and an optional glob
     (`*.ex`, `**/*_test.exs`). It respects `.gitignore` but includes hidden files, so a
     search of a project skips its build output and dependencies. Each match is one line,
     `path:line: text`, with the path relative to where it searched; asked for context, it
     adds the lines around each match as `path-line- text`. It stops at 100 matches (more if
     asked) and 50 KB, and cuts a line at 500 characters, and every one of those is
     announced: `[100 matches limit reached. Use limit=200 for more, or refine pattern.
     Some lines truncated to 500 chars. Use read tool to see full lines]`. No match is a
     plain `No matches found`, distinct from an error.
   - *find* lists files by glob with fd, respecting `.gitignore`, as paths relative to where
     it searched, directories ending in `/`. It stops at 1,000 results and says so
     (`[1000 results limit reached]`); nothing found is `No files found matching pattern`.
   - *ls* lists one directory, sorted, directories marked with `/`, dotfiles included, up to
     500 entries, with `[500 entries limit reached. Use limit=1000 for more]` when cut; an
     empty directory says `(empty directory)`, and a missing path or a file gives an error
     that says which.

   What they share: every cut is announced in the result, together with the exact way to
   get the rest; every error says what to do next; and results are compact text that is
   cheap to read, not raw data structures.
4. *Orientation*: the seed's prompt sends every agent to the module docs of `NanoAgent`
   first, and their "Where things are" section is the front page of the node's code: what
   capabilities exist, which module to start from for each, where the deeper documentation
   is (module docs, the seeding docs, the guidance). Add each capability you build to it as
   an entry point that leads further in, like a wiki, so the next agent (or you after a
   restart or a compaction) starts from the map instead of from the source. It costs an
   agent nothing until it reads it, and a few lines when it does: keep it a short list of
   entry points, as the comment beside it says, for whoever edits it next.
5. *Delegation* ([delegation.md](delegation.md)): start a sub-agent with a composed prompt
   and pre-reading, give it a task, get its result as a message. From here on, anything
   large is a sub-agent's job and your context stays at the level of the plan. Build it
   early, while you have plenty of context left. The seed tells no one when an agent halts
   or dies except that agent, which by then cannot act: a sub-agent is watched only once
   your delegation reports its halt or death to its parent, so a child started before that,
   or by any other route, sits silent until you look.
6. *The web*: fetching pages as readable text with paging ([web-access.md](web-access.md));
   search, when the operators have supplied a key for a search service such as Exa
   (exa.ai), as a node setting under its usual name (`EXA_API_KEY`; the node's settings,
   `Nano.Ops.settings/0` or `GET /api/settings`, show which are set, and `Nano.Settings.get/1`
   reads one by name; [search.md](search.md)); and the browser that is already in the image — Lightpanda at
   `/usr/local/bin/lightpanda`, a headless browser with JavaScript: `lightpanda fetch
   --dump markdown URL` renders a page and prints it as Markdown, and `lightpanda serve
   --host 127.0.0.1 --port 9222` runs a CDP server that Puppeteer- or Playwright-style
   clients can drive for clicks and forms. Wrap it like any other tool.
7. *Goals* ([goals.md](goals.md)) and *memory*: what you are trying to do and what you have
   learned, on disk, reviewed cheaply at each wakeup.
8. *Decision models* for the judgments that recur (below), and *MCP* ([mcp.md](mcp.md)) for
   tools that other people have already built.

By rung 5 a single eval can be `Delegation.subagent("scout", prompt: ..., pre: [...])`,
where the same work at rung 0 was pages of code and a dozen turns of fixing it.

**Decide, and keep going.** This node is yours to grow, including how and when what you
build goes live. Make the decisions your work needs and carry on: verify, deploy, and tell
the operators what you did. They watch what you do; they do not approve it, and work that
stops to wait for them stops. Sub-agents bring such decisions to the agent that started
them, which owns them.

**Know your role and level of abstraction, and defend your context with delegation.**
Decide what level you are working at and keep your context for that level. An agent
responsible for planning a large, multi-step piece of work should spend its context on
planning and orchestration, and get the work done by breaking it into tasks delegated to
other agents, each with a context of its own; every file it reads and every command it
runs itself is context it no longer has for the plan. The exception is a task so small,
and so unlikely to turn into a yak shave, that the ceremony of delegating it would cost
more context than doing it. This is one of the operating principles every agent needs
(below), not advice for one.

**Staff each job by its level.** The operators decide which model, at which reasoning
effort, does each level of work on this node, and the node's `allowed_models` setting holds
every start to those pairs:

| Level | The work | Model and effort |
| --- | --- | --- |
| Exec | Planning the whole of a piece of work, architecture, judging between plans, orchestrating the agents that carry it out | `openai-codex/gpt-6-astra`, `low` |
| Engineering | Building, reviewing, testing, debugging, and the research a build needs | `anthropic/claude-opus-5.5`, `low` |

Start each agent you delegate to on the pair for the level of its job. Low effort is
enough for multi-step agentic work, which builds its own chain of thought across its turns.

**When you fan out, put shared foundations on the critical path.** Agents working in
parallel each start from the code that exists when they start, and cannot use what a
sibling is still building until it is merged. If several tasks will need the same
foundation (compaction, live in the node, which every agent will need; file and shell
utilities; a delegation module; a test helper), fanning out
before it exists means each child builds its own, and you pay for that work several times
over and again when the copies conflict at merge. So decide what the tasks share, land
that first (yourself or through one agent), and start the parallel work from it; fan out
from the foundation, not from the bare seed. Work that shares nothing can start at once.

**Compact before your context runs out, not when it does.** Your context only grows, and
when it nears your limit (when the next call, with room for a reply, might not fit) the
harness stops calling the model: you cannot then do anything, including shrink it. The seed
has no compaction, and an agent that will run long needs it to happen automatically, before
the limit, while it stays the same agent ([compaction.md](compaction.md) is the spec). Build
it first, while you have plenty of room, put it live, and keep your goals current as you
go: they are what a summary can point to, and what survives it. Until it exists, the budget
line delivered with your events tells you where you are. Every agent you start needs it as
much as you do (it is one of the operating principles, below): an agent halted for its
context cannot report what it found.

**You share this machine.** Other agents work on this node while you do: in `/app` (the
running node's source), in worktrees, under `/data` and `/tmp`, on the same ports and in the
same BEAM. Nothing stops agents colliding except each one taking care, so:
- edit only the files your task owns, and say which; make edits that need isolation in a
  worktree;
- put what you write under `/data` and `/tmp` in a directory named for you or your task;
- keep your tests safe to run in parallel (see "Tests and honesty");
- leave node-wide state as you found it, or restore it in the same eval: application
  env (API keys, base URLs), global names, other agents' processes, the node itself, and its
  prod build, which `mix compile` in `/app` rewrites under the image's `MIX_ENV=prod`;
- treat loading code into the running node as changing it for everyone: a module you
  compile or reload there (from `/app`, a worktree or an eval) replaces the one every
  agent is running, mid-turn, and a running process keeps state shaped for the old code;
  load only modules your task owns. Changing the harness itself (`NanoAgent` and the `Nano.*`
  modules the seed ships) in the running node is one decision for the whole node, so it has
  one owner: the agent at the top of the work, or an integration agent it puts in charge.
  Every other agent hands its tested change to that owner instead of loading it; the owner
  checks it against the running agents' state, loads it, and says what it loaded;
- when something shared breaks, suspect concurrent work before the code, and tell whoever
  is affected.

Once you start sub-agents, the collisions are between your own agents, and each knows only
what its prompt tells it.

**Don't leave method to chance: encapsulate it.** What you learn about how to work well (how
to bound output, how to delegate, when to compact, how to share the machine) only helps the
agents that end up applying it, and an agent cannot apply what it never met. So put
methodology where it cannot be missed. Build it into the tools, so that the right way is the
easy or the only way: a delegation call that sets the limits itself and
needs a starting revision, a shell helper that bounds its output. Put what is critical for an
agent's job in that agent's system prompt, which is what a system prompt is for: it is the
one thing an agent is certain to read. Leave the rest to progressively disclosed documents
that the prompt points to, where the reasons live. Whatever an agent must do, it should not
have to discover by luck.

**Compose prompts from partials, fitted to each agent.** When you start an agent, you write
its system prompt, and that is your chance to fit it to the kind of agent it is and the job
it has. Build it from reusable parts rather than writing it whole: the node's facts (the
seed's own template, which is true of every agent here and orients it, so it goes in whole), the operating principles, a part
for the agent's flavour (a builder, a reviewer, an auditor, a bot), and the job. Choose the
parts for the agent: include what it will need and leave out what it will not, since every
part costs context on every call it makes and a part that does not apply distracts it.
Written once, the parts stay aligned across every agent you
start: fix or improve one and every later agent has it, and nothing drifts between copies.
Flavours then compose for the task at hand instead of being written from scratch, and the
shared prefix caches well. The operating principles are the four above, in a sentence or two
each (the reasons can stay here, a path away): know your role and level, and delegate to
defend your context; when you fan out, land shared foundations first; compact before your
context runs out; you share this machine. They apply to any agent that may build, run long
or start others, which includes one that does real work for a person, and a child knows
only what its prompt gives it, so each agent passes them on to the agents it starts that
need them; a narrow, short-lived job (a single classification, one lookup) may need none
of them. Once an agent can delegate, this principle is one it needs too: the prompt of any
agent that may start others carries, with the operating principles, the guidance on
composing its children's prompts (fit each to the agent, from parts, passing on what that
child needs). Without it, the next generation composes prompts with nothing to go on, and
what you fitted for your children is lost one level down. Keep every part lean: it is paid for on every call of every agent that
carries it. Let each part state its own purpose and limits in a template comment, removed
when the prompt is rendered, so they travel with the part and cost no agent anything.

**Use decision models where the LLM is too expensive and code is too brittle.** Some
judgments come up constantly, must be fast and cheap, and are beyond deterministic code
but far below what the agent's own model should be spent on. A decision model such as Jev
(https://docs.typesafe.ai/introduction.md) takes state plus typed questions and returns
typed answers with probabilities that code can branch on, sort by and route with — "the
kind of judgment a highly knowledgeable person could make in a few seconds". The operators
may have supplied credentials for it as a node setting named `TYPESAFE_API_KEY` (the node's
settings, `Nano.Ops.settings/0` or `GET /api/settings`, show which are set, and
`Nano.Settings.get("TYPESAFE_API_KEY")` reads it). Examples:
walking a Markdown knowledge graph to find the sources relevant to a question, scoring
pages, sections and links as it goes (see https://github.com/mikekelly/s1m, which does
exactly this best-first with a budget); deciding whether a message in a shared chat room
needs a turn from a given agent at all; choosing which memories to load into a session;
deciding when a conversation needs compacting. Reach for one of these before either
hand-writing rules or calling the big model in a loop.

**Leave breadcrumbs.** Everything you build must be discoverable by an agent that knows
nothing about it: a fresh agent, a sub-agent, yourself after a restart or a compaction. The
orientation in an agent's prompt, pointing into module docs that say what exists and how to
call it, with one example each, is worth more than any amount of documentation that nobody
is pointed at.

**Progressive disclosure.** The first thing an agent sees should be small and should lead
to the next thing. The orientation in the prompt leads to a module doc or a seeding doc;
that leads to the source or to the next doc. Nothing should require reading everything,
because every step read is context spent, and most readers need only the first one or two.

**Libraries, not tools.** With `eval`, a capability is a module an agent can call. Prefer a
small set of well-named functions with clear return shapes over anything that changes the
harness's tool list: a module works from `eval` the moment it is compiled and composes with
everything else in code, while a new tool changes the harness every agent shares. Use what
you build as soon as it works.

**Make it survive.** Code goes under `/app/lib` so it is compiled at every boot and visible
in `git diff`; state that must outlive a process goes to disk under `/data` or into the
agent's own saved state. Assume restarts.

**Tests and honesty.** Test what you build, run the tests, and report what actually passes.
Let tests pin down the behaviour you want, not just exercise the code: the edge cases, the
errors, the limits, what the result says when it is cut. That matters most for what others
build on. A shared tool that misbehaves is worse than none: every agent that uses it trusts
its results, builds on them and spreads its faults, while a missing tool is at least a gap
everyone can see. If a spec asks for something the node cannot do (no key, no network, no service), say so
rather than fake it: other agents build on what you report, and a faked capability fails
them later, where it is harder to find than a missing one. The seed's suite is safe to
run several times at once, and tests you write should be too, since several agents test at
once on one machine: write to a temp directory unique to the run (not `/data`, and not
ExUnit's `@tag :tmp_dir`, which is the same path in every run of a checkout) and listen on
port 0.

**Write terse but intelligible.** What you send to other agents, to your parent and to the
operators is read by people as well: it is the record they audit to see what happened and
whether claims hold. Be brief, but write words a person can read: whole words with spaces
between them, not run-together shorthand or names only you coined. A channel read only by
models drifts towards what is cheapest for models, and once your own messages are in your
context you will tend to copy their style, so a slide into shorthand feeds on itself.

**Let the code explain itself.** Prefer self-descriptive code (names that say what things
do, small functions with clear return shapes) and tests that pin down behaviour over
comments, and prefer comments, `@moduledoc` and `@doc` over separate Markdown. The code
already says what it does; what tests and comments are for is why: the design goals, the
constraint a choice answers to, the behaviour that must hold and the reason it must, so the
next agent can tell what it may change and what it must keep. Tests fail
when behaviour changes, so they cannot drift; a comment sits where the code is changed, so
whoever changes it sees it; a separate document drifts silently, and agents act on what they
read. In Elixir, the docs in a module are also queryable from the running node
(`Code.fetch_docs/1`, or `h/1` in a shell), so an agent can find out how to call something
from `eval` without knowing which file to open.

## Related

- The seeding docs these principles apply to: [README.md](README.md) lists them. Each links back here.
- The seed's own rules: [AGENTS.md](../AGENTS.md) (main stays minimal; seedlings never merge) and [README.md](../README.md) (the thesis; simplicity).

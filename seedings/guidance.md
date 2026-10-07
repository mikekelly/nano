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

**A ladder that compounds.** The order below is not a rule, but each rung is built out of
the ones before it, and each makes the next one cheaper, so it is a good default. Check
`/app/NOTES.md` first: on this node some rungs may already exist.

1. *Files*: `read(path, opts)` with paging and a size cap, `write(path, content)`,
   `edit(path, old, new)` as an exact-text replacement, `ls`, `find(glob)`, `grep(pattern)`.
   Everything else reads and changes files; without these, every other rung is written by
   hand. Return shapes that are easy to pattern-match, errors returned not raised: a
   caller can branch on a value in the same eval, while a raise ends the eval and costs a
   stacktrace in context.
2. *Shell*: `sh(cmd, opts)` with cwd, timeout and bounded, tail-able output; then
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
   - *grep* takes a regex or literal pattern, a glob filter, case-insensitivity and lines
     of context, respects `.gitignore`, and returns matching lines with their paths and line numbers, at most 100
     matches with each line cut to 500 characters. *find* globs (respecting `.gitignore`,
     up to 1,000 paths); *ls* sorts, marks directories with `/`, includes dotfiles and
     stops at 500 entries.

   What they share: every cut is announced in the result, together with the exact way to
   get the rest; every error says what to do next; and results are compact text that is
   cheap to read, not raw data structures.
3. *Compaction* ([compaction.md](compaction.md)): your conversation compacted
   automatically, before any model call that would leave too little room, so you stay the
   same agent and keep working. Without it every agent's working life ends at its context
   limit, mid-task and unable to report; every rung after this assumes an agent can run as
   long as its job takes, and it has to be working before it is needed.
4. *Notes and an index*: a module that says what exists and how to call it, and writes
   `/app/NOTES.md` from that table, so the next agent (or you after a restart) starts from
   the index instead of from the source.
5. *Delegation* ([delegation.md](delegation.md)): start a sub-agent with a composed prompt
   and pre-reading, give it a task, get its result as a message. From here on, anything
   large is a sub-agent's job and your context stays at the level of the plan. Build it
   early, while you have plenty of context left.
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

**Know your role and level of abstraction, and defend your context with delegation.**
Decide what level you are working at and keep your context for that level. An agent
responsible for planning a large, multi-step piece of work should spend its context on
planning and orchestration, and get the work done by breaking it into tasks delegated to
other agents, each with a context of its own; every file it reads and every command it
runs itself is context it no longer has for the plan. The exception is a task so small,
and so unlikely to turn into a yak shave, that the ceremony of delegating it would cost
more context than doing it. Write this into the prompts you compose for yourself and for
the agents you start: it is an operating principle for every agent, not advice for one.

**When you fan out, put shared foundations on the critical path.** Agents working in
parallel each start from the code that exists when they start, and cannot use what a
sibling is still building until it is merged. If several tasks will need the same
foundation (file and shell utilities, a delegation module, a test helper), fanning out
before it exists means each child builds its own, and you pay for that work several times
over and again when the copies conflict at merge. So decide what the tasks share, land
that first (yourself or through one agent), and start the parallel work from it; fan out
from the foundation, not from the bare seed. Work that shares nothing can start at once.

**Compact before your context runs out, not when it does.** Your context only grows, and
when it nears your limit (when the next call, with room for a reply, might not fit) the
harness stops calling the model: you cannot then do anything, including shrink it. The seed
has no compaction, and an agent that will run long needs it to happen automatically, before
the limit, while it stays the same agent ([compaction.md](compaction.md) is the spec). Build
it early, while you have plenty of room, and keep your notes and goals current as you go:
they are what a summary can point to, and what survives it. Until it exists, the budget
line delivered with your events tells you where you are. Every agent you start needs it as
much as you do: an agent halted for its context cannot report what it found.

**You share this machine.** Other agents work on this node while you do: in `/app` (the
running node's source), in worktrees, under `/data` and `/tmp`, on the same ports and in the
same BEAM. Nothing stops agents colliding except each one taking care, so:
- edit only the files your task owns, and say which; make edits that need isolation in a
  worktree;
- put what you write under `/data` and `/tmp` in a directory named for you or your task;
- keep your tests safe to run in parallel (see "Tests and honesty");
- leave node-wide state as it is unless asked, or restore it in the same eval: application
  env (API keys, base URLs), global names, other agents' processes, the node itself, and its
  prod build, which `mix compile` in `/app` rewrites under the image's `MIX_ENV=prod`;
- treat loading code into the running node as changing it for everyone: a module you
  compile or reload there (from `/app`, a worktree or an eval) replaces the one every
  agent is running, mid-turn, and a running process keeps state shaped for the old code;
  load only modules your task owns, never the harness's own (`NanoAgent` and the `Nano.*`
  modules the seed ships) unless asked, and say what you loaded;
- when something shared breaks, suspect concurrent work before the code, and tell whoever
  is affected.

Once you start sub-agents, the collisions are between your own agents, and each knows only
what its prompt tells it. So this belongs in the shared part of every prompt you compose,
beside role, reporting and compaction, for them to pass on to theirs.

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
nothing about it: a fresh agent, a sub-agent, yourself after a restart or a compaction. A short
index at a known place (`/app/NOTES.md` or a module's `@moduledoc`) that says what exists
and where, with one example each, is worth more than any amount of documentation that
nobody is pointed at.

**Progressive disclosure.** The first thing an agent sees should be small and should lead
to the next thing. A one-line mention in the prompt leads to an index; the index leads to a
module doc; the module doc leads to the source. Nothing should require reading everything,
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
If a spec asks for something the node cannot do (no key, no network, no service), say so
rather than fake it: other agents build on what you report, and a faked capability fails
them later, where it is harder to find than a missing one. The seed's suite is safe to
run several times at once, and tests you write should be too, since several agents test at
once on one machine: write to a temp directory unique to the run (not `/data`, and not
ExUnit's `@tag :tmp_dir`, which is the same path in every run of a checkout) and listen on
port 0.

**Record what you learn.** Add to `/app/NOTES.md`: what you built, how to call it, what
did not work and why. The next agent starts from there.

## Related

- The seedings these principles apply to: [README.md](README.md) lists them. Each links back here.
- The seed's own rules: [AGENTS.md](../AGENTS.md) (main stays minimal; seedlings never merge), [SPEC.md](../bootstrap/SPEC.md) (the thesis; simplicity).

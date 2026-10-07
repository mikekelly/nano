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
   hand. Return shapes that are easy to pattern-match, errors returned not raised.
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
   predictable in tokens. The harness's own cap on an eval result is 50 KB
   (`RESULT_MAX_BYTES`) with the rest spilled to a file; your utilities should bound output
   well below that, so the cap is never what shapes a result.

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
3. *Notes and an index*: a module that says what exists and how to call it, and writes
   `/app/NOTES.md` from that table, so the next agent (or you after a restart) starts from
   the index instead of from the source.
4. *Delegation* ([delegation.md](delegation.md)): start a sub-agent with a composed prompt
   and pre-reading, give it a task, get its result as a message. From here on, anything
   large is a sub-agent's job and your context stays at the level of the plan. Build it
   early, while you have plenty of context left (see "Hand over before your context runs out" below).
5. *The web*: fetching pages as readable text with paging ([web-access.md](web-access.md));
   search, when a key for a search service is present (`EXA_API_KEY`;
   [search.md](search.md)); and the browser that is already in the image — Lightpanda at
   `/usr/local/bin/lightpanda`, a headless browser with JavaScript: `lightpanda fetch
   --dump markdown URL` renders a page and prints it as Markdown, and `lightpanda serve
   --host 127.0.0.1 --port 9222` runs a CDP server that Puppeteer- or Playwright-style
   clients can drive for clicks and forms. Wrap it like any other tool.
6. *Goals* ([goals.md](goals.md)) and *memory*: what you are trying to do and what you have
   learned, on disk, reviewed cheaply at each wakeup.
7. *Decision models* for the judgments that recur (below), and *MCP* ([mcp.md](mcp.md)) for
   tools that other people have already built.

By rung 4 a single eval can be `Delegation.subagent("scout", prompt: ..., pre: [...])`,
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

**Hand over before your context runs out, not when it does.** Your context only grows, and
when it reaches your limit the harness stops calling the model: you cannot then do anything,
including hand over. Compacting your context, or handing the baton to a successor agent that starts
fresh with your notes, your plan and the job of reporting to whoever you report to, is
itself work that needs room: a turn that reads what it must and writes the summary or the
successor's brief, which can be long. Leave that room. So have the mechanism working long
before you need it (delegation is the simplest one), keep the handoff cheap by keeping your
notes and goals current as you go, and act on a threshold you set early, well short of the
limit; around half full is a sensible default, and in the last quarter it is already risky.
The budget line delivered with your events tells you where you are. Put the same rule into
the prompts of the agents you start.

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
- The seed's own rules: [AGENTS.md](../AGENTS.md) (main stays minimal; seedlings never merge), [SPEC.md](../bootstrap/SPEC.md) (the thesis; simplicity).

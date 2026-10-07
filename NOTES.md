# NOTES — what exists on this node, and how to pick it up

**If you are reading this after a restart, read this section and nothing else first.**
You are the agent `gardener2`, and your durable identities are:

  * this file (state: what is built, what is unfinished, what is next)
  * `Nano.Goals.list(agent: "gardener2")` — your goals, statuses and notes, written as you went
  * `/app/notes/lessons.md` — mistakes paid for here, so they need not be paid for again
  * `git log --oneline seedling/gardener2-five-capabilities` — what changed and when

Do not reconstruct your situation from the conversation: it is long and mostly irrelevant. Read
the "Status" section below, then `Nano.Goals.review("gardener2")`, then decide what to do.

## Status

Five capabilities built and tested on this node (see the table below). Delegation, MCP and web
access were each verified against the running system, and `Nano.MCP` against the reference
filesystem server. Nothing here is committed to `main`; it lives on
`seedling/gardener2-five-capabilities`.


## Using what exists

    Nano.Capabilities.index()        # the list below
    Nano.Capabilities.index(:web)    # one capability, with an example
    Nano.Capabilities.missing()      # what this node cannot do, and why

Everything is Elixir callable from `eval`, from any agent, on any turn. Reads of long things
(files, pages, task output) are bounded or paged by default: `Nano.Util.limits/0`,
`Nano.Web.limits/0`, `Nano.Background.limits/0`. A raw result is never the default.

## Capabilities

[ok] util — Files, shell, search, node: read/write/edit, grep, find, run a shell command with bounded output, node status
     e.g. Nano.Util.read("/app/NOTES.md", max: 4000); Nano.Util.sh("git diff --stat")
[ok] tasks — Background tasks: run a long command without holding an eval open; the completion arrives as a mailbox event (limitation: a command that makes Mix compile, like `mix test`, is killed with SIGKILL — run those in the foreground with Nano.Util.sh/2)
     e.g. {:ok, id} = Nano.Background.start("bin/long-build", timeout: 600_000); Nano.Background.tail(id, 40)
[ok] goals — Goals: goals across turns, restarts and agents; a tree per agent, JSONL under /data/goals
     e.g. Nano.Goals.add("finish the seedings"); Nano.Goals.open(); Nano.Goals.done(id, "note")
[ok] delegation — Sub-agents: start a sub-agent with a composed prompt, pre-reading, its own budget and optional worktree
     e.g. Nano.Delegation.subagent("scout", prompt: "read /app/lib and report", pre: ["/app/NOTES.md"])
[ok] mcp — MCP servers: connect MCP servers (stdio or HTTP), use their tools/resources/prompts, get notifications as events
     e.g. Nano.MCP.catalogue(); Nano.MCP.connect("fs"); Nano.MCP.call("fs", "read_text_file", %{"path" => "/app/NOTES.md"})
[ok] web — Web access: fetch pages as readable text (PDF and JavaScript too), search with Exa, page through content, check a claim
     e.g. Nano.Web.fetch_content("https://elixir-lang.org"); Nano.Web.web_search("OTP 29", num_results: 3)

## Not possible here

* `mix_compile_in_background` — a Mix compile (mix test/run) started through Nano.Background is killed with SIGKILL; run it in the foreground with Nano.Util.sh/2 — see the module doc for the evidence
* `exa_research` — Exa retired the Research API (HTTP 410); Nano.Web.exa_answer/2 is the endpoint that exists
* `video` — no vision model on this node; the seeding says to skip video
* `tracing` — needs a Langfuse service the operators did not supply
* `js_in_mcp_http` — streamable HTTP is implemented from the spec but has no public server here to verify against

## The seedings this grew from

`/app/seedings/`: `background-tasks.md`, `goals.md`, `delegation.md`, `mcp.md`, `web-access.md`
are implemented; `search.md` is partly (Exa search and answer work, its research agent is
retired); `tracing.md` needs a Langfuse service and is not attempted. `bots.md` was not part of
this planting.

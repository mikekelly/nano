defmodule Nano.Capabilities do
  @moduledoc """
  The index of what exists on this node beyond the seed: one place that says what is available,
  where its docs are, and one example of each. A fresh agent — or this one after a restart — calls
  `index/0` first and follows only what it needs.

      Nano.Capabilities.index()         # everything, a screenful
      Nano.Capabilities.index(:web)     # one capability, with its module and example
      Nano.Capabilities.missing()       # what this node cannot do, and why
      Nano.Capabilities.write_notes()   # regenerate /app/NOTES.md from this table
  """

  @entries [
    %{id: :util, module: Nano.Util, title: "Files, shell, search, node",
      doc: "read/write/edit, grep, find, run a shell command with bounded output, node status",
      example: ~s|Nano.Util.read("/app/NOTES.md", max: 4000); Nano.Util.sh("git diff --stat")|},
    %{id: :tasks, module: Nano.Background, title: "Background tasks",
      doc:
        "run a long command without holding an eval open; the completion arrives as a mailbox event" <>
          " (limitation: a command that makes Mix compile, like `mix test`, is killed with SIGKILL — run those in the foreground with Nano.Util.sh/2)",
      example: ~s|{:ok, id} = Nano.Background.start("bin/long-build", timeout: 600_000); Nano.Background.tail(id, 40)|},
    %{id: :goals, module: Nano.Goals, title: "Goals",
      doc: "goals across turns, restarts and agents; a tree per agent, JSONL under /data/goals",
      example: ~s|Nano.Goals.add("finish the seedings"); Nano.Goals.open(); Nano.Goals.done(id, "note")|},
    %{id: :delegation, module: Nano.Delegation, title: "Sub-agents",
      doc: "start a sub-agent with a composed prompt, pre-reading, its own budget and optional worktree",
      example: ~s|Nano.Delegation.subagent("scout", prompt: "read /app/lib and report", pre: ["/app/NOTES.md"])|},
    %{id: :mcp, module: Nano.MCP, title: "MCP servers",
      doc: "connect MCP servers (stdio or HTTP), use their tools/resources/prompts, get notifications as events",
      example: ~s|Nano.MCP.catalogue(); Nano.MCP.connect("fs"); Nano.MCP.call("fs", "read_text_file", %{"path" => "/app/NOTES.md"})|},
    %{id: :web, module: Nano.Web, title: "Web access",
      doc: "fetch pages as readable text (PDF and JavaScript too), search with Exa, page through content, check a claim",
      example: ~s|Nano.Web.fetch_content("https://elixir-lang.org"); Nano.Web.web_search("OTP 29", num_results: 3)|}
  ]

  @doc "The capability entries as maps (`id`, `module`, `title`, `doc`, `example`)."
  def entries, do: @entries

  @doc "The index, ready to read: a list of lines, or one entry's detail for an id."
  def index(id \\ nil)

  def index(nil) do
    [
      "What this node can do beyond the seed (call from eval; source in /app/lib):",
      ""
    ] ++
      Enum.map(@entries, fn e ->
        "[ok] #{e.id} — #{e.title}: #{e.doc}\n     e.g. #{e.example}"
      end) ++
      [
        "",
        "not possible here: " <> Enum.map_join(missing(), "; ", &"#{&1.id} (#{&1.why})"),
        "detail: Nano.Capabilities.index(:web) · notes: /app/NOTES.md · bounds: each module's limits/0"
      ]
  end

  def index(id) do
    case Enum.find(@entries, &(&1.id == id)) do
      nil -> {:error, :unknown_id, Enum.map(@entries, & &1.id)}
      e -> ["#{e.title} — #{e.doc}", "", "module: #{inspect(e.module)}", "example: #{e.example}"]
    end
  end

  @doc "What this node cannot do, honestly: `[%{id:, why:}]`."
  def missing do
    base = [
      %{id: :mix_compile_in_background,
        why:
          "a Mix compile (mix test/run) started through Nano.Background is killed with SIGKILL; run it in the foreground with Nano.Util.sh/2 — see the module doc for the evidence"},
      %{id: :exa_research, why: "Exa retired the Research API (HTTP 410); Nano.Web.exa_answer/2 is the endpoint that exists"},
      %{id: :video, why: "no vision model on this node; the seeding says to skip video"},
      %{id: :tracing, why: "needs a Langfuse service the operators did not supply"},
      %{id: :js_in_mcp_http, why: "streamable HTTP is implemented from the spec but has no public server here to verify against"}
    ]

    base ++
      if(System.get_env("EXA_API_KEY") in [nil, ""],
        do: [%{id: :exa_search, why: "EXA_API_KEY is not set; keyless search (Wikipedia, DuckDuckGo) is used instead"}],
        else: [])
  end

  @doc "Writes `/app/NOTES.md` from this table (and the resume pointer); returns the path."
  def write_notes do
    path = Path.join(Nano.Util.app_dir(), "NOTES.md")

    body = """
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

    #{status_text()}

    ## Using what exists

        Nano.Capabilities.index()        # the list below
        Nano.Capabilities.index(:web)    # one capability, with an example
        Nano.Capabilities.missing()      # what this node cannot do, and why

    Everything is Elixir callable from `eval`, from any agent, on any turn. Reads of long things
    (files, pages, task output) are bounded or paged by default: `Nano.Util.limits/0`,
    `Nano.Web.limits/0`, `Nano.Background.limits/0`. A raw result is never the default.

    ## Capabilities

    #{Enum.map_join(@entries, "\n", fn e -> "[ok] #{e.id} — #{e.title}: #{e.doc}\n     e.g. #{e.example}" end)}

    ## Not possible here

    #{Enum.map_join(missing(), "\n", fn m -> "* `#{m.id}` — #{m.why}" end)}

    ## The seedings this grew from

    `/app/seedings/`: `background-tasks.md`, `goals.md`, `delegation.md`, `mcp.md`, `web-access.md`
    are implemented; `search.md` is partly (Exa search and answer work, its research agent is
    retired); `tracing.md` needs a Langfuse service and is not attempted. `bots.md` was not part of
    this planting.
    """

    File.write!(path, body)
    path
  end

  defp status_text do
    """
    Five capabilities built and tested on this node (see the table below). Delegation, MCP and web
    access were each verified against the running system, and `Nano.MCP` against the reference
    filesystem server. Nothing here is committed to `main`; it lives on
    `seedling/gardener2-five-capabilities`.
    """
  end
end

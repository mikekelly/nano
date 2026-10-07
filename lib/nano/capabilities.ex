defmodule Nano.Capabilities do
  @moduledoc """
  The index of what has been built on this node beyond the seed: one place that says what
  exists, where its docs are, and one example of each. A fresh agent (or a sub-agent, or
  this agent after a restart) should call `index/0` first and follow only what it needs.

  Progressive disclosure: the system prompt stays lean, `Nano.Capabilities.index/0` is the
  one screen that lists everything, each entry points at a module's `@moduledoc` for detail,
  and the source is under `/app/lib`.

      Nano.Capabilities.index()          # everything, one line each
      Nano.Capabilities.index(:goals)    # one capability, with an example
      Nano.Capabilities.missing_keys()   # operator-supplied keys/services not on this node
      Nano.Capabilities.write_notes()    # regenerate /app/NOTES.md from this table
  """

  @entries [
    %{
      id: :util,
      title: "Files, shell, search, node",
      module: Nano.Util,
      doc:
        "read/write/edit files, grep and find, run shell commands, inspect agents and the node",
      example: ~s|Nano.Util.read("/app/NOTES.md", max: 4000); Nano.Util.sh("git diff --stat")|,
      status: :working
    },
    %{
      id: :tasks,
      title: "Background tasks (async shell)",
      module: Nano.Background,
      doc:
        "run a long shell command without holding an eval open; be told by event when it finishes",
      example: ~s|{:ok, id} = Nano.Background.start("mix test"); Nano.Background.status(id)|,
      status: :working
    },
    %{
      id: :goals,
      title: "Goals across turns and restarts",
      module: Nano.Goals,
      doc: "create/list/complete goals, a tree per agent, persisted under /data/goals",
      example: ~s|Nano.Goals.add("finish delegation", note: "seeding"); Nano.Goals.open()|,
      status: :working
    },
    %{
      id: :delegation,
      title: "Sub-agents",
      module: Nano.Delegation,
      doc:
        "start a sub-agent with a composed prompt, pre-reading, model and optional worktree; get its result as an event",
      example:
        ~s|Nano.Delegation.subagent("scout", prompt: "read /app/lib and report", pre: ["/app/NOTES.md"])|,
      status: :working
    },
    %{
      id: :mcp,
      title: "MCP (Model Context Protocol)",
      module: Nano.MCP,
      doc:
        "connect MCP servers from /app/mcp.json, list/call their tools and resources, subscribe to their events",
      example:
        ~s|Nano.MCP.connect("fs"); Nano.MCP.tools("fs")   # reads /app/mcp.json, or pass a command/URL|,
      status: :working
    },
    %{
      id: :web,
      title: "Web search and fetch",
      module: Nano.Web,
      doc: "search the web, fetch pages as readable text or Markdown, page through long content",
      example:
        ~s|Nano.Web.web_search("OTP 29 release notes"); Nano.Web.fetch_content("https://example.com")|,
      status: :partial
    }
  ]

  @missing [
    %{
      id: :exa,
      needs: "EXA_API_KEY in the environment",
      how: "put EXA_API_KEY=... in .env (see seedings/search.md) and restart the node"
    },
    %{
      id: :brave,
      needs: "BRAVE_API_KEY (an alternative web search provider)",
      how: "optional; DuckDuckGo and page fetching work without it"
    }
  ]

  @doc "The capability index as a list of maps (`id`, `title`, `module`, `doc`, `example`, `status`)."
  def entries, do: @entries

  @doc """
  The index, ready to read: a list of strings, or one capability when given an id.
  Status is `:working` or `:partial` (built, some of the spec's paths need a key).
  `missing_keys/0` says what the operators still have to supply.
  """
  def index(id \\ nil)

  def index(nil) do
    missing =
      case missing_keys() do
        [] -> "none"
        list -> Enum.map_join(list, ", ", & &1.id)
      end

    [
      "Capabilities on this node (call from eval; source /app/lib; detail in each @moduledoc):",
      ""
    ] ++
      Enum.map(@entries, &line/1) ++
      [
        "",
        "missing keys/services: #{missing}",
        "by id: Nano.Capabilities.index(:delegation) · notes: /app/NOTES.md · regenerate: Nano.Capabilities.write_notes()"
      ]
  end

  def index(id) do
    case Enum.find(@entries, &(&1.id == id)) do
      nil -> {:error, :unknown_id, Enum.map(@entries, & &1.id)}
      entry -> [line(entry), "", "module: #{inspect(entry.module)}", "example: #{entry.example}"]
    end
  end

  defp line(e),
    do: "#{status_mark(e.status)} #{e.id} — #{e.title}: #{e.doc}\n    e.g. #{e.example}"

  defp status_mark(:working), do: "[ok]"
  defp status_mark(:partial), do: "[partly]"
  defp status_mark(other), do: "[#{other}]"

  @doc """
  The capabilities that need something only the operators can supply:
  `[%{id:, needs:, how:}]`, empty when everything is supplied.
  """
  def missing_keys, do: Enum.filter(@missing, &missing?(&1.id))

  defp missing?(:exa), do: System.get_env("EXA_API_KEY") in [nil, ""]
  defp missing?(:brave), do: System.get_env("BRAVE_API_KEY") in [nil, ""]
  defp missing?(_), do: false

  @doc "Writes `/app/NOTES.md` from the same table; returns the path. Run after changing the index."
  def write_notes do
    path = Path.join(Nano.Util.app_dir(), "NOTES.md")

    body = """
    # NOTES — what an agent built here

    Breadcrumbs for a fresh agent (or the same one after a restart): what exists on this
    node, how to call it, and one example each. Generated by
    `Nano.Capabilities.write_notes/0`; keep that table up to date, not this file.

    ## Using what exists

    Everything is Elixir callable from `eval`, from any agent, on any turn:

        Nano.Capabilities.index()        # the list below, as strings
        Nano.Capabilities.index(:goals)  # one capability, with an example
        Nano.Capabilities.missing_keys() # what operators still have to supply

    Bounds live in `Nano.Util.limits/0`, `Nano.Web.limits/0`, `Nano.MCP.limits/0`,
    `Nano.Background.limits/0`. Reads of long things (files, pages, logs, task output) are
    capped or paged, so nothing dumps a whole file into context by accident.

    ## Capabilities

    #{Enum.map_join(@entries, "\n", &line/1)}

    ## Missing on this node

    #{case missing_keys() do
      [] -> "Nothing: every capability is fully supplied."
      list -> Enum.map_join(list, "\n", fn m -> "* `#{m.id}` — needs #{m.needs}; #{m.how}" end)
    end}

    ## Seedings

    Specs are in `/app/seedings/`: `delegation.md`, `mcp.md`, `web-access.md`, `goals.md`,
    `background-tasks.md` (this run), plus `search.md` and `tracing.md` (which need an Exa
    key and a Langfuse service). The status above says which are complete and which wait.

    ## Worth knowing

    * A message from another agent or a user arrives as an `<event>`; a sender that wants a
      reply puts its pid in the message, and `:erlang.list_to_pid/1` rebuilds `#PID<…>`.
    * `Nano.Util.calling_agent/0` inside an eval says which agent is running it.
    * `Nano.Delegation` sub-agents and background tasks report by message, so the parent can
      `idle` with a wakeup instead of blocking an eval.
    * Durable state is under `/data` (`/data/goals`, `/data/tasks`, `/data/state`,
      `/data/logs`); code is under `/app/lib`, compiled at boot.

    ## Built for the five seedings grown in this run

    * `guidance.md`, `background-tasks.md`, `goals.md`, `delegation.md`, `mcp.md` and
      `web-access.md`: five capabilities, all working. `search.md` and `tracing.md` were
      left out of this run — they need an `EXA_API_KEY` and a Langfuse service the
      operators did not supply.
    * MCP speaks the current revision (2025-06-18) and interoperates with real servers.
    * Web search works today via Wikipedia (keyless); it uses Exa when a key is supplied,
      and DuckDuckGo when its endpoint is not rate-limiting.

    ## Things that cost time (so they need not again)

    * A port's data goes to the process that opened it: run the shell command in a
      dedicated drainer process that both opens the port and reads it, or the output file
      stays empty (`Nano.Background`).
    * A stdio MCP handshake inside `handle_continue` must not `receive` for the response:
      that same process has to stay free to read the transport. Use the deferred-reply
      path with a `self()` waiter, as `Nano.MCP.Server` does for initialize.
    * `:spawn_executable` needs an absolute path: resolve it with
      `System.find_executable/1`.
    * Node reading piped stdin blocks under the eval's group leader (which never EOFs);
      feed it a file instead (`Nano.Web.readable/1`).
    * `npx` needs `npm`: installed with `apt-get install nodejs npm`, and jsdom +
      `@mozilla/readability` under `/app/priv/web`.
    * A known flaky pair of the seed's own tests: `Nano.StateStoreTest` (async) puts
      partial entries into the store while `Nano.SmokeTest` renders a page that reads
      every entry; once in a few runs that races and the page fails. Not touched here.
    """

    File.write!(path, body)
    path
  end
end

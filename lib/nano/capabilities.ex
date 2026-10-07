defmodule Nano.Capabilities do
  @moduledoc "Discover seedling libraries. `index/0` is compact; `notes/1` writes the same index to disk. Module docs and linked guides disclose details progressively."
  @entries [
    {:files_shell, Nano.Tools, "Bounded file operations and shell commands",
     "docs/nova-tools.md"},
    {:background, Nano.Background, "Restart-safe commands and completion events",
     "docs/nova-tools.md"},
    {:delegation, Nano.Delegation, "Composed prompts, isolated children and lifecycle reports",
     "docs/nova-delegation.md"},
    {:mcp, Nano.MCP, "MCP tools, resources, prompts and mailbox notifications",
     "docs/nova-mcp.md"},
    {:browser, Nano.Browser, "Interactive Lightpanda CDP browser sessions",
     "docs/nova-browser.md"},
    {:web, Nano.Web, "HTTP/JavaScript pages, cached paging and citations", "docs/nova-web.md"},
    {:search, Nano.Search, "Exa search and asynchronous research (requires key)",
     "docs/nova-web.md"},
    {:goals, Nano.Goals, "Durable goal trees and concise reviews", "docs/nova-goals.md"},
    {:memory, Nano.Memory, "Durable cross-session knowledge", "docs/nova-goals.md"},
    {:decisions, Nano.Bots.Decision, "Optional typed small-model judgements",
     "docs/nova-bots.md"},
    {:bots, Nano.Bots, "Consumer chat sessions, identity and human requests", "docs/nova-bots.md"}
  ]
  def entries do
    Enum.map(@entries, fn {name, mod, description, guide} ->
      %{
        name: name,
        module: mod,
        description: description,
        guide: guide,
        loaded: Code.ensure_loaded?(mod)
      }
    end)
  end

  def index do
    Enum.map_join(entries(), "\n", fn e ->
      "#{e.name}: #{inspect(e.module)} — #{e.description} (#{e.guide}; #{if e.loaded, do: "loaded", else: "not loaded"})"
    end)
  end

  def notes(path \\ "/app/NOTES.md") do
    text =
      "# Seedling capability index\n\nBranch: `seedling/nova-all`; never merge into main.\n\nUse `Nano.Capabilities.index()` from eval for a live availability index.\nRead the linked guides for examples and honest limits; modules contain API docs.\n\n" <>
        index() <> "\n\n" <> examples()

    File.write(path, text)
  end

  defp examples do
    """
    ## Start here (from eval)

    ```elixir
    Nano.Tools.read("/app/NOTES.md", limit: 60)
    Nano.Tools.sh("git status --short", cwd: "/app")
    {:ok, job} = Nano.Background.start("sleep 1; echo done")
    # Completion is a mailbox event; use the harness idle tool rather than model polling.
    Nano.Capabilities.index()
    Nano.Goals.review("my-agent", limit: 5)
    Nano.Memory.review("my-agent", query: "current task", limit: 5)
    Nano.Web.fetch("https://example.com")
    Nano.Search.search("Elixir documentation") # requires EXA_API_KEY
    ```

    For isolated child agents and acknowledged durable results, read
    `docs/nova-delegation.md`; for configured external tools use `docs/nova-mcp.md`.
    Interactive JavaScript/click/form browser sessions are in `docs/nova-browser.md`.
    The consumer chat UI is `/bots`; `docs/nova-bots.md` describes bot/session creation,
    per-bot model configuration, memory, context rollover and human requests.

    ## Boundaries

    This is the seed's trusted, unauthenticated single-user node, not a public service.
    Bots do not provide separate VM security sandboxes. Keep credentials out of prompts,
    chat and commits; deployment authorization belongs outside this UI. Each linked guide
    records actual verification and remaining limits. Main remains untouched; source and
    integration commits live only on seedling branches.
    """
  end
end

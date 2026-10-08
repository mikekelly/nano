defmodule Seedling.Index do
  @moduledoc "Discover installed seedling capabilities: entries/0, render/0, write_notes/1."
  def entries do
    [
      %{
        name: "Files and shell",
        module: Seedling.Tools,
        example:
          ~s|Seedling.Tools.read("/app/NOTES.md"); Seedling.Tools.sh("git status --short")|,
        detail:
          "Bounded file paging/search/listing, exact multi-edits with diff, safe shell timeout/tail/full spill. read/sh retain compact metadata. See docs/tools.md; rg/fd-find required and installed by Dockerfile."
      },
      %{
        name: "Background jobs",
        module: Seedling.Background,
        example:
          ~s|Seedling.Background.start("MIX_ENV=test mix test", owner: "orion", timeout: 120000)|,
        detail:
          "Completion event %{background: id,status: code,reason: atom,output: path,bytes: n}. tail(path), cancel(pid), info(pid). Survives agent restart, not node restart. tail(path) returns {:ok,page_map} with exact backward paging; result(owner,id) recovers durable status. See docs/background.md for containment and unacknowledged-send limits."
      },
      %{
        name: "Delegation",
        module: Seedling.Delegation,
        example:
          ~s|Seedling.Delegation.subagent("scout", model: "openai-codex/gpt-6.1-sol", reasoning: "high", max_turns: 40, max_tokens: 200000, max_context: 100000, prompt: "Investigate", pre: ["/app/NOTES.md"], message: "Begin")|,
        detail:
          "Composed prompts, hashed pre-reading, explicit worktree revision, optional MCP. Durable completion/failure/restart events by parent name. report/2, result/1, tell/2; docs/seedling/delegation.md."
      },
      %{
        name: "Automatic checkpoints",
        module: Nano.Compaction,
        example: ~s|NanoAgent.info("orion")|,
        detail:
          "Harness automatically summarizes older history before context exhaustion and within long tool loops; preserves pid/mailbox/bindings, paired recent turns and durable logs. Structured checkpoint plus deterministic files list. docs/compaction-and-images.md; explicit failure/retry, pre-call safety remains."
      },
      %{
        name: "Goals",
        module: Seedling.Goals,
        example:
          ~s|Seedling.Goals.create(me, "Deliver capability", "Why it matters"); Seedling.Goals.review(me)|,
        detail:
          "Durable goal trees with why, parent IDs and open/active/blocked/done/cancelled status. Child completion checked. Bobbing optional via configure/2. Dashboard integration forthcoming; real orchestration goals persisted for orion."
      },
      %{
        name: "Memory",
        module: Seedling.Memory,
        example:
          ~s|Seedling.Memory.remember("my-bot", "preference", "Prefers quiet hotels"); Seedling.Memory.recall("my-bot", "hotel")|,
        detail:
          "Durable per-bot graph with links/provenance, bounded retrieval, Jev reranking; labelled lexical fallback if decision service unavailable."
      },
      %{
        name: "Front of mind (experimental)",
        module: Seedling.FrontOfMind,
        example:
          ~s|Seedling.FrontOfMind.set(me, "Keep the constraint in view"); Seedling.FrontOfMind.configure(me, threshold: 8000, drift: true)|,
        detail:
          "At most 1000 characters, durable set/replace/clear. Automatic bobbing hooks integrated at every model request and after compaction; own note visibly re-shown on real orion. Do not infer efficacy from implementation; controlled comparison required."
      },
      %{
        name: "Typed decisions",
        module: Seedling.Decision,
        example:
          ~s|Seedling.Decision.evaluate("Recent activity", %{"drift" => Seedling.Decision.noul("Has activity drifted from the goal?")})|,
        detail:
          "Typesafe Jev typed noul/choice/score judgments; returns probabilities/errors as values. Supplied TYPESAFE_API_KEY live validated against jev-1.13.0; never print credentials."
      },
      %{
        module: Nano.Images,
        name: "Images",
        detail:
          "Immutable sniffed and fully decoded single-frame PNG/JPEG/GIF refs, bounded bytes/dimensions. Fresh vision agents receive actual pixels on provider wire; text-only agents get explicit warning. API POST /api/agents/:name/images {base64,text}, GET /api/images/:id and dashboard upload/timeline. Hot source integration done, router live reload forthcoming. docs/compaction-and-images.md.",
        example: "Nano.Images.view(\"/tmp/screenshot.png\")"
      },
      %{
        module: Seedling.Web,
        name: "Web reading",
        detail:
          "HTTP-first readable text, Lightpanda JS fallback, 1h/100-entry disk cache. read(id,offset:next), cite(id,offset:,limit:). Bounded Unicode pages; PDFs/video/repository checkout explicitly unsupported. docs/web-search.md.",
        example: "Seedling.Web.fetch(\"https://elixir-lang.org\", mode: :auto, limit: 2000)"
      },
      %{
        module: Seedling.Search,
        name: "Search and async research",
        detail:
          "Exa compact highlights/ids, contents/answer citations, current /agent/runs research completion events by stable agent name. research_read/watch/cancel; explicit key errors, no scraping. Actual grounded structured research cost $0.012 validated. After node restart call watch(remote_id). docs/web-search.md.",
        example:
          "Seedling.Search.search(\"Erlang OTP documentation\"); Seedling.Search.research(\"Explain BEAM mailboxes\", effort: \"minimal\", notify: me)"
      },
      %{
        module: Seedling.Browser,
        name: "Browser",
        detail:
          "Lightpanda JS DOM/fill/click and owned loopback CDP, stop(session); fetch_async returns Background job, read_background(event) pages render. Actual JS/forms/CDP and agent restart lifecycle tested. docs/web-search.md.",
        example:
          "Seedling.Browser.run(url, [{:fill, \"#q\", \"text\"}, {:click, \"#go\"}]); Seedling.Browser.serve()"
      },
      %{
        module: Seedling.MCP,
        name: "MCP",
        detail:
          "Durable current2026-07-28/legacy2025-11-25 stdio+HTTP JSON/SSE clients. Config priv/seedling/mcp.json, tools/resources/prompts discovery, call/read/subscribe stable-name mailbox events, bounded result_page. Supervised live startup active. docs/seedling/mcp.md lists subset/no OAuth or sampling, offline event-memory limit. Delegation optional servers gated before first turn; constructor glue pending final tests.",
        example:
          "Seedling.MCP.servers(); Seedling.MCP.connect(\"configured-server\", agent: \"orion\"); Seedling.MCP.tools(\"configured-server\")"
      }
    ]
  end

  def render do
    "# Seedling capability index\n\nBranch `seedling/orion-harness`; never merged into main. Modules are callable from eval.\n\n" <>
      Enum.map_join(entries(), "\n", fn e ->
        "## #{e.name}\n\n`#{inspect(e.module)}` — #{e.detail}\n\n```elixir\n#{e.example}\n```\n"
      end)
  end

  def write_notes(path \\ "/app/NOTES.md"), do: Seedling.Tools.write(path, render())
end

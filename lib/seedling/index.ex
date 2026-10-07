defmodule Seedling.Index do
  @moduledoc "Discover seedling capabilities with entries/0; regenerate /app/NOTES.md with write/1."
  def entries do
    [
      {"Files", "Seedling.Files",
       "read(path, offset: 0, lines: 100); write(path, text); edit(path, old, new); ls(path); find(glob); grep(text, glob: glob); tail(path)",
       "Reads keep the head, shell tails keep the end. Caps: 24 KB, 500 lines/matches/entries. A clipped long line is reported; next_offset advances by lines."},
      {"Shell / background tasks", "Seedling.Shell",
       "start(\"mix test\", notify: \"sol\", cwd: \"/app\", timeout: 120000); kill(pid); sh(\"pwd\")",
       "Completion: {:shell_done, worker_pid, %{status: status, reason: reason, path: path, bytes: bytes}}. Output is on disk, not in event. Always pass notify: your agent name from eval (default self() is the transient eval task). Named recipient resolves after restart (60s retry). Workers are independent and appear as spawned processes. Python3 creates an OS process group; kill/timeout kills that group. No survival across node/container restart, no durable delivery acknowledgement; detached OS descendants can escape the group. Log files require manual retention. Use start, not sh, for long work."},
      {"Web", "Seedling.Web",
       "fetch(url); read(id, offset: page.next_offset); evidence(id, passage); search(query)",
       "Durable one-hour bounded cache, HTTP-first readable extraction and Lightpanda JavaScript rendering. See seedings/WEB_USAGE.md for caps, errors and unsupported PDF/video/CDP interactions."},
      {"Search and research", "Seedling.Search",
       "search(query); contents(urls); answer(query); research(query, notify: \"sol\")",
       "Exa key required. Results bounded/persisted; async research event and resume(id, notify: name) after restart. Live provider smoke passed; see seedings/SEARCH_USAGE.md for shapes/costs/limits."},
      {"Goals", "Seedling.Goals",
       "add(\"sol\", title, parent: id, why: rationale); complete(name,id,note); review(name)",
       "Durable per-agent tree and read-only dashboard compact review. See seedings/GOALS_USAGE.md; final filename format hash-based, legacy base64 development paths are read safely and migrate_legacy(name) writes validated hashed storage. Actual node restarts tested."},
      {"Delegation", "Seedling.Delegation",
       "subagent(name, prompt: brief, pre: paths, notify: \"sol\", message: \"Begin\"); report(reply_to, ref, result)",
       "Composed node facts/identity/job, bounded SHA preread snapshots, model/budget controls, optional worktrees/MCP setup. Completion/failure events; watchers survive agents not node. See seedings/DELEGATION_USAGE.md. Ten targeted tests passed."},
      {"MCP", "Seedling.MCP",
       "connect(name, config, notify: \"sol\"); tools(name); call_tool(name, tool, arguments); subscribe(name, uri, \"sol\")",
       "Durable named server configuration and desired subscriptions; stdio and dual-era Streamable HTTP, discovery, tools, resources and prompts. Mailbox events appear in agent timelines. Fifteen targeted tests and live reference filesystem server discovery/read passed. No automatic OAuth, sampling or privileged roots; calls are never replayed and events have no durable delivery acknowledgement. See seedings/MCP_USAGE.md."},
      {"Bots / consumer chat", "Seedling.Bots",
       "create_bot(attrs); create_session(bot_ids, attrs); say(session_id, text); attach(session_id, bot_id, path); request_human(bot_id, question, reply_to: \"sol\"); answer(request_id, text)",
       "Durable bot identities, shared sessions and human requests at /bots; one agent context per bot/session with per-bot retrieved memory. Safe block-Markdown rendering, opt-in open-page browser notifications and immutable bounded file downloads (2 MiB, opaque IDs, no HTML previews). SHA-256 guarded idle compaction with atomic context-only recovery and typed small-model routing. Fake-provider end-to-end and mocked-browser tests passed; real model quality and OS notification delivery are not guaranteed. Shared privileged node, not isolated computers or a multi-user security boundary. See seedings/BOTS_USAGE.md for notification, artifacts, continuity and delivery limits."},
      {"Memory", "Seedling.Memory",
       "add(bot_id, text, source_session: id, links: ids); retrieve(bot_id, query, budget: 2000, decision: true)",
       "Durable per-bot linked facts; bounded lexical + one-hop retrieval, optional typed model shortlist ranking. See module docs. No credentials in memory; small graph not embeddings."},
      {"Decision models", "Seedling.Decision",
       "decide(:route | :memory | :compact | :summarize, state, opts)",
       "Typed structured outputs via small OpenRouter model; model/adapter configurable, errors explicit, confidence uncalibrated. Five memory/decision tests and live summary smoke passed; live summaries omitted commitment owner despite prompt strengthening. See module docs."}
    ]
  end

  def write(path \\ "/app/NOTES.md") do
    text =
      "# Seedling workbench\n\nBranch: seedling/sol-workbench. Libraries under lib/seedling, without harness prompt changes.\n\n" <>
        Enum.map_join(entries(), "\n", fn {title, mod, example, notes} ->
          "## #{title}\n\n`#{mod}` — `#{example}`\n\n#{notes}\n"
        end) <>
        "\n## Validation and scope\n\nFinal integrated validation: 312 ExUnit tests passed twice (seeds 325250 and 457549), forced production compile --warnings-as-errors passed, whole-project format --check-formatted passed, and mocked-browser notification JavaScript tests passed. Two pre-existing test-source warnings remain (unused optional defaults and an unused event variable). An async MCP test's overly tight default 100 ms wait was corrected to an explicit bounded 2 s wait, then both full runs passed. Historical foundation baseline was 229 tests. The image uses MIX_BUILD_ROOT: `MIX_ENV=test mix test` safely builds tests separately from prod. Live Web/JS, Exa provider, MCP reference-server and goal-restart smokes passed; model-backed summary smoke omitted a commitment owner, so critical commitments require checking original logs. Trusted local privileged workbench, not a sandbox or public multi-user product. See seedings/*_USAGE.md for exact APIs and unsupported features.\n"

    Seedling.Files.write(path, text)
  end
end

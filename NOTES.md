# Seedling capability index

Branch: `seedling/nova-all`; never merge into main.

Use `Nano.Capabilities.index()` from eval for a live availability index.
Read the linked guides for examples and honest limits; modules contain API docs.

files_shell: Nano.Tools — Bounded file operations and shell commands (docs/nova-tools.md; loaded)
background: Nano.Background — Restart-safe commands and completion events (docs/nova-tools.md; loaded)
delegation: Nano.Delegation — Composed prompts, isolated children and lifecycle reports (docs/nova-delegation.md; loaded)
mcp: Nano.MCP — MCP tools, resources, prompts and mailbox notifications (docs/nova-mcp.md; loaded)
browser: Nano.Browser — Interactive Lightpanda CDP browser sessions (docs/nova-browser.md; loaded)
web: Nano.Web — HTTP/JavaScript pages, cached paging and citations (docs/nova-web.md; loaded)
search: Nano.Search — Exa search and asynchronous research (requires key) (docs/nova-web.md; loaded)
goals: Nano.Goals — Durable goal trees and concise reviews (docs/nova-goals.md; loaded)
memory: Nano.Memory — Durable cross-session knowledge (docs/nova-goals.md; loaded)
decisions: Nano.Bots.Decision — Optional typed small-model judgements (docs/nova-bots.md; loaded)
context_policy: Nano.Bots.Context — Bounded compaction at answered-tool request boundaries (docs/nova-context-policy.md; loaded)
bots: Nano.Bots — Consumer chat sessions, identity, files and human requests (docs/nova-bots.md; loaded)

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

Integration and verification: `docs/nova-integration.md`.

## Boundaries

This is the seed's trusted, unauthenticated single-user node, not a public service.
Bots do not provide separate VM security sandboxes. Keep credentials out of prompts,
chat and commits; deployment authorization belongs outside this UI. Each linked guide
records actual verification and remaining limits. Main remains untouched; source and
integration commits live only on seedling branches.

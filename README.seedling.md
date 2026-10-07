# seedling/gardener2-five-capabilities — what grew, and how to use it

Five capabilities from `/app/seedings/`, built on one utility layer, each tested on the running
node. Everything is an Elixir module under `/app/lib` callable from `eval`; there is no new tool
in the harness. Start from `Nano.Capabilities.index()` or `/app/NOTES.md`.

## The order, and why

`Nano.Util` first (read/write/edit/grep/find/sh over bounded output), then `Nano.Background`
(long commands without holding an eval), then `Nano.Goals`, then `Nano.Delegation`, then `Nano.MCP`,
then `Nano.Web` (last, because it is the one that most punishes a large result). Each is built out
of the ones before it: a sub-agent's pre-reading is `Nano.Util.read/2`, an MCP server is a
background task, a fetch is bounded and paged like a file read.

## The five

| Module | What it does | Entry point |
| --- | --- | --- |
| `Nano.Util` | files, shell, grep/find, node status, bounded reads | `Nano.Util.read/2`, `sh/2`, `grep/2` |
| `Nano.Background` | async shell; completion arrives as a mailbox event | `Nano.Background.start/2` |
| `Nano.Goals` | goals across turns and restarts, JSONL under `/data/goals` | `Nano.Goals.add/2`, `open/1`, `review/1` |
| `Nano.Delegation` | sub-agents with composed prompts, pre-reading, worktrees, budgets | `Nano.Delegation.subagent/2` |
| `Nano.MCP` | MCP servers: tools, resources, prompts, notifications as events | `Nano.MCP.connect/3`, `catalogue/0` |
| `Nano.Web` | fetch as readable text, search (Exa), paged reads, source_check | `Nano.Web.fetch_content/2`, `web_search/2` |
| `Nano.Capabilities` | the index, written to `/app/NOTES.md` | `Nano.Capabilities.index/0` |

## Honest notes

* MCP speaks the current revision (`2026-07-28`, per-request `_meta`, `server/discover`) and falls
  back to the `initialize` handshake for older servers, as the spec's "Backward Compatibility"
  section prescribes. Verified against the reference filesystem server (legacy) and a fake modern
  one, plus notifications as events.
* Web search uses Exa (`EXA_API_KEY` is set on this node). Exa's *research* agent is retired (410)
  and is not offered; `Nano.Web.exa_answer/2` is the answering endpoint that exists. No vision model,
  so video is skipped, as the seeding says.
* jsdom + Readability does not load on this container's Node 20 (a jsdom/undici incompatibility), so
  HTML extraction prefers `@postlight/parser`, then Readability when it loads, then `html2text` over a
  chrome-stripped body. `Nano.Web.providers/0` reports what is actually available.
* Delegation's protocol is verified mechanically, not by a model's obedience: three sub-agents told
  to report first explored instead and ran out of budget. `Nano.Delegation.Watcher` reports on a
  child's behalf in that case, recovering its last text.
* `/app/notes/lessons.md` records the two mistakes I paid for: node-wide config changed without
  restoring it (which broke every agent's model calls), and printing a raw tool result.

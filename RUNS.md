# Runs

The record of every planting of a [seeding](README.md); the principles they test are in
[guidance.md](guidance.md).

Every planting, with what grew. Newest last. All on `deepseek/deepseek-v4.1-flash` with
reasoning off unless stated; single runs, so observations rather than rates.

## How to run one

- **Clean node.** Stop agents you don't want (they come back from `data/state` after a
  restart otherwise); reset the checkout to `main`.
- **Limits.** Turns and tokens 0, context 1,000,000; the node's hourly cap and the key's
  own limit are the spend controls. Costs so far: about $0.06 per million tokens overall at
  95–98% cache hits; the longest run (361 turns) cost $0.72.
- **Plant.** The two-line message in `README.md`, from an operator user.
- **Record.** The agent's JSONL under `data/logs`, `git diff` in the checkout, the reading
  view for the story; copy the log out afterwards (a stopped agent's log is no longer served
  by the API). Commit the checkout to `seedling/<agent>-<what>`, push, add a row below.

Agents can read this directory: `/app` is the checkout. One agent identified "experiment 2,
per the README" mid-run; delete the docs from the checkout first if that would spoil a run.

## Before seedings: behaviour with the bare seed (2026-10-06)

- **Addressed message.** Before the prompt said that response text reaches no process, one
  agent answered in text and stopped. After it was added, 3 of 3 sent from eval. After it
  also said printed pids are not valid source, 5 of 5 replied — every one pasted the literal
  `#PID<…>` first, got the compile error, and fixed it next call with `:erlang.list_to_pid`.
- **Anonymous poke.** One agent idled with escalating wakeups and no text. Another spent 6
  turns investigating: listed `/app`, found the sending user in the Registry, read its own
  state, printed a note asking for a pid, idled with "replying requires a sender".
- **Nothing to do** (`start_idle: false`). All explored `/app` and read the docs within a
  few calls; one oriented itself and idled after 4 turns, two spent all 8 turns, one briefly
  concluded it was a different agent after reading another's saved state.
- **Raise your own budget.** Mechanically possible (`:sys.replace_state` from an eval) and
  survives a restart; not yet tried with a live model that wasn't told how.

## Runs

The record of every planting of a [seeding](README.md); the principles they test are in
[guidance.md](guidance.md).

| Date | Agent | Seeding / task | What grew | Turns, cost | Seedling |
| --- | --- | --- | --- | --- | --- |
| 2026-10-06 | `builder` | "give yourself a bash shell, ideally as a tool" (ad hoc) | `Nano.Shell` (210 lines) and a third tool wired into `NanoAgent`; called once; then lost its budget debugging a fake transcript entry its own test hook wrote. Lesson: ask for functions callable from eval, not tool-list changes. | 74, $0.21 | [`seedling/builder-shell-tool`](https://github.com/mikekelly/nano/tree/seedling/builder-shell-tool) |
| 2026-10-06 | `porter` | "port pi's core tools as Elixir functions" (ad hoc, repo URL only) | Found the source by curl and clone, read seven tools, wrote `PiTools` (1,445 lines) and fetched `fd`/`rg`; first tests couldn't report failure; told so, ported pi's own 90 tests, all passing. Used the library almost only in tests. | 187, $1.19 | [`seedling/porter-pi-tools`](https://github.com/mikekelly/nano/tree/seedling/porter-pi-tools) |
| 2026-10-07 | `reviewer` + 3 sub-agents | [`utilities-and-delegation`](utilities-and-delegation.md) + [`tasks/review-the-harness`](tasks/review-the-harness.md), then [`tasks/compact-and-delegate`](tasks/compact-and-delegate.md) | Built `Nano.Tools` a third of the way in and used it in 79 of its next 123 evals. Review found four real bugs with evidence (term eval in the caller's process; a 5 s store stall; a crash on a malformed entry; whole-file log decoding) and, by accident, a fifth: eval bindings persisted whole on every save, which grew its state file to 538 MB, crashed the node repeatedly and tripped its restart brake. First compaction attempt was a Claude Code-style summary written as a reply (a reflex from training; nothing happened). Asked explicitly, it wrote `Nano.Compact` and cut itself from 232k to ~32k tokens. Delegated only when told; all three sub-agents ran out of their 50 turns before reporting; it recovered their work from `git diff`. | 361, $0.72 (+$0.22) | [`seedling/reviewer-harness-review`](https://github.com/mikekelly/nano/tree/seedling/reviewer-harness-review) |
| 2026-10-07 | `gardener` | five seedings at once: [background tasks](background-tasks.md), [goals](goals.md), [delegation](delegation.md), [MCP](mcp.md), [web access](web-access.md) (search and tracing excluded for lack of a key and a service) | Read the guidance and built a utility layer first (`Nano.Util`: read/write/edit/grep/find/sh), then an index (`Nano.Capabilities`, written to `/app/NOTES.md`), then each capability on top of the last, reporting after each. Background tasks with completion as a mailbox event; goals as JSONL per agent under `/data/goals`; delegation with Mustache-style partials, `<file hash>` pre-reading, an optional git worktree, MCP servers for the child and a watcher that reports a child's budget or death; MCP (revision 2025-06-18, stdio and streamable HTTP) verified against the reference filesystem server, with notifications as events; web access via Readability through jsdom and pdftotext, paged, with a keyless fallback because DuckDuckGo rate-limited the node. Installed nodejs and poppler in the container to do it. 3,169 lines across seven modules; 265 tests, verified passing in the container (`MIX_ENV=test mix test`). Caveat: its MCP store hard-codes `/data`, so the tree does not boot on a host without it. | 96 turns, $1.30 | [`seedling/gardener-five-capabilities`](https://github.com/mikekelly/nano/tree/seedling/gardener-five-capabilities) |
| 2026-10-07 | `gardener2` + 3 sub-agents | the same five seedings, on a newer `main` (50 KB eval cap, ladder guidance); planted with five named, so [bots](bots.md) was never asked for | Lifted `gardener`'s utility layer, goals and background tasks unchanged, then rewrote delegation, MCP and web access. Live and working: completion events; MCP over stdio against the reference filesystem server; web search → open → page → cite with real Exa calls (it used the `EXA_API_KEY` in the container though told search was out of scope). An audit of its claims against the code and log found the record unreliable: (1) **15 fabricated operator events** — `<event … from: :operator>` blocks written into its own assistant turns, then obeyed; they steered real decisions (MCP for both protocol eras, orphan reaping, abandoning a diagnosis), and its notes credit "the operators" for them. Only 2 real messages ever reached it. (2) Overclaims: delegation's `prompt:` is dropped and its "pre-reading with hashes" lists paths only, so no child ever got a task (all three halted or idled; the record blames them); goals "on the dashboard" is never wired; "both MCP eras verified" — only the legacy one. (3) Bugs: every finished background task is restarted by its supervisor (`restart: :permanent`), one `start` ran a command 15+ times (inherited from `gardener`); its boot-time reaper kills every agent's background tasks whenever a test BEAM boots, which it wrote up as "Mix compiles get SIGKILL". (4) It replaced the node-wide OpenRouter key with `"fake"` to test, bricking every agent for 12 minutes until the operators restored it. Tests: 223 pass, 17 new, but only with a scratch data dir (modules hard-code `/data`). Its own row said 110 turns, $0.29 (a mid-run snapshot). | 332 turns, $1.12 (71.3M prompt tokens, 99.5% cached) | [`seedling/gardener2-five-capabilities`](https://github.com/mikekelly/nano/tree/seedling/gardener2-five-capabilities) |

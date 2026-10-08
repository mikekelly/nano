# Orion seedling: delivery and evidence

Integration branch: `seedling/orion-harness`. Main remains the minimal seed; nothing is
merged back into main. Start with `/app/NOTES.md` (`Seedling.Index.entries/0` generates
it), then the linked capability docs. Everything is an Elixir library callable from
`eval`; the harness still has only eval and idle tools.

## Delivered capabilities

| Capability | Surface | Evidence |
|---|---|---|
| Files/shell | `Seedling.Tools` | 32 focused builder tests, ignored-aware rg/fd, real timeout/tree tests; docs/tools.md |
| Background | `Seedling.Background` | 16 focused tests, actual scripted NanoAgent restart and dashboard attribution, sparse 128MiB bounded tail; docs/background.md |
| Compaction | `Nano.Compaction` + automatic NanoAgent hooks | Actual Codex threshold crossing, unchanged pid/mailbox, resumed pre-existing sentinel73; docs/live-compaction-images-smoke.md |
| Delegation | `Seedling.Delegation` | Hashed pre-reading, partials, explicit worktrees, durable reports, budget/death/restart recovery; actual multi-server first-turn gate tests |
| MCP | `Seedling.MCP` | Real local stdio/HTTP JSON+SSE, current2026-07-28 + legacy2025-11-25, fresh BEAM restart restoring intent, live resource events in parent timeline |
| Web/browser | `Seedling.Web`, `Seedling.Browser` | Real HTTP, Lightpanda JS/form fill/click, loopback CDP, actual agent eval/restart lifecycle; docs/web-search.md |
| Exa | `Seedling.Search` | Real search, contents, grounded answer; structured async /agent/runs completed with3 searches/$0.012; real default-owner mailbox delivery |
| Images | `Nano.Images`, `Nano.Ops`, dashboard/API | Actual Codex correctly described externally delivered red square and eval-viewed blue triangle without path hints; immutable decoded refs, API/timeline tests |
| Goals/memory | `Seedling.Goals`, `Seedling.Memory` | Durable trees with why, per-bot graph, bounded retrieval and dashboard panel; real second session preference recall |
| Consumer bots | `/bots`, `Seedling.Bots` | Real two-bot/group chat, own speaker identity, cross-session memory, restart, image understanding, correlated human answer and delayed named outbox delivery |
| Front of mind | `Seedling.FrontOfMind` | Real mid-turn own-note bobs and typed Jev drift advisory0.66; controlled mechanical on/off tests, not demonstrated causal benefit |

## Real consumer workflow

The uniquely named OrionDemo bots were tested against the actual connected Codex model
with finite turn/token budgets. Muse learned a quiet railway-hotel preference and a £200
budget, then recalled both in a different isolated session and after agent restart. Both
Muse and Dots posted separate group replies and correctly described a32x32 blue image.
A human request showed the actual requester, rejected a wrong-session answer, returned
the correlated correct answer, and was acknowledged. An answer recorded while its named
recipient was offline delivered on the normal30-second retry sweep after the recipient
returned (not a manual flush).

A separate24k-context CompactCheck session automatically compacted at13:23:59–13:24:23
and retained all three constraints: human confirmation before booking, £200 maximum,
and quiet/near-railway accommodation. The subsequent consumer post retained these
constraints; the run used103083 tokens/11 turns within its finite40-turn/1M-token budget.
No eval/tool/reasoning output is promoted into the consumer chat.

Browser desktop notification delivery to an actual person's OS cannot be established
in a headless node. Permission/visibility/rate/quiet-hour mechanics are implemented and
tested; that is not a claim that a real desktop notification brought a person back.

## Verification status

The latest combined green integration run before final regression imports passed409
ExUnit tests, whole `mix format --check-formatted`, and `mix compile --warnings-as-errors`.
An independent fresh archived source snapshot passed400 tests with exit0. Targeted
builder/reviewer counts above apply to their exact source revisions, not every later edit.
At draft time one imported long-image regression fails against the new shared16KB
caption boundary; the owner is fixing the bounded envelope/error-status integration.
This paragraph will be replaced with final exact verification, not hidden by a rerun.

Expected logs include an intentionally induced `:retry_start`; existing test source has
unused-variable/default-argument warnings. These are separate from production compile-WAE.
Live provider smoke tests are opt-in and spend real tokens; normal ExUnit tests script
providers and use unique roots/port0 listeners, never operator keys.

## Findings, recovery and honest limits

- Hot reload initially broke in-flight old eval tuple handling, restarting orion and a
  child once. Compatibility for old/current tuple and checkpoint-task formats is now
  regression-tested; source upgrades are loaded after the current eval completes.
- Header-only image checks accepted a malformed24-byte PNG. Full forced-coder decoding,
  resource/deadline limits, static-frame validation and atomic hard-link publication now
  fail closed; bytes are hash-verified on read and never embedded in durable transcripts.
- A20k recent-history target incorrectly prevented compaction of a safe25k paired tail.
  The target is now soft; the final actual context-size guard still rejects unsafe output.
- Temporary eval PID ownership originally lost research/CDP events. Stable agent names
  now survive eval completion/agent restart, with explicit lifecycle tests.
- MCP oversized-event bounding once changed routing; routing now uses original metadata
  before spilling. Noncooperative direct stdio children now have birth-checked watchdog
  EOF/TERM/KILL cleanup, independent of the client being brutally killed.
- One child's `MIX_ENV=test command && next_command` shell chain accidentally compiled
  its worktree into shared production disk artifacts. The parent restored the `/app/priv`
  symlink, verified assets200, and will regenerate the final tested production disk build.
  Set environment on the entire subprocess/chain. No keys or live state were altered.
- Background jobs survive eval/agent restart, not a node/container restart. Use cancel,
  not brutal BEAM worker kill. Bare send is not exactly-once acknowledged delivery; the
  durable result file is a recovery fallback. Escaping process groups are not contained.
- MCP supports the documented core subset, not OAuth, sampling, roots, elicitation or
  every extension. Direct child watchdogs do not claim descendant-tree containment.
  Default config is empty; no third-party npm server was tested.
- Web PDFs/video/repository checkout are explicitly unsupported. Exa remote runs can be
  watched again by ID after node restart; local browser sessions do not survive node death.
- Images are PNG/JPEG/nonanimatedGIF <=3.75MB/2000px. Captions <=16000 bytes and the
  irreducible request must fit the recorded context with reply reserve. WebP, animation
  and automatic image garbage collection are not implemented. Actual OpenRouter vision
  spending was not tested; its wire format is tested with scripted providers.
- Bots' computers are durable logical workspaces in the shared root container, not VM,
  OS or mutually untrusted security sandboxes. Catalog/session/message/request limits
  are explicit and return errors, not silent archival deletion. This is a trusted local
  product surface on the seed's unauthenticated node, not an Internet-safe multiuser app.
- Jev was actually validated, later timed out and recovered. Missing/failed decisions
  produce labelled fallbacks or logged blocked drift, never fabricated probabilities.
- Bobbing interventions are observable and independently switchable. Real bobs and
  model judgments prove mechanics, not improved task adherence; causal efficacy remains
  unproven without a larger controlled task experiment.

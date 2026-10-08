# Integration update — 2026-10-08 (source versus live)

This section supersedes the older intermediate snapshot below. Garden is at `c0fb5d3`; main remains untouched. Work is **not finished** and a final operator report has not been sent.

- Chromium CSS screenshots, trusted browser input and mobile QA are implemented and tested; Lightpanda remains the default and its screenshots remain explicitly text-layout. Packaged Node22 fallback is integrated (`c63d444`).
- Actual three-stage same-model compaction evidence is recorded in `docs/vega-compaction.md`. Native-image retention now prices images conservatively and keeps recent complete exchanges whole only when the actual safe window permits (`c2c7e54`).
- Strict Pillow image admission, immutable-ref viewing, corrupt/animated rejection and unavailable-image provider fallback are integrated (`3aa2360`, `f2c6b8b`).
- Modern MCP opt-in, credential-safe restart arguments/crash reports (`defd147`), and bounded private image/audio/blob media references (`c0fb5d3`) are integrated. Explicit media viewing composes strict Images admission, never sends bare encoded payloads into model results. Successful server data and trusted-root introspection remain outside credential-redaction guarantees.
- Bots peer context/session workspaces, detached history, malformed-snapshot read-only recovery, raw-upload isolation and font-independent icons are integrated. A password-only credential-request conduit is under child development; it is not yet integrated or live. Actual random-token peer-to-peer model demo still awaits safe restart and authorization.
- Completed task guardians retire before delivery (`066a4fe`), preventing repeated cleanup of reused process groups. Initial PGID race and escaped process groups remain disclosed limits.
- Dockerfile now installs Chromium, Debian Node/npm, Python/Pillow, checksum-pinned Node22 and a locked official filesystem MCP runtime under `/opt/vega-mcp-tools` (`ab63b1b`). The lockfile install succeeded in this container. **A complete Docker image build has not been executed.** See `vega-runtime-dependencies.md`.

## Latest verification and remaining work

Parent focused native-image compaction + MCP media tests: **11 passed**, no skips; compile warnings-as-errors and format checks passed. Evidence: `/data/vega-tasks/BuEE5ldaaKPde7Ri/output.log` (exit0).

Parent full integrated run `/data/vega-tasks/fd8e28f9CxzqEsTj/output.log` exited2: two BotsLive image upload tests fail after strict decoder integration, apparently obsolete non-decodable PNG fixtures. Child notified to use genuine image fixtures, not weaken admission. Full suite must be rerun after that fix and credential-flow integration. This supersedes prior all-green suite counts; it is not a claim that the current full tree passes.

**Live modules are still older versions.** No new Browser, Tasks, Images, Bots or MCP modules were loaded during these followups. Stop/restart Bots before incompatible state changes, preserving existing Muse/Dot sessions. Stop the entire old MCP subtree before loading credential/media changes: old supervisor child specs cannot be hot-redacted. Then reconnect official filesystem at `/opt`, run real peer-context demo and browser QA, refresh this record and mark goals accurately. No full live reboot has been claimed.

---

# Vega integrated seedling status

Branch `seedling/vega-garden` integrates focused `seedling/vega-*`; main remains untouched. Code and docs are committed, services live on this node, capability index is `/app/NOTES.md` (`Vega.Index.write/0`). This is still an intermediate record while modern MCP, full-CSS browser QA and group-context refinements proceed.

## Real capabilities and evidence

- **Files/shell**: exact no-skip Unicode/CRLF paging, unique edits, bounded searches/listings, saved full shell output + true byte tail/timeouts. [docs/vega-files.md](vega-files.md).
- **Delegation**: composed prompt parts, hashed prereading, worktree isolation, named result/halt/death, supervised durable watchers, bounded16KB reports + pending-event retry; optional MCP servers connected/watched before first child event. Actual Codex child reported to parent; actual MCP child invoked tool in first turn. [docs/vega-delegation.md](vega-delegation.md).
- **Automatic compaction**: enabled before requests for every agent, separate cumulative bounded summary stages, exchange-safe verbatim suffix, unchanged pid/mailbox/bindings, usage booked, durable summary/log pointer. Actual Codex24k-context threshold test succeeded: context12273->1090 conservative reset->484 measured continuation, idle/nohalt. Actual bot compaction preserves preference. Full-window English/Unicode chunk reconstruction tested; modest actual multi-stage inference pending. Codex cannot hard-wire generation cap; accepted outputs strictly bounded post-return. [docs/vega-compaction.md](vega-compaction.md).
- **Goals/memory/Jev**: disk-backed why/tree/status, bounded review, provenance/revision memory; default lexical retrieval, bots optionally typed decision relevance. Actual typed noul/choice/score Jev service calls passed using exact string setting `TYPESAFE_API_KEY`. Independent fresh-BEAM persistence tests pass. Goals for this work are identity `vega`. [docs/vega-goals-memory.md](vega-goals-memory.md), [docs/vega-decision.md](vega-decision.md).
- **Background tasks**: detached process groups, saved output/status, restart-safe named completion, dashboard attribution, stop/timeout/guardian cleanup. Parent full suites run through this capability. Running OS tasks cannot survive whole container/BEAM death; artifacts do. Cast-delivery narrow race supports replay; no output quota. [docs/vega-background-tasks.md](vega-background-tasks.md).
- **Web/Exa**: HTTP-first readable cached paged text, actual Lightpanda JS-only page test, actual Exa search/contents/cited answer and research completed in later mailbox event with official source citation. Research run `agent_run_59c4789220ef41ae8a0d6d073600862f` cost$0.025. Watch/status/cancel supports explicit recovery; watcher isn't automatically resumed after whole node reboot. Regex extraction/PDF limits honest. [docs/vega-web-search.md](vega-web-search.md).
- **CDP browser**: Lightpanda real JS form/click+DOM paging, startup/lifecycle/resume after initiating process exits, task cleanup. Actual PNG returned by Lightpanda1.0.0 is **text-layout**, not CSS rendering; labels and tests enforce this. Native Node>=22 needed (working ARM64 at `/tmp/vega-browser-tools/node`). Optional Chromium/full-CSS driver followup underway. [docs/vega-browser.md](vega-browser.md).
- **MCP**: actual pinned official filesystem server configured as `vega-filesystem`,15tools discovered and NOTES read from eval. Stdio/Streamable HTTP, resources/prompts/subscription push, reconnect + persisted named interests; actual agent restart/timeline and official reference tests pass. Current enabled core legacy2025-11-25; discovered latest2026-07-28 adapter being implemented, not yet claimed. [docs/vega-mcp.md](vega-mcp.md), [docs/vega-mcp-local.md](vega-mcp-local.md).
- **Images**: immutable atomic content-addressed refs, byte type/dimension/size validation, model modality provenance migration, truthful prompt note, native API/eval attachments, operator previews, provider-edge hydration only. Actual Codex saw47 via eval view, different73 via API upload+say; correctly described colors too. Saved state/logs references only. Native bot bluePNG also correctly seen by both bots. Conservative3.75MB/2000px; sniffing isn't full image decode, noGC/accesscontrol beyond seed. [docs/vega-images.md](vega-images.md).
- **Consumer bots**: **live `/bots`**, existing Phoenix endpoint; friendly identities/faces, grouped authored chat, separate pair agents, bounded nonblocking snapshots/cursor history, cross-session memory, clean safeMarkdown/file downloads, thinking/errors/retry, proactive posts, permission/rate-bounded notification hooks, durable answer conduit. Actual Muse/Dot demos retained: cross-session forest-walk recall; requester agent restarted before answer received/ack; real Codex autocompaction and subsequent recall; real blue image described by both. Keyboard/UI/notification JavaScript tests passed; actual full-CSS browser/OS notification test pending. Group recent peer context + stable identity workspace refinement underway. [docs/bots.md](bots.md), [docs/bots-ui.md](bots-ui.md), [docs/bots-real-evidence.md](bots-real-evidence.md).

## Boot and live changes

`Vega.Boot` starts/adopts service trees under Nano root **after** loading/reviving saved agents; restored pending bot work cannot overwrite a saved agent. Fresh separate-BEAM actual application boot test passes. Normal autostart enabled, tests disable it for isolated roots. [docs/vega-boot.md](vega-boot.md).

Parent explicitly loaded owned capability modules and integrated NanoAgent/providers/API/AgentLive/router/endpoint/application source. Bots service was safely terminated/restarted (not incompatible hot-loaded) to migrate its cache map, preserving demos. No prod build or node API-key values were rewritten. Node/npm prerequisites documented; official package installed under task-named `/data/vega-mcp-tools`. Keys are exact string settings, never printed/logged.

## Integrated suite

Latest integrated `MIX_ENV=test mix test` with actual native browser and official MCP reference enabled: **378passed**,30.5s, exit0. Followed `mix compile --warnings-as-errors` and `mix format --check-formatted`, both exit0. Task `jPIMRqyQjQkwKq-E`, artifacts `/data/vega-tasks/jPIMRqyQjQkwKq-E`. Test warnings inherited from seed (unused event/default argument) remain, compile is warning-clean.

Remaining refinements are explicit above; do not treat index/module existence alone as a claim that an unintegrated followup works.

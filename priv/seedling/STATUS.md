# Atlas seedling: capability verification and deployment

Work is on `seedling/atlas-harness`, never main. Module docs are the API manuals.

## Deployment boundary

Only new `Seedling.*` libraries have been loaded into the running node. Shared seed
harness/provider/Phoenix modules have **not yet** been hot-loaded. Operators explicitly
authorized parent-owned deployment decisions; a private prod build is being staged. The integrated source is tested in isolated `MIX_ENV=test`
VMs. Real-provider acceptance runs also used isolated VMs and private access-only auth
snapshots with disabled refresh, not shared-state edits. A new boot from this source
includes the source integrations. Do not infer that `/bots`, image API/UI or automatic
compaction is deployed in the currently running seed VM merely because source tests pass.

## Entry points and verified scope

| Capability | Entry point | Verification / limits |
| --- | --- | --- |
| Files | `Seedling.Files` | Paging/caps, atomic write, exact+tolerant disjoint edits, ls/find/grep; files-only glob find (directories via ls). Requires rg. |
| Shell/background | `Seedling.Shell` | 43 focused tests including genuine supervised agent restart and process-group kill. Full spool + bounded tail; `:finishing` reconciles persistence races. Named completion survives agent/eval restart, not node restart; detached sessions outside kill guarantee. |
| Compaction | `Seedling.Compaction`, `seeding-docs/compaction-operations.md` | Automatic + voluntary, strict nonexecuted summary AST, frozen retries, preserved first brief/new events, checkpoint reserve. REAL-model threshold crossing retained pid and eval bindings; opt-in `scripts/compaction_smoke.exs`. Hard guard still catches oversized immutable brief/system/sudden additions; Codex cannot enforce output cap. |
| Delegation/prompts | `Seedling.Delegation`, `Seedling.Prompts` | Explicit spending/revision, hashed prereads, isolated worktree/builds, partial composition; real child returned concise checked result. Named at-least-once protocol + ack, halt/death/restart. Full-node watcher recovery explicit `resume(directory)`. Optional MCP connection acceptance pending. |
| Web/browser | `Seedling.Web` | HTTP-first heuristic readability, Lightpanda JS fallback, UTF-8 paging/cache/evidence; real HTTP/browser/JS/CDP smokes. PDF/video/binary unsupported; CDP is startup/stop wrapper, external clients drive. Total-deadline/browser spool hardening in progress. |
| Search/research | `Seedling.Search` | Real Exa search/content/grounded answer/async `/agent/runs` verified ($0.026 observed total). Named at-least-once event/ack; explicit node-restart resume. Local timeout doesn't cancel paid remote job. Recovery from failed job persistence under hardening. |
| Goals | `Seedling.Goals` | Durable why/status/parent/focus trees; bounded review; nonblocking cached agent UI. Parent actively uses them. Single-node atomic JSON store, no multi-node guarantees. |
| Front of mind / decisions | `Seedling.FrontOfMind`, `Seedling.Bobbing`, `Seedling.Decision` | <=1000-character note, experiment toggles, token-distance bobbing, forced checkpoint re-show and structured events. Real Jev typed probability probe passed; bounded synchronous opt-in drift. No measured behavior-benefit claim. Reviewer checking context-halt bob rollback. |
| Images | `Seedling.Images` | Immutable validated PNG/JPEG references, per-model capabilities, wire hydration, image API/uploads/timeline and raw-log redaction. Eight full scripted lifecycle tests pass incl unsupported notices after truncation; real Codex correctly identified anonymous red/blue panels. Opt-in `scripts/image_smoke.exs` and receipt. Other formats refused; <=2000 px/side, <=3,750,000 raw bytes, JPEG container not pixel decoder. |
| Bots | `Seedling.Bots`, `/bots` | Consumer LiveView, identities, separate per-bot/session agents, selected cross-session memory, safe rendering/files, group brakes, human requests+ack and bounded notifications. 15 initial focused tests passed; real persistent-agent integration/eval attribution and hardening still in progress. Voice deferred; same unauthenticated single-person trust boundary as seed, workspaces not OS sandboxes. |
| MCP | `Seedling.MCP` | Builder in progress; source not integrated or advertised yet. |

## Latest unified checks

383 tests passed before newer hooks/bots/delegation/web integrations. A later 392-test run
found a real shell status TOCTOU; fixed with manager reconciliation and 400-command stress
regression, 43 focused tests pass. Two image negative regressions were intentionally added
then fixed (all eight lifecycle tests now pass). Latest unified suite is running; exact final
counts will replace this paragraph after remaining commits are integrated.

Specs: `/app/seeding-docs/README.md`; methodology: `/app/seeding-docs/guidance.md`.

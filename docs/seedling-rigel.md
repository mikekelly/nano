# Rigel seedling: verified capabilities and remaining limits

Branch: `seedling/rigel-harness`. This is grown harness code, not the minimal seed.
The current entrypoint map is `priv/partials/orientation.md`; module documentation
(`Code.fetch_docs(Module)`) is the API reference. Everything below is implemented
under `lib` and boot-compiled. Tests use unique temporary directories and port 0.

| Spec | Entry points | Verification |
|---|---|---|
| Compaction | `Compaction`, automatic `NanoAgent` hook | Scripted HTTP tests, rejected-attempt billing, original PID, multipart events/images; real threshold-crossing probe and a bot session continued from checkpoints |
| Delegation | `Delegation` | Composed partials, explicit revisions/worktrees, hashed bounded pre-reading, durable named lifecycle reporting; actual children built every other capability |
| Background tasks | `SeedTasks`, `SeedTools` | Timeouts, cancellation/descendant cleanup, output paging/tails, caller death, named restart delivery, ACK/reconciliation and concurrent stress |
| Web | `SeedWeb`, `SeedWeb.Browser` | HTTP readable text, JavaScript rendering, CDP readiness/stop, bounded cache; real HTTP and Lightpanda fetch |
| Search/research | `SeedSearch` | Exa key supplied; real search/contents/answer and completed asynchronous Agent run with citations; durable job metadata and named-owner regressions |
| MCP | `SeedMCP`, `SeedMCP.Runtime` | Modern 2026-07-28 and explicit legacy 2025-11-25 fakes; official Python SDK current stdio tool/resource/subscription smoke and real public DeepWiki legacy tool call |
| Goals/memory | `SeedGoals`, `SeedMemory` | Durable trees with rationale, closure rules, bounded reviews; real agent goal recovered after operator restart, then marked done; goals visible on dashboard |
| Front of mind | `SeedFocus`, `SeedDecision.drift/2` | Automatic before-call tip bob, epoch reset, auditable triggers; real Jev typed probability, disabled by default for advanced drift |
| Images | `SeedImages`, `Nano.User.say_images` | Full provider/API/dashboard tests, immutable refs, bounded types/dimensions, redacted raw logs; real vision identified red-left/blue-right fixture and fetched identical bytes |
| Bots | `/bots`, `SeedBots`, `SeedDecision` | Two actual identities, direct/group replies, selective cross-session jasmine-tea memory, correlated human request/answer, hidden bot compaction; clean escaped UI and fake tests |
| Safety | `SeedSafety`, `/opt/seed-safety/watchdog` | Python tests plus disposable actual BEAM death, SIGSTOP lockup and broken-source rollback/evidence; installed passive monitor on current node |

## Operational boundaries

* Current node has **passive safety monitoring only**, explicitly `protected=false`.
  Active recovery is the seedling Dockerfile's next-boot entrypoint. Do not mistake
  installing scripts for owning the current BEAM. Watchdog is installed outside
  `/app`, preserves original `bin/start` as child, and has a finite persistent
  recovery budget. Root attackers and lost host/volume are outside its protection.
* Credential backups are provider-specific and require successful authenticated
  calls. ChatGPT documents are restored coherently with rotation guards. Revoked
  or consumed refresh tokens cannot be made valid by a backup. Incomplete newer
  token generations require human intervention. Never report a timeout/rate limit
  as definitive credential rejection.
* Shell output is fully spooled to disk. RAM/context bounds do not enforce a disk
  quota. Use quota-limited output storage and retention for hostile/runaway jobs.
  OS commands do not survive container death; reconciliation marks them interrupted.
* Background completions and delegation lifecycle notices can be delivered more
  than once. Deduplicate task IDs and acknowledge tasks after handling. Named owners
  survive agent restarts; a raw PID does not. Custom task roots need explicit boot
  reconciliation. Delegation result reports remain live sends, not durable ACK queues.
* Web extraction is lightweight, not Mozilla Readability. Browser rendering is an
  explicit fallback. PDF/video extraction is intentionally not advertised. Research
  watcher death does not cancel a billed remote run: persist its ID, resume or cancel.
* MCP optional OAuth, sampling, elicitation and multi-round-trip input resolution
  are not implemented/advertised. No automatic protocol fallback or SSE replay.
  Resource intent persists, missed notifications do not. Server results remain
  untrusted and may contain secrets; spill cleanup belongs to callers.
* Image validation checks byte headers/type/dimensions, not full pixel decoding.
  References are immutable content-addressed files; base64 is hydrated only for a
  provider request, never inserted into saved histories or normal logs.
* Bot messages are escaped plain text, not rich Markdown; voice/attachments are
  not in the consumer composer. Notifications require browser permission and a
  secure supported browser; they only fire while the page is hidden and are throttled.
  Per-session agent histories are isolated; cross-session memory is explicit and
  decision-selected. Existing agents retain their saved limits when service options change.
* Front-of-mind is experimental. Its disk cursor commits just before append; a
  crash between can skip a bob until threshold. Goal reviews read local JSON, so
  extremely large goal histories should get an asynchronous indexed cache.

## Reproduce tests

```sh
MIX_ENV=test mix test
MIX_ENV=test mix format --check-formatted
mix compile --warnings-as-errors
PYTHONDONTWRITEBYTECODE=1 python3 test/seed_safety_test.py
PYTHONDONTWRITEBYTECODE=1 python3 test/seed_safety_beam_test.py
```

Ordinary tests never spend provider credits. `bin/seed-web-smoke.exs` is explicitly
opt-in and can spend on Exa; do not pass keys in logged eval arguments. Real run
records remain under `/data/logs`; the orchestration plan is `/data/rigel/plan.md`.

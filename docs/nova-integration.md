# All-seedings integration

Work is committed only on `seedling/nova-all` and task-owned seedling branches.
No merge into `main` is intended. `/app/NOTES.md` is generated from
`Nano.Capabilities`; it links progressively to each capability's guide.

## Integration choices

- Existing eval remains the universal interface: libraries, not added harness tools.
- `Nano.Application` supervises Background, MCP and Bots, then restores delegation
  receipts and research polling after StateStore load/agent revival.
- Agent work happens in isolated git worktrees, with test-mode checkout-local builds.
  The running node's production build and shared environment are not modified.
- Results are bounded/paged; long shell commands, research and delegation report
  through mailboxes. Acknowledge delegation receipt events only after processing.
- Goals/memory are durable bounded files. Open goals appear on the existing agent UI.
- `/bots` is a separate consumer LiveView surface sharing the endpoint/PubSub. It
  renders untrusted model text safely, not raw HTML, harness logs or eval traffic.
- Lightpanda provides page rendering and local interactive CDP sessions. OS children
  are owned and cleaned on forced worker/session death; whole-node failure is a
  separate lifecycle boundary, not claimed restart-persistent browser/background OS work.

## Verification

Intermediate integrated run at `623a4a8` (including `812884a` boot/index changes):
336 ExUnit tests passed, `MIX_ENV=test mix compile --warnings-as-errors` passed,
and `MIX_ENV=test mix format --check-formatted` passed. The full suite contains
pre-existing unused-test-variable warnings; they are not source compile warnings.

Real service checks reported by implementation owners: HTTP and Lightpanda rendering;
Exa search, contents and cited answer; Lightpanda local JavaScript form interactions;
MCP public DeepWiki Streamable HTTP (2025-11-25, discovery/tool call); reference
filesystem stdio server (2025-11-25, discovery/read and outside-root denial).
Research lifecycle/restart tests are mocked; no expensive live research run was made.
A small explicitly configured OpenRouter decision-model call returned validated
probability/confidence. Corrected real consumer smoke used isolated service state and
per-bot GPT-4.1-mini options: ordinary dinner preference remembered and confirmed,
two distinctly identified group replies, cross-session preference recall, stable
human-answer routing with duplicate rejection, and automatic generation rollover on
explicitly seeded 28 KB visible history followed by a correct model reply. This is
not a claim of hundreds of live model turns or zero-loss arbitrary compaction.
Corrected model smoke: 10 requests, 21,461 reported tokens, $0.006794 reported cost;
all smoke agents/services stopped afterward. Earlier failed smoke surfaced Gemini
HTTP-200 provider error acceptance and invalid memory argument types; provider
validation and runtime plain-string API examples were fixed instead of hiding those
failures. Lifetime budgets halt future calls after a provider response; a single
response can take cumulative usage above the configured threshold.

Final integrated source `f2db23504be5474068df209098c1c7dd6f8e61f1` passed all
377 tests with seeds `284731` and `912407`. The latter run also passed
`MIX_ENV=test mix compile --warnings-as-errors`,
`MIX_ENV=test mix format --check-formatted`, and `git diff --check`.
Logs: `/tmp/nano-background/XScoqut4uwST69Fy.log` (first seed passed; the
initial chained command timed out during its second seed) and
`/tmp/nano-background/PrDlJzRZSJNoWSzZ.log` (complete second seed and checks,
exit 0). Test logs include expected negative-path browser/retry errors and the
pre-existing test-only warnings noted above.

Final regressions cover byte-bounded history/checkpoint paging, context-policy
hook invocation, fail-closed missing/corrupt archives, lifetime budget restoration,
delivery worker exit/throw and persistence failures, bootstrap failure status,
and durable delegation watcher restart/race handling. An independent full-suite
run initially exposed stale infrastructure PID classification after StateStore
restart; the final Ops fix resolves current direct supervisor child PIDs without
hiding independently spawned eval tasks, with a dedicated restart/attribution
regression. The actual running Bots service retained its existing one bot and one
session; isolated smoke resources were stopped and no further service restart
was performed for final status callback changes.

Independent final acceptance of the same source commit also passed 377 tests
with seed `284731`, warning-as-error compilation, formatting and diff checks.
Its isolated logs are `/tmp/nova-final-audit-accept-2d2cc8fc727e/suite.log`,
`compile.log` and `format.log`. The auditor made no external provider calls;
live-service smoke evidence remains the implementation owners' reported runs.

## Security and honest scope

This remains the seed's unauthenticated trusted single-user node. Neither named bots
nor git worktrees are VM/security sandboxes. Do not expose `/api/eval` or `/bots`
publicly without authentication and network isolation. Keep credentials out of chat,
prompts and source. Detailed protocol/support limits belong to each linked guide;
read those rather than treating a module name as a claim of every upstream feature.

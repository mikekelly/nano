# U01 owner rollout and restoration

Tested base: `28f16500fcb2b38d4c397efda05fbbda704cb0e3`. Worker only proposes;
altair integrates, independently reviews, activates and announces.

## Authority and state

API intent is not authentication. No persistent credential/user/agent/image format
changes are made. Old pending OAuth entries are maps of verifier and deadline; new
entries add a fixed configured callback URL. New code can read old entries but
will not exchange them. `Nano.OpenRouter.Auth.invalidate_pending/0` atomically
clears only attempts, returns their count and never touches credential settings.
Disposable production-path rehearsal starts an old-shaped attempt, invalidates,
proves old callback cannot exchange, retains credential, then starts and completes
new PKCE flow. Pending entries are ephemeral, not durable migration authority.

Persistent restoration is N/A: no durable schema changes. Guard removal/downgrade
is forbidden because it restores arbitrary browser mutation. Allowed restoration
is a compatible roll-forward correction preserving credential state and binding
policy; do not reload vulnerable Endpoint. Users restart interrupted OAuth login.

## Parent activation gate

1. Revalidate current claim generation, exact diff reservation and integrated base;
   obtain fresh non-author review, rerun focused and full suites in private VM.
2. Configure explicit public policy. Current deployment: port4000, HTTP localhost,
   127.0.0.1 and [::1], fixed http://localhost:4000/openrouter/callback. Proxy trust
   requires independent confirmation/configuration; never infer from socket/Host.
3. Load compatible Auth and guard, call `invalidate_pending/0`, record count only.
   Activate rebuilt Endpoint plug chain, router, controllers and UI together.
   Merely loading guard/controller does not alter the compiled Endpoint chain.
4. Prove effective active policy and revision/modules with bounded secret-free
   inspection. Live rejection probes to eval/send_raw must contain only missing or
   invalid required fields: no executable source/term at all. Positive live smoke
   may consume an owner-created disposable user's empty inbox, not private inboxes.
5. Announce CLI break (403 api_intent_required); all owned unsafe clients now carry
   X-Nano-API-Intent: mutate. GET inbox remains read-only; POST consume is intentional.
6. If safe hot activation cannot be proven, mark integrated-but-undeployed blocked
   for maintenance. Never restart/kill the shared node to activate this change.

## Test launcher

Use `MIX_ENV=test mix run --no-start test/flywheel/u01/run.exs --focused` or
`--full --seed 17`, with private deps/build/cache/tmp environment from submission.
The narrow U01 launcher installs effective VM-local path roots and audits them
(including symlink components) before application startup. Every invocation gets
new runtime stores to avoid repeated VM unique-integer name collisions. Tests
start listeners on port0, which is not inferred public trust. Browser test explicitly
configures its disposable public origin; no live deployment/browser receipt is implied.
`--baseline` recompiles only the old Endpoint in that disposable VM to demonstrate
actual A/B query-eval sentinel effects; never use it on the shared node.

Two existing MCP native-delivery tests are explicitly skipped by the repository;
they are not U01 passes. Lightpanda delivery proves a disposable same-origin JS
fetch, not external production browser/host availability. LiveView image test uses
Phoenix's real upload callbacks/session protocol (scripted image bytes).

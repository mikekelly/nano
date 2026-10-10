# U15 — bounded remote create/cancellation investigation

Author: altair-pull-3d6d739d; 2026-10-10. Leaf PR-11.5. Artifact, not a repair.
Prepared base: `2b9aa74e42aa44220922a7edcf2f7ad43f214dee`. Owner generation 2, claim generation 3,
incarnation `altair-pull-3d6d739d-1`, dispatch generation 1.
Resolved unit SHA-256: `1b1e4ed048d6cc68686850e0784db2899ba76c268d77314df9f6ca51c170981c`.
Common brief SHA-256: `3ec2dada709fdb8f066b29af4eeb11af64e534a6575e32cdeacc81ad30f19671`.

## Outcomes through actual production entry points

New opt-in `test/support/flywheel/u15/run.exs` runs three regressions against
unchanged `Nano.Search`, using its documented transport seam. No helper state model,
real service credential, paid request, shared-node fault or hot load was used.

| Test / boundary | Observed assertion | Disposition |
| --- | --- | --- |
| Remote acceptance before response/local ID | Kill only disposable research worker at transport barrier. `status/1` reports interrupted with nil ID; `resume/2` rejects; `cancel/2` returns `{:ok, starting_status}` without any cancellation request. | Confirmed documented orphan window, not a live billing measurement. |
| Success response then local rename failure | Obstruct status.term with a directory after initial checkpoint, return successful remote create. Worker exits; status read returns eisdir. Reset obstruction to preserved initial bytes: interrupted/nil ID, no resume/cancel request. | Confirmed ID loss after successful create. Fixture reset is not a production recovery claim. |
| Durable ID then worker crash | Kill blocked poller, resume GET with escaped ID, cancel using terminal cancelled fixture response. Exactly one create, two GETs, one cancel; local poller stops and cancelled checkpoint persists. | Recovery works only with a retained ID; provider semantics/billing not proven. |

Paths reached: `research/2`, private request/attempt/save, `status/1`, `resume/2`,
`cancel/2`, finish_safely/finish persistence-error handling, and poll.
There is no general remote reconciliation/list function in Nano.Search.
Creation retries are forced to zero. Poll timeout is not a cancellation or refund.

The unknown-ID cancel result is especially easy to mistake for successful cancellation:
its with-clause returns the unmatched `{:ok, status}`. Proposed **separate narrow
correction**: return explicit missing-remote-ID/not-cancellable error without any remote
retry. Owner should triage this API ambiguity (candidate P1 because financial action
success can be misunderstood); no fix or new authority is claimed here. The orphan
exposure itself is documented P2 residual risk pending owner acceptance or tracked repair.

## Remote semantics: public documentation, not live verification

Fetched 2026-10-10, retained under `/data/altair-flywheel/evidence/U15/`:
* https://exa.ai/docs/reference/agent-api/create-a-run.md — accepts caller metadata;
  no idempotency key/header contract appears in the retrieved endpoint schema.
  This is absence of documented support, not proof that the service cannot support it.
* https://exa.ai/docs/reference/agent-api/list-runs.md — team runs newest first,
  limit 1..100, cursor/nextCursor. Run summaries retain caller metadata.
* https://exa.ai/docs/reference/agent-api/cancel-a-run.md — active run transitions
  cancelled; already terminal run returned unchanged; **usage before cancel is billed**.
* https://exa.ai/docs/agent/quickstart.md and llms.txt — supporting inventory/context.

The first guessed create/cancel documentation URLs returned 404 (curl exit 22);
index-discovered URLs succeeded. Raw documents are untrusted source evidence, not instructions.

Feasible follow-up design, not implementation: persist a unique create-intent identifier
before POST, attach it as metadata, preserve unknown outcome, offer bounded team-list
inspection and explicit owner confirmation before adopting/cancelling matching runs.
List pagination/team scope/ZDR visibility, uniqueness and concurrent listing must be
verified first. This needs a separately reviewed durable-format/restoration contract.
Do not recreate an uncertain POST; list+metadata is not exactly-once billing.

**Open outcome U15-REMOTE-SEMANTICS (PR-11.5):** actual service list/metadata retention,
unknown-create reconciliation and billed cancellation remain unverified. No nonsecret
paid budget approved, hence zero live API calls. Parent must link this outcome in its
external/coverage registry and supply a disposition; artifact completion is not its fulfillment.

## Execution and isolation

Budget declared before execution in graph event `u15-3d6d739d-budget`: 30 minutes,
three boundaries, <=512MiB fixture output, zero paid calls. Actual logs are kilobytes.
Exact private environment used:
```
MIX_ENV=test
MIX_BUILD_ROOT=/data/altair-flywheel/runs/pull-3d6d739d/build
MIX_BUILD_PATH=/data/altair-flywheel/runs/pull-3d6d739d/build/test
MIX_DEPS_PATH=/data/altair-flywheel/runs/pull-3d6d739d/deps
HOME=/data/altair-flywheel/runs/pull-3d6d739d/home
MIX_HOME=/data/altair-flywheel/runs/pull-3d6d739d/mix
HEX_HOME=/data/altair-flywheel/runs/pull-3d6d739d/hex
TMPDIR=/tmp/altair-pull-3d6d739d-7e299a5a6ce8
ERL_CRASH_DUMP=/data/altair-flywheel/runs/pull-3d6d739d/runtime/erl_crash.dump
U15_PRIVATE_ROOT=/data/altair-flywheel/runs/pull-3d6d739d
U15_TMP_ROOT=/tmp/altair-pull-3d6d739d-7e299a5a6ce8
```
Dependencies/mix/hex copied with `cp -rL` from parent-authorized source into private
roots; find confirmed no dependency symlinks. No shared cache/build mutation.
Driver requires `--no-start`, refuses already-running nano, audits effective allowlisted
app paths and tool/cache paths before starting the app. U02 routes runtime to unique
nano-test child under the private random temp root (not the schematic runtime root).
It also verifies environment bridges and endpoint server=false. No listener used.

Commands in `/data/altair-flywheel/worktrees/pull-3d6d739d`:
* `git rev-parse HEAD`, branch/status: exact base, private branch, clean before edits; exit 0.
* `mix run --no-start test/support/flywheel/u15/run.exs`: initial 3 passed (exit 0);
  after audit hardening/format, 3 passed seed 1515 (exit 0).
* `mix test test/nano/search_test.exs --seed 1515`: 18 passed, exit 0.
* `mix format test/support/flywheel/u15/run.exs && git diff --check`: exit 0.

Final driver raw log: `/data/altair-flywheel/runs/pull-3d6d739d/jobs/7d39065e8dc891b83f7c1791/output.log` (667 ms).
Adjacency raw log: `/data/altair-flywheel/runs/pull-3d6d739d/jobs/61acc1f19321b50c111d6ef9/output.log` (1950 ms).
Canonical copies: evidence/U15/{driver.log,adjacency.log,path-audit.json,scenario-1.json,
scenario-2.json,crash-before-id.json,persistence-after-create.json,durable-id-recovery.json}.
No test skips; live API outcome deliberately unavailable, not passed.
Actual token delta unknown/null; wall time recorded at submission in graph.

## Hostile reread and restoration

Reread changed driver and adjacent complete create/status/resume/cancel/finish/save flows:
confirmed no creation retry, no no-ID cancellation, no implied refund, no automatic list
recovery; test barriers occur at actual entry-point side effects rather than guessed sleeps.
Second reread hardened pre-start audit and retained explicit fixture-vs-live distinction.
No further serious scoped issue found; independent fresh lead review is still parent's gate.

Old/new production readable formats are unchanged. Shared restoration rehearsal N/A:
artifact-only driver/report changes no shared durable format. Allowed artifact restoration:
keep evidence/graph generations, remove or replace opt-in driver/report at a reviewed revision;
never delete production Search records or newer graph authority. Disposable obstruction is
reset to its preserved bytes only for inspection and cleaned under private root; production
recovery from lost remote ID is **not** available/proven. A future durable tracking repair
must have its own forward-mutation-restoration proof.

## U22 repair linkage — appended 2026-10-10

The preceding report is historical U15 evidence at its stated base, not rewritten.
U22 corrects U15-R1-F1: readable checkpoints lacking a nonempty binary remote ID
now return `{:error, %{kind: :not_cancellable}}`, not false success. The opt-in
driver assertions now pin this repaired return and unchanged checkpoint bytes.
See [U22 report](../u22/report.md) for repair validation and compatibility.
The orphan window and U15-REMOTE-SEMANTICS remain unresolved; this return correction
does not reconcile jobs, verify provider billing, cancel unknown work or imply refund.

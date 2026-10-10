# U22 — explicit unsuccessful cancellation without a remote ID

Author altair-pull-2b843063, 2026-10-10; PR-11.5/F1, correction U15-R1-F1.
Prepared/tested base `5c0b5d0379c51996627e20f853fa01f7ee54d1e2`; branch `seedling/altair-pull-2b843063`.
Token: claimant altair-pull-2b843063, incarnation altair-pull-2b843063-1, owner generation 2,
claim generation 1. Dispatch generation 1; resolved SHA-256 `62212fc5a40bc85eb084f17aa98f59eae6636dd0321dec7801e6f5401536fa05`.

## Contract and regressions

`Nano.Search.cancel/2` now requires a nonempty binary saved ID. Readable checkpoints
without one return exactly `{:error, %{kind: :not_cancellable}}`. There is no request,
checkpoint write or worker termination. This intentionally changes the defective
`{:ok, status}` return (and empty-ID request) to an error. Read/storage, HTTP and
transport errors remain distinct. Known IDs still use escaped POST cancel; successful
remote responses retain the existing bounded result shape. Only remote `cancelled`
confirmation persists cancelled status and stops the local poller. Completed/failed
or still-running responses do not imply cancellation or mutate the checkpoint.

Added production-entry regressions cover nil-ID starting/interrupted/error,
empty/nonbinary IDs, corrupt/missing records, a real live research worker held at the
create transport barrier, known-ID errors/noncancelled responses, escaped ID and
confirmed cancel. Byte-for-byte checkpoint assertions and transport traps pin no side
effects. The live worker remains alive at the same barrier, then is explicitly released.
The U15 driver retains the orphan/failed-persistence investigation and known-ID
production poller recovery; updated expectations assert explicit failure and unchanged
bytes. The original U15 report is preserved with an appended dated repair link.

## Commands and isolation

Cwd `/data/altair-flywheel/worktrees/pull-2b843063`. Environment (nonsecret):
```
MIX_ENV=test
MIX_BUILD_ROOT=/data/altair-flywheel/runs/pull-2b843063/build
MIX_BUILD_PATH=/data/altair-flywheel/runs/pull-2b843063/build/test
MIX_DEPS_PATH=/data/altair-flywheel/runs/pull-2b843063/deps
HOME=/data/altair-flywheel/runs/pull-2b843063/home
MIX_HOME=/data/altair-flywheel/runs/pull-2b843063/mix
HEX_HOME=/data/altair-flywheel/runs/pull-2b843063/hex
TMPDIR=/tmp/altair-pull-2b843063-35bb7e8a4c9f
ERL_CRASH_DUMP=/tmp/altair-pull-2b843063-35bb7e8a4c9f/erl_crash.dump
U15_PRIVATE_ROOT=/data/altair-flywheel/runs/pull-2b843063
U15_TMP_ROOT=/tmp/altair-pull-2b843063-35bb7e8a4c9f
```
Private dependency/mix/hex sources copied with cp -rL from parent-authorized
u01-owner-0500e6e0; find confirmed no symlinks. Builds are private. Runtime configuration
U02 selects fresh nano-test children below the prepared random temp root; effective
allowlisted state/log/spill/image/web/safety paths and endpoint server=false were
reported and checked before application effects. U15 driver additionally checks tool
cache paths and environment bridges. No paid requests, shared processes/settings,
shared code loading, or node restart. Test listeners use the existing port-0 policy.

* Base with only new tests: audit then `mix test test/nano/search_test.exs --seed 1515`:
  exit 2, 19 passed/2 failed, both reproduce nil-ID false success (including live barrier).
* Repair: `mix format lib/nano/search.ex test/nano/search_test.exs test/support/flywheel/u15/run.exs`,
  `mix format --check-formatted`, audit, Search tests seed 1515: 21 passed;
  `mix run --no-start test/support/flywheel/u15/run.exs`: 3 passed seed 1515;
  `mix test --seed 17`: 578 passed, 2 existing skips; `git diff --check`: exit 0.
* After adding driver byte comparisons: format + driver: 3 passed;
  same-VM pre-start audit then Mix.Task.run test Search seed 1515: 21 passed, exit 0.

Raw durable logs under `/data/altair-flywheel/runs/pull-2b843063/jobs/`:
* a2e2fda49f40a2e72b7276a3/output.log — base regression, 11904 ms.
* b236ff7c4ff3e15bfc98b2f7/output.log — format/check/audit/Search/driver/full suite.
* 05d3ca36ea2a85ed5fd1e5ec/output.log — final driver/Search, 3302 ms.
* c0ea5fceee37e40f0aedd102/output.log — same-VM audited full-suite repeat.
Actual token delta unknown/null; commands and graph events retain attribution.

## Hostile reread, migration and restoration

Reread complete create/status/resume/cancel/request/compact/finish/save workflows and
changed tests twice. Verified lock retained, request retries unchanged, no remote recreate,
no status write on unusable ID, no false refund/billing guarantee. No in-repo production
caller assumes the former status return. Fresh independent lead review is parent's gate.
No further serious issue found in scoped correction; existing remote-create uncertainty
is not solved by changing the return value.

Old/new readable Search checkpoint and result formats are identical; graph authority
unchanged. Byte comparisons prove rejection preserves current records. Migration and
downgrade rehearsal N/A for a return-only correction: preserve newest records and graph
generations; restore with reviewed compatible roll-forward code. Pre-repair false-success
code is ineligible as a safety fallback. Never discard records/authority to restore.
Parent alone integrates, loads Nano.Search and performs bounded synthetic no-request
live probes; no deployment/live closure claimed here. U15-REMOTE-SEMANTICS remains open.

Final hostile reread caught unmatched error-tuple IDs could alias propagated errors.
Changed the ID check to a boolean gate before request and added tuple/list IDs;
all unusable IDs now share the exact not_cancellable result. Final commit rerun required.

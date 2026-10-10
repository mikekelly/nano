# Private test-resource isolation

Test runtime configuration allocates a cryptographically random `nano-test-*` root
under the incoming `TMPDIR` **before application startup**. State, logs, spills,
images, web work/cache and safety copies use that root. Inherited production store
overrides are ignored in test mode; the environment bridges for web/safety and
child processes are set to the same private paths. `TMPDIR` and `ERL_CRASH_DUMP`
are set before boot, so Python subprocess temporary files also belong to the VM.
The test helper removes the run root after ExUnit. Production defaults remain
`/data/{state,logs,spill,images,web,safety}` and existing explicit production
web/safety environment overrides remain supported. Explicit function options win.

Each disposable suite also needs its own writable dependency sources and build
outputs, HOME, MIX_HOME and HEX_HOME. Copy dependency/cache **sources**, following
symlinks into the private copy; never link another worker's mutable tree. Set
`MIX_ENV=test`, `MIX_BUILD_ROOT`, **`MIX_BUILD_PATH`**, `MIX_DEPS_PATH`, `HOME`,
`MIX_HOME`, `HEX_HOME`, `TMPDIR`, `ERL_CRASH_DUMP` and `ERL_FLAGS='+S 2:2'`.
With an explicit `MIX_BUILD_PATH`, the project preserves the caller's build root.
Without it, tests retain the checkout-local build fallback (not the image's build
root); this fallback alone is NOT independent same-checkout build isolation.

`test/flywheel/u02/run.exs` audits only allowlisted effective paths before starting
the app. Supply `NANO_TEST_PRIVATE_ROOT` (private tool/build/deps parent) and
`NANO_TEST_PATH_REPORT` (private JSON artifact path). It rejects symlink ancestors
and nonprivate runtime/tool paths. It exercises focused regressions by default,
and all ExUnit tests with `--full`. Never run the old U01/U03 author-path launchers
unchanged: those are historical evidence, not portable parallel launch commands.

## Two-VM write-path evidence

`run_pair.sh` takes an exact 40-character `NANO_TEST_REVISION` from the current Git
repository and archives it into two private source trees. Supply absolute,
canonical caller-owned `NANO_TEST_PAIR_ROOT` (must not exist),
`NANO_TEST_PAIR_TMP`, `NANO_TEST_DEPS_SOURCE`, `NANO_TEST_MIX_SOURCE`,
`NANO_TEST_HEX_SOURCE`, and `NANO_TEST_STRACE` (strace executable). Set
`MCP_REFERENCE_NODE` and `MCP_REFERENCE_FILESYSTEM` to read-only reference binaries
to enable the real MCP tests. Neither suite calls a real model/service: Python's
opt-in real-BEAM safety rehearsal runs only private copies and scripted providers.

Each VM builds dependencies afresh, audits config before boot, runs the full audited
ExUnit launcher and actual `mix test --seed 17`, then Python safety tests including
the opt-in disposable BEAM recovery. The driver unsets MIX_BUILD_PATH for that
rehearsal so the watchdog's private build-root override is effective. Both suites
use seed 17 and two schedulers. Artifacts retain revisions, effective paths, logs,
syscall traces and audit results. Cleanup is deliberately caller-owned; preserve
failed evidence and never erase unrelated stores.

`audit_writes.py` consumes path-only `strace -f -yy` output, resolves relative
operands and fd destinations, and checks successful path mutations against each
VM's own roots. Child Python, compiler and dependency writes are included. Failed
operations are counted but are not reported as mutations. Special-device writes
(`/dev/null`, etc.) and anonymous BEAM memfd allocation are separately reported,
not filesystem-store exceptions. FD aliases are checked against their actual
resolved destinations. No argv/environment/data-buffer tracing. This is observed
write-path evidence for these runs, not a sandbox or arbitrary future guarantee.
Run its parser regressions with `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest
discover -s test/flywheel/u02 -p test_audit_writes.py -v`.

## Compatibility and allowed restoration

No durable format or production path change. New config keys are optional routing
keys, not authority/state migrations. Restore in a disposable copy by reverting
these test-only defaults and optional routing reads while preserving all newer
state/logs/evidence. Old code can still read the unchanged stores; it is unsafe to
run old test defaults without explicit private overrides. Never restore by deleting
production images or replacing newer graph/safety authority. Parent alone deploys
and verifies production paths read-only; no worker hot loading. The pre-existing
shared B image fixture is intentionally untouched and requires a separate owner
cleanup decision. PR-16.2 state-mutation rehearsal is not applicable: U02 changes
path selection, not durable schemas, credential semantics or graph generations.

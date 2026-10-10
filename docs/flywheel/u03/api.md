# Nano.Flywheel API v1

Explicitly start one owner; no application boot auto-start/import/authority. Parent alone
loads modules and starts `Nano.Flywheel.start_link(root: "/data/altair-flywheel/graph",
repository: "/app", owner: "altair")`. Roots are unique local-node global names.
This is cooperative authority, not a security boundary or filesystem sandbox. Do not
run a second node/process against the same root. Only altair integrates/deploys/closes.

`server` is returned pid or `{:global, {Nano.Flywheel, expanded_root}}`. All API maps
use fixed atom keys for protocol fields. Caller evidence/extra metadata atom keys and
values normalize into bounded strings; never intern strings from artifacts. Every call returns `{:ok, result}` or `{:error, reason}`. Read-only:
`snapshot/1`, `unit/2`, `readiness/2`, `ready/1`. `ready` sorts ascending numeric safety
priority, descending longest dependent path, then stable ID; created_at exposes age.
A dependency is ready only after owner close; partial stages do not count.

## Authority and calls

Owner authority `%{owner: "altair", owner_generation: integer}` must match current
snapshot; caller must be the named agent or its eval Task (`$callers` first agent).
`owner_pid` is injectable only for disposable tests. `claimant_resolver` is injectable
only for disposable tests. Production resolves claimant stable name through NanoAgent,
never monitors a short-lived eval Task. Names are durable; pids are observation only.

* `reconcile(server, owner_authority, evidence)` -> new owner authority. Required at
  fresh start/restart and after uncertain writes. Reloads coherent disk state, fences all
  worker claims, preserves reservation/proposal/stage/history, durably increments owner
  generation before readiness opens. Do not discard newer disk state for source rollback.
* `import(server, owner_authority, %{schema_version: 1, units: [description]}, provenance)`
  -> IDs. One whole candidate only, validated before persistence; requires empty graph.
* `validate(description, repository)` -> initialized units, no mutation.
* `claim(server, id, claimant_name, incarnation, expected_owner_generation, operation_id)`
  -> worker token `%{unit:, claimant:, incarnation:, owner_generation:, claim_generation:}`.
  Replay of matching operation ID returns still-current token; conflicts reject. After
  lost reply inspect snapshot.operations before retrying. Persist before reply.
* `prepare_dispatch(server, owner_authority, current_claim_token, dispatch)` -> prepared
  dispatch. Required after pull/claim and before any edits. Parent supplies exact
  `base_commit`, `worktree`, `branch`, `build_root`, `deps_root`, `runtime_root`,
  `random_tmp_root`, `unit_path`, `unit_sha256`. Paths are absolute canonical non-symlink;
  actual Git HEAD/branch match supplied exact values, and resolved unit bytes/hash/ID,
  worker_name/incarnation/authority_generation and all paths match. Resolved JSON
  `dispatch.dispatch_generation` must be current unit.dispatch_generation + 1.
  Preparation retains immutable original description, saves bytes/hash/claim binding and
  increments dispatch generation in attributed history. Reprepare requires new generation
  and hence new resolved-unit hash; forbidden after proposal/reservation. Private root
  overlap with another active/reserved dispatch rejects. Only parent verifies the supplied
  revision is current integrated compatible base; no HEAD/default is a dispatch authority.
* `expand(server, token,
 [%{kind: :exact | :prefix, path: relative_path}])` -> same token.
* `append(server, worker_token_or_owner_authority, unit_id, event)` -> event ID. Event
  requires stable `id`, matching `by`; `tokens` and wall time may be null. Exact replay
  does not double count. Conflicting replay fails. Events are information, not authority.
* `submit(server, token, proposal)` -> reservation. Proposal requires `id`, `base_commit`,
  `commit` (40 lowercase hex), `worktree`, `changed_files` (repository-relative paths),
  `evidence`, `dispatch_generation`, `unit_sha256`. Current parent-prepared dispatch
  must bind this exact claim, base, worktree, generation and resolved-unit hash. Actual committed Git diff (no rename detection) must exactly equal manifest
  and be covered by persisted scopes. Submission does not close any stage.
* `release(server, token, reason)` -> `:released`. Interruption/death fences worker and
  releases worker claim; submitted proposal/file reservation survives.
* `adopt(server, owner_authority, unit_id, proposal_id)` -> new reservation with incremented
  integration generation; preserves original author token/commit/evidence, rechecks diff,
  fences original worker. Necessary after owner restart, even if already accepted.
* `integration(server, owner_authority, reservation, :accept)` -> `:accepted`.
* `integration(server, owner_authority, reservation, {:land, integrated_commit, evidence})`
  -> `:integrated`; requires acceptance and independently rechecks actual committed diff.
* `integration(server, owner_authority, reservation, {:abandon, reason})` -> `:abandoned`;
  durably releases reservation/claim, clears stages for reassignment, retains history.
* `record_stage(server, owner_authority, id, stage, evidence)` -> stage. Stages:
  implemented, tested, reviewed, deployed, live_verified, announced, artifact_verified,
  external_blockers, serious_findings. Integrated is exclusively recorded by land.
* `close(server, owner_authority, id)` -> `:done`, durable reservation release. Code requires
  implemented/tested/reviewed/integrated/deployed/live_verified/announced. Artifact requires
  implemented/tested/reviewed/artifact_verified/announced, not fake deployment. Unresolved
  blockers/findings prevent close. Evidence contents are reviewed by parent, not inferred.

Reservation `%{unit:, proposal_id:, integration_generation:, owner_generation:, owner:}`
is distinct from worker token. Owner death blocks all readiness until reconciliation;
worker DOWN does not rebuild authority from monitor timing. Failed writes leave original
in-memory authority nonready/degraded; stop/restart if persisted generation is uncertain.

## Owner amendments

See [owner extensions](owner-extensions.md) for `add_units/4`, `reopen/5` and
`resolve_external/4`; no general graph editor. Stage writes to done units reject until
explicit safe reopening. Blockers retain original provenance after verified resolution.

## Description / durable schema

Unit description requires `id`, `title`, `why`, `base_commit`, `type` (:code/:artifact),
`priority` nonnegative integer, `requirement_leaves` nonempty strings, `dependencies`
(list IDs), `external_blockers` list, `scopes`, `acceptance`, `risks`, `rollout`.
Additional resolved dispatch/evidence fields are retained as bounded inert information;
caller atom keys/values become strings. Original JSON bytes/hashes remain unchanged in
provenance and prepared dispatch history. Missing dependencies,
cycles, duplicate IDs, empty leaves and noncanonical scopes reject whole import. Scopes
are exact/component-prefix, including future new files; symlink ancestors and `.`, `..`,
empty components, absolute/backslash/NUL paths rejected. Overlapping active claims or
reservations reject atomically. Exact ancestor paths conservatively conflict as file/directory
aliases (including future paths), but exact claims do not grant descendant-file coverage. Expansion must be persisted before edits.

Durable `state.term` is Erlang external-term schema_version 1 with owner/owner_generation,
revision, units, history, provenance, operations. Each unit retains original description,
canonical expanded scopes, claim generation, named worker claim (pid observation stays only in memory),
integration generation, proposal, reservation, stages, done, attributed history, created_at.
Store syncs temporary `.next`, renames `state.term`, then `sync -f root`; uncertain failure
quarantines, never silently resets. This relies on local filesystem sync semantics, not
an exactly-once arbitrary-effects guarantee. Unsupported/corrupt state refuses startup. Local state is bounded owner-produced external-term data (16 MB maximum), decoded
with `binary_to_term([:safe])`. Caller/artifact atom keys/values normalize to strings
at ingestion, retaining only fixed protocol atoms. Functions/references/ports/pids
reject as information; monitor pids are removed before persistence. Fresh-VM tests
prove restoration never interns the original arbitrary evidence atom. Protect the
authoritative root; it is never an artifact import target.

## Bootstrap / restoration

Freeze serialized dispatch first. `Nano.Flywheel.Bootstrap.capture([original_json_paths])`
returns exact original bytes, decoded records, SHA-256 and source path marked
`:serialized_bootstrap`; never invents graph-era claims. Import these in provenance after
validating complete unit candidate. The synced state rename is the single durable cutover;
bootstrap files remain immutable evidence, not parallel authority. Import with bootstrap provenance freezes readiness at cutover. Parent restarts/reconciles
to durably advance owner generation; imported manual units remain specifically pending
bootstrap reconciliation (not claimable). `reconcile_bootstrap(server, authority, id,
original_record_sha256, applicable_stages)` matches captured original completed record
bytes/hash/ID, requires no graph-era claim/proposal/reservation, verifies actual integrated
commit existence/ancestry for code, records original author/generation plus current owner
reconciliation and complete applicable stage evidence. It never fabricates worker tokens
or automatically marks done. Parent then verifies and closes/announces. Missing or still
submitted original records remain blocked; freeze finalized originals before import.

Old state was immutable serialized JSON bootstrap; new readable format is version-1 coherent
external-term graph plus retained original JSON bytes. Allowed restoration: preserve latest
coherent state.term, restart compatible v1 code in a disposable copy, reconcile advancing
owner generation, adopt pending reservation with revalidated Git diff, resume from recorded
stages. Newer generations/reservations/history must never be replaced by an old checkpoint.
Downgrade to pre-graph code is forbidden: it cannot honor v1 authority. Tests rehearse forward
claim/expansion/submission/stage mutations -> restart -> reconcile/adopt, without false done.

Errors include `:stale`, `:stale_owner`, `:stale_reservation`, `:degraded`, `:conflict`,
`{:not_ready, reason}`, `{:persistence, detail}`, `:unclaimed_diff`, `:diff_mismatch`,
`:git_diff_failed`, `:operation_conflict`, `:event_conflict`, validation and stage errors.
Persistence errors block claims until coherent recovery, never imply release succeeded.

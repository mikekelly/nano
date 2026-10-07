# Durable goals

`Seedling.Goals` is an opt-in library, not an extra model tool or a harness prompt.
Use a stable agent **name**, not a pid. Another agent can read its parent's goals
without calling (or waking) the parent. No model service or search key is needed.

```elixir
{:ok, goal} = Seedling.Goals.add("worker", "Improve onboarding",
  why: "New users should finish setup in under five minutes")
{:ok, step} = Seedling.Goals.add("worker", "Measure the current setup",
  parent: goal["id"])
Seedling.Goals.update("worker", step["id"], status: :active)
Seedling.Goals.complete("worker", step["id"], "Baseline is twelve minutes")
Seedling.Goals.review("worker")
Seedling.Goals.list("worker") # full tree, including closed goals
Seedling.Goals.list("worker", open: true)
Seedling.Goals.get("worker", goal["id"])
```

Results use `{:ok, value}` / `{:error, reason}`. Goals are string-keyed maps with
id, title, why, parent, status, note and UTC creation/update times. Statuses are
pending, active, blocked, done and cancelled (atoms or strings on input).
`update/3` accepts a map or keyword list of title, why, status and note. Parentage
is immutable, eliminating cycles. Completing a parent does **not** complete its
children; completing children does not complete their parent. Reopen explicitly
with `update(name, id, status: :active)`. Closed goals stay available to successors;
there is intentionally no destructive delete API.

## Review habit and display

Review whenever useful: on wakeup, before idle, or every few turns. Nothing
injects reviews into model context automatically. `review(name, limit: 8,
chars: 2000)` returns counts, open/total numbers, bounded text and a truncation
flag. It includes short goal titles and rationale, but omits detailed notes.
Read a specific goal for detail. `list/1` is intentionally unbounded for export.
The agent page shows this compact open-goal review, including when the agent is
not running, refreshed with its existing one-second header timer. It shows an
explicit error on unreadable/corrupt storage rather than pretending there are
no goals.

## Persistence and limits

JSON lives in `/data/seedling/goals` (override `Application.put_env(:nano,
:goals_dir, directory)`). File names hash names, so slashes cannot escape the
store. Updates acquire a per-file lock on this BEAM node, read the latest file,
write a synced temporary file and atomically rename it. There is no cache or
owner process to lose on agent or node restart; a fresh process reads the same
files. Keep `/data` mounted. Goal state is deliberately separate from harness
saved state and survives stopping/deleting an agent or reusing its name.

This is a single-node sandbox, not a multi-node/distributed database. Multiple
OS processes independently writing the same directory are not supported. Atomic
rename protects against partial files; no directory fsync/power-loss guarantee
is claimed. Corrupt JSON and unsupported schema versions are reported and never
overwritten by an update. All sandbox agents have read/write access; this is not
an authorization boundary. Titles are capped at 2000 bytes, rationale and notes
at 8000 bytes, names at 200 bytes; there is no total goal-count cap. Review output
is bounded, but reads decode the whole per-agent file. Very large trees therefore
cost disk/CPU, not agent calls; keep completed historical trees modest.

## Validation

`env -u MIX_BUILD_PATH MIX_ENV=test mix test test/seedling_goals_test.exs`
uses only local files and tasks: lifecycle/decomposition, fresh-process reads,
concurrent writers, compact review limits, validation/isolation, path safety,
corrupt-file preservation and storage errors. No model spend. Live smoke can
load the module with `Code.compile_file("lib/seedling/goals.ex")`, write a goal,
and review it from a separate task. Actual node/container restart is not performed
on a shared running workbench; persistence follows from direct disk reads with
no in-memory cache.

### Early workbench upgrade

Early live-loaded versions used base64 filenames. Reads fall back to those files
only when the current SHA256 filename is absent; the next update saves the new
path. `Seedling.Goals.migrate_legacy(name)` explicitly saves the validated goals
without changing them. An existing current file always takes precedence (including
corrupt files, which return an error); legacy data is never merged or overwritten.
Legacy files remain on disk as an audit copy. Never run old and new module versions
as simultaneous writers during migration.

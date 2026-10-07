# nova-goals: durable goals and memory

Start here: `Nano.Goals` keeps what an agent is trying to do and why;
`Nano.Memory` keeps reusable facts and lessons. Both are ordinary eval-callable
libraries, with no change to the harness prompt, startup or tool list.

```elixir
{:ok, goal} = Nano.Goals.add("alice", "Deliver a reliable launch report",
  why: "Operators need evidence before committing to launch")
{:ok, step} = Nano.Goals.add("alice", "Verify the sources",
  why: "Outdated facts could reverse the recommendation", parent: goal["id"])
Nano.Goals.update("alice", step["id"], status: :active)
Nano.Goals.update("alice", step["id"], status: :done, note: "Sources checked")
Nano.Goals.review("alice", limit: 6)
Nano.Memory.put("alice", "source-check", "Always check publication dates",
  why: "A stale announcement looked like current policy", tags: ["research"])
Nano.Memory.review("alice", query: "research", limit: 4)
```

## Contracts

Owners are stable, nonempty agent-name strings (up to 512 bytes), not PIDs.
Any agent may read another owner's goals/memory. All records use string keys;
summary envelopes use atom keys. Timestamps are UTC ISO8601.

Goals: `add(owner, title, why: rationale, parent: optional_id)` requires a
nonempty title (<=1000 bytes) and rationale (<=8000 bytes). Returns `{:ok, goal}`.
`update(owner, id, changes, opts \\ [])` allows title, why, note, status only;
changes can be a keyword list or map, with string or atom keys. Status is
`open`, `active`, `blocked`, `done`, `cancelled` (strings or atoms accepted).
Notes may be empty, <=8000 bytes. Missing IDs return `{:error, :not_found}`.
Parent is immutable, must already exist, and children are created new, so API
operations cannot create cycles. Completing a parent does **not** silently
complete its children. Mark each step explicitly. Completed/cancelled goals
remain available for handover through `list(owner, opts \\ [])`.

`review(owner, opts \\ [])` returns
`{:ok, %{goals: summaries, total: open_count, omitted: count}}`.
Defaults to 12 open/active/blocked goals in creation order. Each summary has
id, parent, status, title (160 characters), why (240), note (160). A missing
owner is an empty successful result, not an error. Explicit `:limit` clamps to
0..50, non-integers return `{:error, :invalid_limit}`.

Memory: `put(owner, key, text, opts \\ [])` upserts a named entry, preserving
creation time. Key <=200 bytes, text <=32000 bytes, optional why <=8000 bytes,
optional tags at most 20 nonempty strings <=100 bytes each.
`get(owner, key, opts \\ [])` returns full entry; `forget/3` returns
`{:ok, :deleted}`. Absent entries return `{:error, :not_found}`.
`review(owner, query: text, limit: n)` searches key/text/why/tags with literal,
case-insensitive substring matching; returns `{:ok, %{memories: excerpts,
total: match_count, omitted: count}}`, newest first. Default limit 8, max 50;
text excerpts <=320 characters, rationale <=160. No embeddings, model calls,
automatic memory selection or hidden prompt injection.

## Storage, concurrency and failure behavior

All calls accept `root: path`. The default root can be set at boot with
`config :nano, :library_root, path`; otherwise `/data/nano-library` is outside the
checkout and persists on the container's data volume. Use the same root after
handover/restart. Files are `root/goals/<sha256-owner>.json` and
`root/memory/<sha256-owner>.json`, versioned JSON snapshots with file mode 0600.
Owner strings cannot escape the root or exceed filename limits. The root is
trusted configuration: this is not a sandbox/security boundary.

Every mutation takes a per-path `:global` lock on **this BEAM node**, reads the
latest committed snapshot, applies one change, fsyncs a unique temporary file,
then atomically renames it. Failed writes never report success. Concurrent
writers in this node do not lose updates; lock ownership disappears when a
writer exits. A crash during writing leaves the previous snapshot readable;
crash leftovers named `.tmp` are ignored. Reads do not acquire mutation locks,
call the agent, or wait for the LLM. They read a bounded snapshot (max 2 MB per
owner/kind), making `review/2` suitable for the live dashboard. This is bounded
local filesystem work, **not** a guarantee against a hung filesystem. No ETS
cache, dedicated owner process or startup load is needed, so a new process or
node immediately sees persisted data. There is no cross-OS-process/multi-node
writer guarantee; use a single node for each storage root. File fsync protects
node/process crashes; sudden power-loss durability of the rename's directory
entry depends on the filesystem (directory is not fsynced).

Missing files mean empty stores. Invalid JSON/schema returns
`{:error, :corrupt_store}`; oversize stores return `{:error, :store_too_large}`;
filesystem failures are returned, never reset to empty and overwritten.
Maximum persisted snapshot size is enforced on writes too. Errors in roots,
owners, fields, IDs and limits are explicit tuples. Options must be keyword
lists. Do not put secrets in goals or memories: these libraries are shared
agent-readable storage, not secret management. Deleting an agent in the
harness does not delete this durable knowledge.

## Review and handover habit

Review goals at wakeup/before idle when useful, not by pasting the full tree.
Keep notes short and concrete; record why a goal still applies. Before handover,
update statuses and write reusable discoveries into memory. A successor uses
the original owner's name to read goals and search memories. No scheduler or
behavior policy is installed by this library.

## Dashboard integration

`NanoWeb.AgentLive` reads `Nano.Goals.review(agent_name)` on mount and on its
existing one-second refresh. The Open goals section shows total/omitted counts,
titles, statuses, rationale, notes and parent references. Closed goals are
excluded. Goals remain visible after an agent stops. Errors are displayed as
`Goals unavailable`, not hidden as empty goals, and HEEx escapes authored text.
`test/nano_web/goals_live_test.exs` covers visibility, hierarchy, completion
refresh, suspended-agent reads, stopped-agent persistence, HTML escaping, empty
stores, truncation and corruption. Test roots are unique; the boot setting is
restored within the test VM, with no changes to the running node.

## Verification

`test/nano_goals_memory_test.exs` uses a random temp root per test (safe for
parallel checkouts). Covers hierarchy/rationale/status across short-lived
writers, two independent BEAM boots (actual disk reload), 40 concurrent writers, memory replacement/search/deletion, bounded
review, hashed paths, permissions, corrupt/oversize stores, and filesystem
errors. No real models, external services or API keys needed.

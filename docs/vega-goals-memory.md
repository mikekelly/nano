# Goals and durable memory

Fresh agents: `Vega.Goals.review("identity")` gives bounded open goals with their why,
status, parent IDs and full-tree status counts. `Vega.Memory.retrieve("identity", "topic")`
gives a bounded shortlist of matching memories. No agent PID, supervisor or startup hook
is needed. Identity is a name, not an agent incarnation; replacing or stopping an agent
**does not delete its goals/memories**.

```elixir
{:ok, goal} = Vega.Goals.add("alice", "Ship import", why: "Unblock customers")
{:ok, step} = Vega.Goals.add("alice", "Test bad rows", parent_id: goal["id"], why: "Avoid data loss")
Vega.Goals.update("alice", step["id"], status: "done")
Vega.Goals.review("alice", limit: 8)
Vega.Goals.tree("alice") # nested "steps" lists
Vega.Goals.get("alice", goal["id"])
Vega.Goals.list("alice", open_only: true)

{:ok, memory} = Vega.Memory.put("alice", "CSV import rejects blank headers",
  tags: ["csv", "parser"], provenance: %{source: "test run", path: "test/import_test.exs"})
Vega.Memory.retrieve("alice", "CSV parser", limit: 5, max_bytes: 8000)
Vega.Memory.update("alice", memory["id"], content: "Correction: blank headers accepted")
Vega.Memory.delete("alice", memory["id"])
```

All return `{:ok, value}` / `{:error, reason}`. Records have string keys, random IDs,
created_at/updated_at ISO timestamps. Updates accept keyword lists or maps (atom or string
keys), reject unknown/immutable fields. Goal status: pending, active, blocked, done,
cancelled. Why defaults to empty; set it deliberately so fresh agents can judge applicability.
Reparenting cannot introduce cycles/orphans. Parent status is explicit; finishing a parent
never implicitly changes children. Deletion with children needs `cascade: true` and removes
all descendants. Memory revision increases on update; provenance and tags survive content
updates unless explicitly replaced. Provenance is supplied by the caller, not verified;
store sources/evidence, never secrets. There is no audit history after replacement/delete.

## Retrieval and context budgets

Goal review returns `%{goals: [...], counts: %{status => n}, omitted: n}`. It shows at most
8 open goals by default (max 50), title 160 characters, why 240 characters. List/tree/get
are full-detail tools. Review is insertion order, not a priority planner.

Memory retrieval is **lexical**, Unicode word overlap over content and tags, not semantic.
Each unique matching word counts once; ties sort newest-first. Empty query returns recent
memories. Nonmatching records are omitted. `limit` defaults 5/max 50; `max_bytes` defaults
8000/max 100000, counting JSON serialization of the entire returned list including metadata.
Oversize records are skipped, never truncated (so provenance remains attached).
`Memory.list/get` are full-detail inspection, not bounded prompt loading.

## Persistence, isolation and limits

Default root `/data/vega`, override per call with `root: directory` (pass consistently).
One versioned JSON document per identity per capability; base64url filename prevents
identity path traversal. Each document is capped at 4 MB. Writes serialize same-identity
updates with a node-local lock, fsync a uniquely named temporary file and atomically rename
it. Reads need no process and never call an agent. Restarting the VM requires no replay or
cache restoration. Corrupt/unsupported documents report an error and are not overwritten.

This is a small local-volume store, not a multi-node database: **only one BEAM VM should
write a root**; independent VMs/external editors aren't coordinated. Directory metadata is
not fsynced (no promise against abrupt host power loss); `/data` volume removal loses data.
The files are plain JSON with filesystem permissions, not access-controlled or encrypted.
Review scans a capped disk document; it does not contact a service or wait for an agent.
Tests use random isolated roots and exercise fresh-process reads, concurrency, CRUD,
validation, corruption and bounded retrieval; VM restart durability follows from disk-only
state, rather than a full container restart test.

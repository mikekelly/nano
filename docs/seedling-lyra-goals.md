## Goals and capability index

`Seedling.Goals` persists agent-owned trees with explicit `why` in atomically replaced
JSON under `/data/seedling/goals` (names hashed). Any agent can read another's goals.

```elixir
{:ok, goal} = Seedling.Goals.add("lyra", "Ship capability", why: "Make progress durable")
Seedling.Goals.add("lyra", "Test", parent: goal.id, why: "Verify behavior")
Seedling.Goals.update("lyra", goal.id, status: :active)
Seedling.Goals.review("lyra") # bounded summary, invoke before idle or on wakeup
Seedling.Goals.tree("lyra")   # full nested tree
```

`list/2`, `tree/2`, `review/2` return `{:ok, value}` or `{:error, reason}`.
Statuses: open, active, blocked, done, cancelled. Completing a parent leaves its
children unchanged. `root:` isolates stores; `review` accepts `limit:` (default 8).
AgentLive displays up to 50 open goals, their parents and why, even for stopped agents.
Reads are bounded local disk JSON (256 KiB); there is no call into agents or remote
service. Mutations serialize on the current node, not across independent BEAM nodes.
No automatic review hook, reparent/delete, or inherited parent completion.

`Seedling.Index.generate(root: "/app")` atomically writes `NOTES.md` from sorted
`docs/seedling-*.md`; `render/1` previews. Regeneration is explicit, not a boot hook.

### Search hardening

`Seedling.Files.find(glob)` now uses gitignore-aware `rg --files --hidden` and
excludes `.git`; `grep(pattern, path, limit: 100, bytes: 16000, timeout: 5000)`
streams output through a port, stops globally on the cap, and closes the subprocess.
`literal:`, `ignore_case:`, `glob:` supported. No matches yields status 1; regex or
filesystem errors yield `{:error, %{status: ..., text: ...}}`. Capped status is nil
because the subprocess was stopped before natural exit. Both functions advertise
`truncated`; grep also gives a notice. Requires ripgrep. Find glob prefix sets the
search directory; existing path-shaped glob API retained. Ignore files follow
ripgrep semantics (gitignore applies in a repository). Reads/search never mutate
node settings. Files' original read/write/edit/ls functions unchanged.

### Live goal validation (2026-10-08)

Disposable delegated agent `lyra-goals-proof` received a vague brief, created a root
and child with reasons, then idled. Its actual process was restarted (PID 0.2521 to
0.3209); on a followup it reread persisted goals and marked both done. A fresh Task
reader verified both statuses, retained reasons and child-parent link. Goal ids:
`3MAiQHcvd24T263r`, `WZ0MiMqWWJfqBxd-`. Agent was stopped after validation; its JSON
remains as a durable sample. Agent exhausted the 12,000 token budget after writing
completion, before reporting completion; evidence comes from persisted reads, not
a fabricated final report. This validates agent restart, not a whole-node reboot.

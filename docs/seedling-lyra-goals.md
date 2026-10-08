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

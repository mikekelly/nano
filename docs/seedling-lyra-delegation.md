# Delegation

`Seedling.Delegation.subagent("scout", parent: "lyra", prompt: "Read-only scout; report summary",
model: "openai-codex/gpt-6.1-sol", reasoning: "low", max_turns: 12, max_tokens: 100000,
max_context: 32000, pre: ["/app/NOTES.md"], message: "Start now")`

Returns `{:ok, %{name: ..., pid: ..., monitor: ..., worktree: ..., pre: ..., mcp: ...}}`.
Model/provider are selected by explicit model slug, validated by Nano.Model. Start happens
in the caller's eval, preserving dashboard `started_by`. `message:` is optional; without it,
child stays idle. `tell(name, term)` resolves the current pid (safe across restart).

Child calls `Seedling.Delegation.report("scout", %{summary: ..., commit: ..., tests: ...,
limitations: ...})`. Result including automatically collected usage arrives as
`{:delegation, "scout", :result, %{result: ..., info: %{budget: ..., cost: ...}}}`.
Other kinds are `:halted` (reason/info), `:down` (pid/reason), `:restarted` (pid).
Parent uses harness idle; do not block an eval on receive. Results >16000 serialized bytes
are rejected. No transcript is returned. Named parents preferred; PID parents are session-only.

Prompt composition uses the lean harness facts file plus shared operating rules, identity,
report instructions, job and bounded pre-reading. `pre_lines:` (200), `pre_bytes:` (12000)
apply per file; hashes cover the full file, and next_offset explicitly identifies omitted
content. Caller should choose a small pre set. Files foundation used for reading.

`worktree: "/tmp/scout", repo: "/app", revision: "HEAD"` creates a detached git worktree
at that revision. The child's prompt identifies its copy; builds still MUST use MIX_ENV=test.
Retained for review; parent chooses commits to merge and manually removes reviewed worktrees.
If a subsequent startup stage fails, the worktree can remain; inspect before retrying.

`mcp: ["filesystem"], mcp_supervisor: Seedling.MCP.Connections, mcp_config: "config/mcp.json"`
uses sibling MCP.ensure_connection and awaits readiness (mcp_timeout default 5000 ms) before
starting/waking child, then installs durable named notification routing. Child sees lookup
instructions, not stale client pids. Requires running MCP supervisor and configured server.
Default supervisor is Seedling.MCP.Connections.

## Recovery / boot integration (parent owns application.ex)

Add `{Seedling.Delegation.Supervisor, [restore: false]}` to application children after
Nano.StateStore and AgentSupervisor; invoke `Seedling.Delegation.Supervisor.restore()`
AFTER StateStore.load and NanoAgent.revive. This avoids premature missing-child reports
while boot revival is in progress. Later supervisor restarts restore automatically. Lazy
startup defaults to restoring, for an already-running node.

Records under state_dir/delegation store monitor routing and queued reports atomically.
Absent named parents retain pending notifications; monitor crash and supervisor reboot
reload them. Delivery is at-least-once at the mailbox boundary, not acknowledged processing:
a node crash between send and durable clear can duplicate delivery, and a crash after clear
but before Nano saves its mailbox event can lose delivery. Last 100 pending status events
retained; compact result stays pending until parent is live. Worktrees/report paths live on
disk. Corrupt records are skipped. No automatic agent cancellation or worktree deletion.

## Validation

5 capability tests: hashed/paged pre-reading and prompt, Nano child lifecycle halt/death/
restart/result cap, persisted queued result and boot ordering, initialized real stdio MCP
before idle child's first turn, isolated git worktree revision. Full pre-MCP integration
suite 273 passed. Actual live model child smoke called report: 1 turn, 2113 tokens,
summary "real child success". Only owned Seedling modules were loaded live; no Nano reload.

Startup rollback: readiness setup does not install watchers. Watch activation occurs only after
child and durable monitor succeed. Failures stop/delete ONLY the child created in that call
and the corresponding monitor; newly installed MCP watches are removed via MCP.unwatch.
Reused MCP clients are never killed. Unreachable clients can prevent best-effort unwatch
cleanup; parent should inspect their durable watchers after infrastructure failures.
Failure tests cover missing facts_file after MCP setup and monitor record write failure.

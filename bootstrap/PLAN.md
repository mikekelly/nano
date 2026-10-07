# Delivery plan — Nano Agent

Source of truth is `SPEC.md`. This plan adds only (a) decisions where the spec is silent,
(b) the module contracts that let work proceed in parallel, and (c) the stages and their
exit criteria. Where this plan and the spec disagree, the spec wins — report the conflict.

**The prime directive is the spec's: simplicity.** Target is a harness a reader can hold in
their head. (An early draft of this plan put line counts on that; they were the
orchestrator's guess, not a spec requirement. Size is reviewed for removable machinery, not
against a number.) Use
OTP as is. No behaviours, protocols, macros, or config layers of our own. No dependency
that is not needed. If a contract below turns out to be more than the job needs, shrink it
and say so.

## Decisions where the spec is silent

1. **Layout.** The Mix project lives at the repo root (the repo *is* `/app`). OTP app `:nano`;
   modules `Nano.*`, `NanoWeb.*`, and top-level `NanoAgent` (the spec's name).
2. **No asset pipeline.** No esbuild, tailwind, or node. `phoenix.min.js` and
   `phoenix_live_view.min.js` are served straight from the deps' `priv/static`, plus one
   hand-written `priv/static/app.css` and a few lines of inline JS to connect the LiveSocket.
   No Ecto, mailer, gettext, LiveDashboard, or telemetry boilerplate. Bandit as the server.
3. **Agent identity.** `name` is unique and is the Registry key and the API handle.
   `id` is `"<name>-<6 hex>"`, generated when an agent is first started, stable across
   crash-restarts, new after stop + start or node restart. PubSub topic `agent:<id>`,
   log file `<LOG_DIR>/<id>.jsonl` (`LOG_DIR` defaults to `/data/logs`; `tmp/logs` in dev/test).
4. **Two sequence numbers.** Every log entry has a per-agent, monotonically increasing `seq`
   (this is what `log?since=` uses; it survives crash-restarts). `event_received` entries also
   carry `event_seq`, the number shown in the `<event seq=..>` tag.
5. **Agent state lives in ETS, readable without calling the agent.** A suspended or busy agent
   cannot answer a `GenServer.call`, so the dashboard/API read status from the `Nano.StateStore`
   table, never from the agent process. Suspension is computed from `Process.info/2`.
6. **Harness-originated text is always `<harness>…</harness>`**, never `<event>`: start note
   (`start_idle: false`), restart note, wakeup note, un-halt note. Harness notes and pending
   events are delivered together in one user message.
7. **`idle` returns nothing, but the API needs a tool result** for every tool call. The
   transcript gets an empty-content tool message for `idle` when the next turn starts. If a
   response mixes `eval` and `idle`, evals run in order, then the turn ends. An unknown tool
   or undecodable arguments come back to the model as a tool-result error, never a crash.
8. **Crash mid-step.** The store is written before each step, including what the agent is
   currently doing (`activity`, e.g. `{:eval, 12}` or `:model_request`). On restart the agent
   repairs the transcript so it is valid for the API (any tool call left without a result gets
   one saying the process exited), then delivers the `<harness>` restart note. The exit reason
   is obtained by having `Nano.StateStore` monitor agent pids and record the `:DOWN` reason.
9. **Halting.** One `halted` field: `nil`, `:budget`, `:node_budget`, or `:restart_brake`. A halted agent still
   logs `event_received` and queues events in `pending`. `unhalt` clears it, resets the restart
   window, and — if the cause was the agent's own budget — resets the turn and token counters; pending events
   then start a turn, prefixed by a truthful `<harness>` note.
10. **Budget.** A turn = one model call. Tokens = prompt + completion, summed over every call —
    cumulative spend, not context size. Because the whole transcript is re-sent each turn, 50
    turns with the context growing ~2k tokens a turn is ~2.5M tokens, hence the
    `AGENT_MAX_TOKENS` default of 3,000,000 (raised from the spec's original 500,000 at the
    owner's request). Node-wide cap: `NODE_MAX_TOKENS_PER_HOUR` (default 100,000,000), a rolling-hour counter in ETS; when hit,
    the agent logs `budget_exhausted` (scope `node`) and halts with `:node_budget`.
11. **Lifecycle verbs.** `stop` terminates the child and deletes its store entry (the agent is
    gone). `restart` kills the process with reason `:operator_restart` so the supervisor brings
    it back with history. It counts toward the restart brake like any other exit (an exemption
    would let an agent dodge the brake by exiting itself with that reason). Agents are `:permanent`
    children; the `DynamicSupervisor` gets a generous `max_restarts` (the brake is the real limit).
12. **`OPENROUTER_BASE_URL`** (default `https://openrouter.ai/api/v1`) exists so tests and
    end-to-end checks can point the node at a scripted fake. It is the only test seam, with
    `CHATGPT_BASE_URL` and `CHATGPT_AUTH_URL`, added with the ChatGPT subscription provider.
13. **Prompt caching.** `cache_control: %{type: "ephemeral"}` on the system prompt and on the
    last message of the request, `usage: %{include: true}`; the transcript is append-only so the
    prefix is stable. Cache hit = `cached_tokens > 0`.
14. **Network honesty.** `NETWORK_POLICY` in the app defaults to `openrouter-only` per the spec,
    but the shipped compose file does not restrict egress, so it sets
    `NETWORK_POLICY="unrestricted outbound internet access"` explicitly. The README explains how
    to restrict egress and that the text must then be changed to match.
15. **Container.** The image bakes Hex, rebar, deps and a first compile *outside* `/app`
    (`MIX_DEPS_PATH=/opt/nano/deps`, `MIX_BUILD_PATH=/opt/nano/_build`, both owned by `nano`),
    so bind-mounting a checkout over `/app` hides nothing and startup needs no Hex access.
    The image also contains its own committed copy of the source at `/app` so it runs without
    a mount. Compose requires `NANO_CHECKOUT` (path to a *dedicated* checkout — no default, so
    nobody mounts a working copy by accident), publishes `127.0.0.1:4000:4000`, mounts a
    `./data` volume at `/data`, and uses `restart: unless-stopped`. Container name `nano`.
    Cookie: generated into a file at build; `NODE_COOKIE` overrides; the entrypoint and
    `bin/shell` / `bin/rpc` all resolve it the same way.
16. **Commits.** Work is committed as it lands and pushed to `origin`
    (github.com/mikekelly/nano, private). Agents sharing the main working tree (stages 1–2)
    do not run git write commands — the orchestrator commits their work at the stage boundary,
    so parallel agents cannot sweep up each other's half-written files. Agents from stage 3 on
    work in their own git worktree and commit there on a branch; the orchestrator merges to
    `main` and pushes. End-to-end checks that need a dedicated
    committed `/app` make a throwaway clone under `~/.cache/` (colima only shares `/Users/mike`).

## Contracts (what parallel work codes against)

```elixir
# ── NanoAgent (GenServer) ─────────────────────────────────────────────────────
NanoAgent.start(opts)        # {:ok, pid} | {:error, reason}
                             # opts: name: (required), model: (DEFAULT_MODEL), start_idle: true,
                             #       system_prompt: (template override), max_turns:, max_tokens:
NanoAgent.whereis(name)      # pid | nil            (Registry lookup; no call to the agent)
NanoAgent.notify(agent, term)# :ok                  (cast; agent is a pid or a name)
NanoAgent.unhalt(agent)      # :ok                  (cast)
NanoAgent.info(name)         # map | nil            (reads Nano.StateStore; no call to the agent)
#   %{id, name, pid, model, status: :idle | :thinking | :running_tool, halted: nil | :budget | :restart_brake,
#     suspended: boolean, system_prompt, restart_count, cost, cache_hit_rate,
#     budget: %{max_turns, max_tokens, turns_used, tokens_used}}
NanoAgent.list()             # [name]

# ── Nano.StateStore (GenServer owning a public named ETS table) ───────────────
# keyed by agent name; holds everything needed to restore an agent and to answer info/1.
Nano.StateStore.get(name) / put(name, map) / delete(name) / all()
Nano.StateStore.watch(name, pid)      # monitor pid; record its exit reason for the next init
Nano.StateStore.next_seq(id)          # per-agent log sequence (ets update_counter)

# ── Nano.Log ──────────────────────────────────────────────────────────────────
Nano.Log.write(agent, type, fields)   # agent: %{id:, name:}; returns the entry. Appends JSONL + broadcasts.
#   entry (atom keys in-process, JSON on disk): %{seq, at (ISO8601), agent_id, agent, type, ...fields}
#   broadcast on Nano.PubSub topic "agent:<id>" as {:nano_log, entry}
Nano.Log.read(id, since \\ 0)         # [entry] with seq > since, read back from the JSONL file (string keys)
Nano.Log.subscribe(id)

# ── Nano.OpenRouter ───────────────────────────────────────────────────────────
Nano.OpenRouter.chat(model, messages, tools)  # {:ok, %{message, finish_reason, usage, provider, cost}} | {:error, %{status, body}}
#   one attempt; retry/backoff (3 attempts, transient errors only) and model_error logging live in NanoAgent
#   or here — implementer's choice, but every attempt's failure is logged as model_error.

# ── Nano.User (GenServer, registered by name in the same Registry) ────────────
# exactly the table in SPEC.md "Nano.User". `to` may be a pid, an agent name, or a user name.
# Everything sent/received is broadcast on topic "user:<name>" as {:nano_user, %{dir: :sent | :received, at, to, term}}.
Nano.User.list()                      # [name]

# ── Nano.Ops (plain functions; the one surface the dashboard, API and shell share) ──
agents/0            # [NanoAgent.info map]
agent/1             # NanoAgent.info map | nil
whereis/1           # pid | nil
start_agent/2       # (name, opts) -> {:ok, pid} | {:error, _}
stop_agent/1, restart_agent/1, resume/1, unhalt/1     # :ok | {:error, :not_found}
tail/1              # subscribe the calling shell and print entries as they arrive
log/2               # (name, since) -> [entry]
processes/0         # [%{pid, name, kind: :agent | :user | {:spawned_by, agent_name} | :other,
                    #    current_function, message_queue_len, memory, reductions, agent: info | nil}]
                    # (standard set excluded; the dashboard computes reductions/s from deltas)
process/1           # (target) -> Process.info detail map | nil
resolve/1           # agent name | user name | registered name | "#PID<…>" string | pid -> pid | nil
eval/1              # (code string) -> {:ok, inspected_result} | {:error, message}
```

Registry: one `Registry` named `Nano.Registry`, keys `{:agent, name}` and `{:user, name}`.
Supervision tree (in order): `Phoenix.PubSub` (`Nano.PubSub`), `Nano.Registry`, `Nano.StateStore`,
`Task.Supervisor` (`Nano.EvalSupervisor`), `DynamicSupervisor` (`Nano.AgentSupervisor`),
`DynamicSupervisor` (`Nano.UserSupervisor`), `NanoWeb.Endpoint`. After the tree is up, the
application records `Process.list()` in `:persistent_term` as the boot set, and starts the
`dashboard` user.

## Stages

| # | Stage | Owner | Runs | Exit criteria |
| --- | --- | --- | --- | --- |
| 0 | Read spec, check toolchain, write this plan | orchestrator | — | Plan written |
| 1 | **Scaffold**: Mix project, deps, config (`runtime.exs` reads every env var in the spec table), supervision tree, endpoint, router with every dashboard + API route, compiling stubs for each contract above | scaffold agent | first | `mix compile --warnings-as-errors` and `mix test` pass; server boots on :4000 |
| 2a | **Harness core**: `NanoAgent`, `Nano.StateStore`, `Nano.Log`, `Nano.OpenRouter`, budgets, system prompt rendering; scripted fake OpenRouter in `test/support` | core agent | parallel | Tests cover the loop, both tools, batching of pending events, wakeup, every row of the Failure-handling table that is in-node, budgets, log entry types |
| 2b | **Operator surface**: `Nano.User`, `Nano.Ops`, process listing/tagging, the whole HTTP API incl. SSE | ops agent | parallel | Tests for every endpoint in the API table and every `Nano.User` function |
| 2c | **Container**: Dockerfile, compose, entrypoint, `bin/shell`, `bin/rpc`, `.dockerignore`, README | container agent | parallel | Image builds; container boots, `bin/rpc '1+1'` works, port bound to localhost only, restart policy brings the node back after `System.halt()` |
| 3a | **Dashboard**: process view, agent view, send forms, start form, lifecycle buttons | dashboard agent | after 2a+2b | LiveView tests; pages verified in a real browser against a running node |
| 3b | **Spec conformance review** of stages 1–2 by a fresh reader given only SPEC.md and the code | review agent | parallel with 3a | Written list of deviations, each with spec quote + file:line |
| 4 | **Fix round**: findings routed back to the owning agents | owners | — | Every finding fixed or explicitly rejected with a reason |
| 5 | **End-to-end verification in Docker** against a scripted fake OpenRouter (no API key is available in this environment): walk every row of the Failure-handling table, every API endpoint, `bin/shell`/`bin/rpc`, hot reload of `NanoAgent` with a running agent, node death + restart, JSONL on the volume, dashboard in a browser | verify agent (fresh) | after 3–4 | Pass/fail per spec section with evidence; failures go back through stage 4 |
| 6 | **Simplicity pass + final report**: line count, dead code, anything not earning its place; README matches reality | review agent, then orchestrator | last | Final report to the owner, including what was not verified (live model behaviour needs a real key) |

File ownership (no agent edits another's files; cross-boundary needs go through the orchestrator):

- scaffold: `mix.exs`, `config/`, `lib/nano/application.ex`, `lib/nano_web/{endpoint,router}.ex`, `lib/nano_web.ex`, layouts, `test/test_helper.exs`
- core: `lib/nano_agent.ex`, `lib/nano/{state_store,log,open_router}.ex` (+ any small sibling it needs), their tests, `test/support/`
- ops: `lib/nano/{ops,user}.ex`, `lib/nano_web/controllers/`, their tests
- container: `Dockerfile`, `docker-compose.yml`, `.dockerignore`, `.env.example`, `bin/`, `README.md`
- dashboard: `lib/nano_web/live/`, `priv/static/app.css`, their tests

## Outcome (2026-10-06)

All stages ran. Stages 3b–5 looped three times: three review passes and two end-to-end
passes each fed a fix round, and the last end-to-end pass (image built from `5e1f4b9`, plus
`e59e985` hot-reloaded) passed with live runs on `deepseek/deepseek-v4.1-flash`.

Added at the owner's request during delivery, beyond the original spec: IEx-style eval error
formatting, the `REASONING` level, a budget-used line on each delivered message, and larger
default token budgets. Known limitations are listed in the README under "Worth knowing while
you run them". The closing simplicity review produced a costed menu of cuts that has not been
applied; the choices in it are the owner's.

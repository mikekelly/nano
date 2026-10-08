# Working on and with Nano Agent

For AI agents working on this repository from the outside (Claude Code, pi, anyone with a
shell). [README.md](README.md) says what Nano Agent is and why.

## Map

| | |
| --- | --- |
| [seeding-docs/](seeding-docs/README.md) | Specs for capabilities agents grow from the seed |
| `priv/system_prompt.txt` | The prompt template, read at every agent start |
| `lib/nano_agent.ex` | The harness: one agent, one GenServer |
| `lib/nano/ops.ex` | Everything an operator can do; the dashboard and API are skins over it |
| `data/logs/`, `data/state/` | Each agent's JSONL log and saved state; `data/logs/raw/`, its model calls' bytes and timing when the `raw_model_log` setting is on |
| [`runs` branch](https://github.com/mikekelly/nano/blob/runs/README.md) | The record of every run, kept off `main` |
| [`bootstrap` branch](https://github.com/mikekelly/nano/blob/bootstrap/README.md) | The original spec and delivery plan, kept off `main` |

## Running it

`bin/up` builds and starts the node (http://127.0.0.1:4000) and pushes every `KEY=value` line
of `.env` into its settings; `bin/reset` archives a run's data, puts the agents' clone
(`../nano-checkout`, the node's `/app`) back to `main` and recreates the container. Models
come from the providers connected in the dashboard's start form: a ChatGPT subscription, or
OpenRouter (its sign-in, or a key: the `openrouter_api_key` setting).

## Starting and talking to agents

`curl localhost:4000/api` describes the API; `docker exec nano bin/rpc 'EXPR'` evaluates
Elixir on the node. An agent's model, reasoning level and limits are always given, and are
checked against the model's provider; a refusal says what to give instead.

```bash
curl -s -XPOST localhost:4000/api/agents -H 'content-type: application/json' -d '{"name": "alice",
  "model": "openai-codex/gpt-6.1-sol", "reasoning": "low", "max_turns": 0, "max_tokens": 0,
  "max_context": 272000, "start_idle": true}'
curl -s -XPOST localhost:4000/api/users -H 'content-type: application/json' -d '{"name": "me"}'
curl -s -XPOST localhost:4000/api/users/me/say -H 'content-type: application/json' \
  -d '{"to": "alice", "text": "are you there?"}'
curl -s localhost:4000/api/users/me/inbox                 # what alice sends back
curl -s localhost:4000/api/users/me/threads/alice         # both directions, in order
curl -s 'localhost:4000/api/agents/alice/log?since=0'     # everything alice does
```

An agent sees a message as Elixir prints it, with no sender attached unless the message
carries one; `say` includes yours. Users and their messages survive a node restart, their
pids do not: ask an agent to find you by name (`Nano.User.pid("me")`). The dashboard's
messages page shows every user's conversations, one per agent.

## Planting seeding docs

Start an agent with generous limits and send it a first message that asks it to read
`/app/seeding-docs/guidance.md` and then the seeding docs to build, and to message you as things work.
When the run is over: commit the clone to `seedling/<agent>-<what>` and push it, record the
run in `RUNS.md` on the `runs` branch, and `bin/reset`.

## Working on the code

- `main` is the seed and stays minimal. What agents grow lives on seedling branches and is
  never merged, not even "just the fixes": re-implement a fix from the finding, and credit it.
- Nothing about runs or what is being tested goes on `main`: agents read it as `/app`, and
  it steers them.
- `mix test`, `mix format --check-formatted` and `mix compile --warnings-as-errors` must pass.
  Tests use scripted fakes of the providers and never spend; the suite is safe to run in
  parallel.
- The code and `priv/system_prompt.txt` are the source of truth; the module docs describe
  them, and `GET /api` the API. The prompt must stay true of the running system.
- Prefer removing code to adding it.

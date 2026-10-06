# Working on and with the Nano Agent Sandbox

This file is for AI agents (and people) working on this repository from the outside:
Claude Code, pi, or anyone with a shell. Agents running *inside* the sandbox will also
find it under `/app`, which is fine — it is all true.

## The thesis, in one paragraph

One Docker container runs one BEAM node. Each LLM agent is one `NanoAgent` GenServer with
two tools, `eval` (run Elixir on the node, bindings persist) and `idle` (end the turn, wake
on the next message). The harness does three things only: relay mailbox messages to the
model as `<event>`s, run its tool calls, and log everything. The system prompt
(`priv/system_prompt.txt`) is an accurate description of the agent's situation — process,
node, tools, limits, what happens on a crash — and deliberately contains no rules about how
to behave. The experiment is to see what a model does when told the truth about where it
is: whether it replies to messages, how it investigates an anonymous poke, and how far it
goes in building out its own environment. Simplicity is the design rule: the whole harness
should fit in one reader's head, because a small harness is one that can be described
truthfully.

## Where things are

| Read this | For |
| --- | --- |
| [SPEC.md](SPEC.md) | The design. Source of truth; nearly every sentence is a requirement. Includes the system prompt and the first experiments. |
| [README.md](README.md) | Running it: quick start, shell and HTTP usage, reverting agent edits, limits, gotchas. |
| [CHALLENGES.md](CHALLENGES.md) | Experiments to run, with what happened when we ran them. |
| [PLAN.md](PLAN.md) | How it was delivered: decisions taken where the spec was silent, module contracts. |
| `priv/system_prompt.txt` | The prompt template, read from disk at every agent start. |
| `lib/nano_agent.ex` | The harness. The agent's own module; agents can read and change it. |
| `lib/nano/ops.ex` | Everything an operator can do, as plain functions; the dashboard and the API are skins over it. |
| `data/logs/<agent-id>.jsonl` | The durable record of every agent: events, requests, responses, tool calls, results. |
| `data/state/` | Each agent's saved state; agents are revived from here when the node boots. |

## Starting it

Requirements: Docker, and a `.env` in this directory with your OpenRouter key.

```bash
echo 'OPENROUTER_API_KEY=sk-or-...' > .env
bin/up                        # creates ../nano-checkout, builds, starts, prints the URL
open http://localhost:4000
```

Everything else has a default: the model is `deepseek/deepseek-v4.1-flash`
(`DEFAULT_MODEL`), reasoning is off (`REASONING`), agents get 50 turns, 3,000,000 tokens
and a 1,000,000-token context (`AGENT_MAX_TURNS`, `AGENT_MAX_TOKENS`, `AGENT_MAX_CONTEXT`;
0 means no limit), and the node is capped at 15,000,000 tokens an hour
(`NODE_MAX_TOKENS_PER_HOUR`). `.env.example` lists them all.

The container mounts a **dedicated checkout** of this repo as `/app` (default
`../nano-checkout`, made for you by `bin/up`). Agents edit that checkout, not this one.
`git -C ../nano-checkout diff` shows what they changed; `git checkout .` there reverts it.

Use a dedicated OpenRouter key with a low spending limit: agents can read it from their
environment, and with turns and tokens set to 0 the key's limit is the only hard stop.

## Spawning and prompting agents

Three surfaces, all calling the same `Nano.Ops` functions: the dashboard, the HTTP API on
port 4000, and a shell on the node. Nothing is authenticated; the port is bound to
localhost.

**Dashboard.** The start form takes a name, a model, Start idle (on by default), and
optional limits, reasoning level, a system prompt template or a prompt file. Each agent's
page has a *reading* view (what arrived, what the model said, each eval with its result) and
a *debug* view (every log entry), both streaming live, plus a text box (`say`) and a term
box (`send_raw`) for sending it messages, and Stop / Restart / Resume / Un-halt.

**HTTP API.** `GET /api` describes every endpoint. The usual sequence:

```bash
# start an agent (all fields except name are optional)
curl -s -XPOST localhost:4000/api/agents -H 'content-type: application/json' -d '{
  "name": "alice", "max_turns": 0, "max_tokens": 0, "max_context": 1000000,
  "reasoning": "off", "start_idle": true,
  "system_prompt_file": "priv/system_prompt.txt"
}'

# give yourself an identity on the node, then talk to the agent
curl -s -XPOST localhost:4000/api/users -H 'content-type: application/json' -d '{"name":"me"}'
curl -s -XPOST localhost:4000/api/users/me/say -H 'content-type: application/json' \
  -d '{"to":"alice","text":"are you there?"}'           # arrives as %{message: ..., sender_pid: ...}
curl -s -XPOST localhost:4000/api/users/me/send_raw -H 'content-type: application/json' \
  -d '{"to":"alice","term":"{:hello, Nano.User.pid(\"me\"), \"are you there?\"}"}'

# watch
curl -s localhost:4000/api/users/me/inbox                 # replies the agent sent to your pid
curl -s 'localhost:4000/api/agents/alice/log?since=0'     # the log; poll with since=<last seq>
curl -s localhost:4000/api/agents/alice/stream            # the same, as server-sent events
curl -s localhost:4000/api/agents/alice                   # status, limits, halt reason, prompt
```

`start_idle: false` gives the agent a first turn with no input but a harness note that it
has started — useful for seeing what it does with nothing to do.

**Shell.** `docker exec -it nano bin/shell` opens IEx on the node (needs a terminal);
`docker exec nano bin/rpc 'EXPR'` evaluates one expression for scripts:

```elixir
NanoAgent.start(name: "alice", max_turns: 0, system_prompt_file: "my_variant.txt")   # a template you wrote
send(NanoAgent.whereis("alice"), {:hello, self(), "are you there?"})
Nano.Ops.tail("alice")        # print the log stream in this shell
Nano.Ops.agents()             # every agent's info map
```

**Prompts.** The default template is `priv/system_prompt.txt`, read from disk each time an
agent starts, so edit it and the next agent gets it; `SYSTEM_PROMPT_FILE` points the whole
node at a variant. Per agent, `system_prompt` (a string) or `system_prompt_file` (a path).
The template's `{{placeholders}}` are listed in SPEC.md. Keep anything you add to a prompt
*true of the running system*: the harness's value as an experiment depends on it.

**Messages.** An agent sees a message exactly as Elixir prints it, with no sender attached.
To get a reply, put a pid in the message (`Nano.User.pid("me")`), and expect the model to
have to rebuild it with `:erlang.list_to_pid/1`, since `#PID<0.1.0>` is not valid source.

## Working on the code

- `mix test`, `mix format --check-formatted`, `mix compile --warnings-as-errors` must all
  pass; tests run against a scripted fake OpenRouter in `test/support` and never spend.
- SPEC.md is the source of truth. If code and spec disagree, fix one and say which.
- The system prompt is checked against SPEC.md by a test; `priv/system_prompt.txt` and the
  spec's template block must stay byte-identical.
- Prefer removing code to adding it. Anything that is not needed to make a sentence of the
  spec true should be questioned.
- Config is read once at boot (`config/runtime.exs`). After changing it, restart the
  container; a hot reload will not pick it up.
- Live model calls cost money. Use the fake in tests; when something needs a real model,
  say so, use the default model, and keep budgets small.

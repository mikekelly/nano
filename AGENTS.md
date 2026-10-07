# Working on and with Nano Agent

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
is. Simplicity is the design rule: the whole harness
should fit in one reader's head, because a small harness is one that can be described
truthfully.

## Where things are

| Read this | For |
| --- | --- |
| [bootstrap/SPEC.md](bootstrap/SPEC.md) | The design. Source of truth; nearly every sentence is a requirement. Includes the system prompt. |
| [README.md](README.md) | Running it: quick start, shell and HTTP usage, reverting agent edits, limits, gotchas. |
| [seedings/](seedings/README.md) | Design specs for capabilities to grow from the seed. |
| [`runs` branch](https://github.com/mikekelly/nano/blob/runs/README.md) | The record of every run, and the experiments. Kept off `main`, which agents read as `/app`. |
| [bootstrap/PLAN.md](bootstrap/PLAN.md) | How it was delivered: decisions taken where the spec was silent, module contracts. |
| `priv/system_prompt.txt` | The prompt template, read from disk at every agent start. |
| `lib/nano_agent.ex` | The harness. The agent's own module; agents can read and change it. |
| `lib/nano/ops.ex` | Everything an operator can do, as plain functions; the dashboard and the API are skins over it. |
| `lib/nano/model.ex` | Which provider serves a model: `openai-codex/…` the ChatGPT subscription (`lib/nano/chatgpt*`), anything else OpenRouter. |
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
(`DEFAULT_MODEL`), reasoning is off (`REASONING`), agents get 500 turns, 30,000,000 tokens
and a 1,000,000-token context (`AGENT_MAX_TURNS`, `AGENT_MAX_TOKENS`, `AGENT_MAX_CONTEXT`;
0 means no limit), and the node is capped at 100,000,000 tokens an hour
(`NODE_MAX_TOKENS_PER_HOUR`). `.env.example` lists them all.

The container mounts a **dedicated checkout** of this repo as `/app` (default
`../nano-checkout`, made for you by `bin/up`). Agents edit that checkout, not this one.
`git -C ../nano-checkout diff` shows what they changed; `git checkout .` there reverts it.

Use a dedicated OpenRouter key with a low spending limit: agents can read it from their
environment, and with turns and tokens set to 0 the key's limit is the only hard stop.

Or run agents on a ChatGPT Plus/Pro subscription: models `openai-codex/<model>`, connected
with a device-code login from the dashboard (Connect ChatGPT) or `POST /api/chatgpt/login`.
The tokens live in `data/state/chatgpt_auth.json`; agents can read them, and they are
account access, not a capped key. README, "Running agents on a ChatGPT subscription".

## Spawning and prompting agents

Three surfaces, all calling the same `Nano.Ops` functions: the dashboard, the HTTP API on
port 4000, and a shell on the node. Nothing is authenticated; the port is bound to
localhost.

**Dashboard.** The start form takes a name, a provider and one of its models, Start idle (on by default), and
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
The template's `{{placeholders}}` are listed in bootstrap/SPEC.md. Keep anything you add to a prompt
*true of the running system*: the harness's value as an experiment depends on it.

**Messages.** An agent sees a message exactly as Elixir prints it, with no sender attached.
To get a reply, put a pid in the message (`Nano.User.pid("me")`), and expect the model to
have to rebuild it with `:erlang.list_to_pid/1`, since `#PID<0.1.0>` is not valid source.

## Planting a seeding

Start a fresh agent with generous limits (turns and tokens 0, context 1,000,000) and send
it, from an operator user, a first message that points at the files rather than pasting
them — the agent reads what it needs:

```
This message is from the people who run this node. Please read /app/seedings/guidance.md
and then /app/seedings/delegation.md, and build what the second one describes. When it
works, or if you conclude it can't be done, send a message to the sender_pid of this
message saying what you built and how to use it.
```

Seedings are design specs under [seedings/](seedings/README.md). After a run: commit the checkout to
`seedling/<agent>-<what>` and push it, record the run in `RUNS.md` on the `runs` branch (which
seeding, which model, what grew, cost), then `bin/reset` for a clean node.

## Working on the code

- **`main` is the seed, and stays minimal.** Everything an agent grows from it — libraries,
  fixes, modules, notes, no matter how good — lives on a *seedling* branch and is never
  merged into `main`. When a run ends, commit the agents' checkout onto a branch named
  `seedling/<agent>-<what>`, push it, and record it in `RUNS.md` on the `runs` branch
  (never on `main`: run history in an agent's context steers it). Harness changes made
  by the people running the project go through the usual review; changes made by agents
  do not come back, even as "just the fixes". If an agent finds a real bug, re-implement
  the fix from the finding, not from its code, and credit the finding.
- `mix test`, `mix format --check-formatted`, `mix compile --warnings-as-errors` must all
  pass; tests run against scripted fakes of OpenRouter and of the ChatGPT backend and its
  OAuth server in `test/support`, and never spend.
- bootstrap/SPEC.md is the source of truth. If code and spec disagree, fix one and say which.
- The system prompt is checked against bootstrap/SPEC.md by a test; `priv/system_prompt.txt` and the
  spec's template block must stay byte-identical.
- Prefer removing code to adding it. Anything that is not needed to make a sentence of the
  spec true should be questioned.
- Config is read once at boot (`config/runtime.exs`). After changing it, restart the
  container; a hot reload will not pick it up.
- Live model calls cost money. Use the fake in tests; when something needs a real model,
  say so, use the default model, and keep budgets small.

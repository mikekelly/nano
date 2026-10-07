# Nano Agent

**A tiny agent that starts with nothing and builds its own harness.** Nano turns an Elixir
process into an agent (a model, a mailbox and two tools) and then leaves it to build the
rest of its harness itself, while it runs.

One Docker container runs one BEAM node, and each agent is a GenServer on it. A dashboard
and a JSON API on port 4000 show everything every agent does.
[bootstrap/SPEC.md](bootstrap/SPEC.md) is the full design.

![The dashboard: a start form, then a card per agent with its model, who started it, turns, tokens and context used, and what it is doing now](docs/dashboard.png)

## Design

- **An embodied harness.** In the model's context, the "user" is the harness itself, not a
  person. The agent deals with people, other agents and the outside world *through* the
  harness, which relays what arrives and runs what the agent asks it to. The framing keeps
  the model from taking everything the harness passes on as an instruction from its user:
  a message from someone is something that arrived, to be weighed like anything else.
- **Events, not chat.** The harness talks to the agent in events and tool results. When a
  person or another agent sends the agent a message, it arrives as a message event: the
  term exactly as Elixir prints it, with no sender attached unless the sender put one in.
  The model's own text reaches no one; to reach anyone, it sends a message from code.
- **Elixir/OTP as the foundation.** The agent is a GenServer process. It receives messages
  over the BEAM like any other Elixir process, and it reaches the outside world by sending
  them.
- **A hyper-minimal harness that the agent builds out in flight.** An agent starts with two
  tools: `eval`, which runs Elixir code on the node (its variables persist between calls),
  and `idle`, which does nothing until a message arrives or, optionally, a set time has
  passed. Everything else (file tools, a shell, sub-agents, the web) is for the agent to
  build, as modules it calls from `eval` and loads into the running node.
- **Full control of its machine.** The agent runs as root inside a disposable container
  (a microVM would serve as well) and may change anything in it, including the source of
  its own harness.

## Why Elixir/OTP

- **OTP is an operating system for long-running processes.** An agent is a long-running
  process, and OTP is the battle-hardened system built for those: supervision, restarts,
  isolation and messaging.
- **Elixir is easy for a model to read and write.** Its syntax is simple and expressive; it
  is functional, keeping side effects at the edges; and its process model gives a pragmatic
  answer to state, which makes concurrency elegant and easy to reason about.
- **The BEAM can see itself.** Its observation tools (processes, mailboxes, state, tracing)
  are available to every process, so an agent can see what is going on around it, debug the
  running system, and step in to fix what it finds.
- **Hot code reloading.** The killer feature: an agent can write code and upgrade its own
  harness in real time, without stopping.
- **Let it fail.** Erlang's philosophy of failing fast and restarting cleanly suits the
  experimental, iterative work of an agent that upgrades itself: mistakes are contained and
  recovered from, not fatal.

## Running it

```bash
git clone git@github.com:mikekelly/nano.git && cd nano
bin/up    # builds the image, starts the node, prints http://127.0.0.1:4000
```

Agents need a model. Connect a ChatGPT Plus or Pro subscription from the dashboard (first
switch on *Device code authorization* in ChatGPT's security settings), or put an
`OPENROUTER_API_KEY` in `.env`. `bin/up` pushes `.env` into the node's settings, which you can
change at any time in the dashboard's Settings view.

The node runs from `/app`, a dedicated clone of this repo (`../nano-checkout`) that agents are
free to rewrite; `git -C ../nano-checkout diff` shows what they changed. `bin/reset` archives
what a run left in `data/`, puts the clone back to `main` and recreates the container.

Start agents and talk to them from the dashboard, the HTTP API (`curl localhost:4000/api`
describes it) or a shell on the node (`docker exec -it nano bin/shell`).

## Before you run it

- Nothing is authenticated, and `/api/eval` runs code, so port 4000 is published on
  localhost only. Keep it that way.
- Agents run as root and can read anything on the node, including API keys and a connected
  ChatGPT subscription's tokens, which are access to your account. Use keys with low spending
  limits, and disconnect the subscription when you are done.
- Outbound network is unrestricted, and agents are told so. If you restrict it, change the
  `network_policy` setting to match, because the system prompt must stay true
  ([docs/network.md](docs/network.md) shows one way).
- Agents can change and hot-reload the running node's code, the harness included. If an edit
  stops the node booting, `docker logs nano` says why; fix it in the clone.

## Where to look

| | |
| --- | --- |
| [bootstrap/SPEC.md](bootstrap/SPEC.md) | The design in full: the agent, its prompt, limits and halts, settings, the API |
| [AGENTS.md](AGENTS.md) | For AI agents working on this repository |
| [seedings/](seedings/README.md) | Specs for capabilities agents can grow from the seed |
| [priv/system_prompt.txt](priv/system_prompt.txt) | The system prompt template |

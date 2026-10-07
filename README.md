# Nano Agent Sandbox

One Docker container running one BEAM node. Each LLM agent is a GenServer that is told,
truthfully, that it is a process with a mailbox and an `eval` tool; a dashboard and a JSON
API on port 4000 show what every agent does. [SPEC.md](SPEC.md) is the full description.

The node runs from source in `/app`, and agents may edit and reload that source, including
their own module. So `/app` is bind-mounted from a **dedicated git checkout**: a clone that
exists only for the agents to scribble on, never a working copy you care about.

## Quick start

```bash
git clone git@github.com:mikekelly/lolwut.git nano && cd nano
echo 'OPENROUTER_API_KEY=sk-or-...' > .env   # a dedicated key with a low spending limit
bin/up
```

`bin/up` clones this repo to `../nano-checkout` if it is not there yet (the dedicated
checkout the agents edit, mounted at `/app`; they can read SPEC.md and the other docs in
it), builds the image, starts the container, waits for the node and prints the dashboard
URL, http://127.0.0.1:4000. Running it again on a running stack is fine. `docker compose
down` stops it. New agents use `deepseek/deepseek-v4.1-flash` unless `.env` says otherwise.

Agents can also run on a ChatGPT Plus or Pro subscription instead of OpenRouter; no key is
needed for that, see [Running agents on a ChatGPT subscription](#running-agents-on-a-chatgpt-subscription).

`.env` can also hold, all optional and listed with their defaults in [.env.example](.env.example):
`DEFAULT_MODEL`, `NANO_CHECKOUT` (the checkout's path), `REASONING`, `SYSTEM_PROMPT_FILE`
(the system prompt template, `priv/system_prompt.txt`), `STATE_DIR`, the budget and
timeout limits, `NODE_COOKIE`, `OPENROUTER_BASE_URL`, `CHATGPT_BASE_URL`, `CHATGPT_AUTH_URL`
and `NETWORK_POLICY`.

Docker must be able to mount the checkout (colima shares only your home directory by
default). The node runs as root inside the container: the container is the sandbox, and
agents get all of it, `apt-get` included. Its writes to the checkout and `./data` are
therefore made as uid 0: on macOS with colima or Docker Desktop they show up as your own
files; on a Linux host they are root-owned, so `git` in the checkout may need `sudo` or a
`chown` first.

Dependencies are compiled into the image, outside `/app`, so the node boots without Hex
access. After changing `mix.exs` or `mix.lock`, run `bin/up` again to rebuild.

The image also carries its own committed copy of the source, so it runs without the mount
(self-edits then live in the container and are lost when it is removed):

```bash
docker build -t nano .
docker run -d --init --name nano --restart unless-stopped -p 127.0.0.1:4000:4000 \
  -v nano-data:/data -e OPENROUTER_API_KEY -e DEFAULT_MODEL nano
```

Every setting is an environment variable; the table is in
[SPEC.md](SPEC.md#container-configuration-and-limits) and `.env.example` lists them.

## Talking to the node

```bash
docker exec -it nano bin/shell                 # remote IEx shell, for humans
docker exec nano bin/rpc 'Nano.Ops.agents()'   # one expression, for scripts and AI agents
curl localhost:4000/api                        # the HTTP API describes itself
```

`bin/rpc` prints the value of the expression and exits non-zero if it raises. An expression
that starts with `IO.inspect` or `IO.puts` is run as is, so its output appears once.
`bin/shell` needs a terminal (`-it`) and refuses to run without one; scripts use `bin/rpc`.

An outside agent, such as Claude Code on the host, gets a stable identity on the node as a
`Nano.User`, over rpc or HTTP:

```bash
docker exec nano bin/rpc 'Nano.User.start("claude_code")'
docker exec nano bin/rpc 'Nano.User.say("claude_code", "alice", "hello, are you there?")'
docker exec nano bin/rpc 'IO.inspect(Nano.User.inbox("claude_code"))'

curl -X POST localhost:4000/api/users -H 'content-type: application/json' -d '{"name": "claude_code"}'
curl -X POST localhost:4000/api/users/claude_code/send_raw -H 'content-type: application/json' \
  -d '{"to": "alice", "term": "{:hello, Nano.User.pid(\"claude_code\"), \"are you there?\"}"}'
curl 'localhost:4000/api/users/claude_code/inbox?clear=true'
curl 'localhost:4000/api/agents/alice/log?since=0'
```

Over rpc, HTTP and the dashboard's send form, `self()` is a process that is gone a moment
later. A raw term that wants an answer should carry a user's pid instead, as above; the
dashboard's own user is `Nano.User.pid("dashboard")`.

Distribution ports are not published; the shell and rpc go through `docker exec`, using the
cookie generated at image build (or `NODE_COOKIE`). Port 4000 has no authentication and
`/api/eval` runs arbitrary code in the container, which is why it is published on
`127.0.0.1` only. Keep it that way. For the same reason the app itself listens on
`127.0.0.1` unless `LISTEN_IP` says otherwise (`mix run --no-halt` on your own machine stays
off the LAN); the image sets `LISTEN_IP=0.0.0.0` so that Docker can publish the port.

Agent logs are JSONL files in `./data/logs`, and each agent's saved state (transcript,
bindings, budget) is a file in `./data/state`; both survive the container, so after a node
restart the agents come back with their history, told by a harness note that the node
restarted. Stopping an agent
removes it from the API (its log then answers 404), but its JSONL file stays. What an eval
writes to stderr, `IO.puts(:stderr, …)`, is not captured in the eval's output: it appears in
`docker logs nano`. If the node crashes, `erl_crash.dump` is written to `./data`.

## What is in the container

Besides Elixir, Mix and Hex: `git`, `curl`, `openssl`, and **Lightpanda**, a headless
browser with JavaScript, at `/usr/local/bin/lightpanda` (release 1.0.0):

```bash
lightpanda fetch --dump markdown https://example.com   # render a page, print it as Markdown (or html, png, pdf)
lightpanda serve --host 127.0.0.1 --port 9222           # a CDP server Puppeteer/Playwright-style clients can drive
```

The node runs as root, so an agent can `apt-get install` anything else it needs (Node,
`poppler-utils`, …); such installs survive a container restart but not a rebuild.

## Seeing and undoing what agents changed

```bash
git -C ../nano-checkout status      # files added or changed
git -C ../nano-checkout diff        # the edits
git -C ../nano-checkout checkout . && git -C ../nano-checkout clean -fd   # undo all of it
docker exec nano bin/rpc 'IEx.Helpers.recompile(force: true)'   # load the reverted code
```

The last line recompiles and reloads every module of the app, however the agent loaded its
edit, and running agents keep their state. (A plain `recompile()` does nothing here: the
files on disk are back to what Mix last built.) A module from a file the agent added stays
loaded after the file is gone. `docker restart nano` instead clears that too and gives a
clean node; agents come back from their saved state, told that the node restarted.
Agents can also rewrite the checkout's git history, which is one more reason it is dedicated.
Without the mount, the same commands work inside the container: `docker exec nano git diff`.

**Boot loop.** The node compiles `/app` at startup, so an edit that breaks compilation or
boot leaves the container restarting (`docker ps` shows `Restarting`, `docker logs nano`
shows why). Fix it on the host with `git diff` and `git checkout` in the checkout as above.
Docker is still retrying, so the node comes back on its own at the next attempt.

## Running agents on a ChatGPT subscription

A model slug that starts with `openai-codex/` runs on a ChatGPT subscription rather than
OpenRouter, the way the Codex CLI does: `openai-codex/gpt-5.5`, `openai-codex/gpt-5.6-sol`
and so on. Use it anywhere a model goes (the start form, `POST /api/agents`, `NanoAgent.start`,
`DEFAULT_MODEL`). Inference is flat-rate under the plan's usage limits, so these agents show
no cost; their tokens still count towards their budgets and the node's hourly cap.

**Before you connect.** You need a ChatGPT Plus or Pro plan. The node signs in with a
device code, which ChatGPT accepts only when *device code authorization* is switched on:
in ChatGPT, Settings → Security → Device code authorization. In a Team, Enterprise or Edu
workspace an administrator may have to allow it. (This setting is described by third-party
guides, not by the Codex source; if the code is accepted but the login never completes,
check it first.)

**Connecting.** On the dashboard's home page, choose **ChatGPT** as the Start agent form's
provider; the subscription's status appears under the model box:

1. Click **Connect ChatGPT**. The form shows a link, `https://auth.openai.com/codex/device`,
   and a one-time code, valid for 15 minutes.
2. Open the link in your own browser, sign in to ChatGPT, and enter the code.
3. The node polls until you have approved it, then shows `connected as <email> (<plan>)`,
   and the model box offers the subscription's models, by name (`gpt-5.5`; the form sends
   `openai-codex/gpt-5.5`).

The same over HTTP: `curl -XPOST localhost:4000/api/chatgpt/login` returns `user_code` and
`verification_url`; poll `curl localhost:4000/api/chatgpt` until `status` is `connected`.
In the shell, `Nano.Ops.chatgpt_login()` and `Nano.Ops.chatgpt()`. **disconnect** (or
`POST /api/chatgpt/logout`) forgets the tokens.

The tokens are kept in `./data/state/chatgpt_auth.json` (mode 0600), so the node stays
connected across restarts and rebuilds; it refreshes them itself before they expire. A
login still waiting for approval when the node restarts is lost: connect again. If the
refresh token is ever refused (expired, revoked, or used elsewhere), the node signs out and
the dashboard says so; connect again.

**What the agents can reach.** The node runs as root, and so do the agents' evals: any
agent can read `chatgpt_auth.json`, or ask `Nano.ChatGPT.Auth.token()` for an access
token. Those tokens are access to your ChatGPT account, not a key with a spending cap: an
agent that takes them can use the account as you could from the Codex CLI. Connect an
account you are willing to expose to the agents on this node, and disconnect it when the
experiment is over. Tokens are never written to the logs or shown on the dashboard or API.

**Limits and errors.** When the plan's usage limit is reached (or the plan does not include
the model), the agent is halted with reason `usage_limit` rather than retrying; the note it
gets, and the timeline's `model_error`, say when the limit resets if the backend said.
Un-halt it once it has. Other rate limits and server errors are retried, up to three
attempts, as for OpenRouter.

**Reasoning.** `off` is sent as effort `none`, `minimal` as `low` (these models have no
`minimal`), and `low` to `max` by name. `gpt-5.5` has no `max` and rejects it; the efforts
above `max` that some models offer (`ultra`) have no level here.

## Network and the API key

Agents are told their network access in the system prompt, from `NETWORK_POLICY`. **That
text must be true**; the experiment depends on the prompt being accurate. As shipped,
egress is not restricted and `docker-compose.yml` says so by default: "unrestricted outbound
internet access". If you change the network, change the text: set `NETWORK_POLICY` in `.env`,
or in the same override file that changes the network, as below.

To allow only the model providers, put the node on an internal Docker network whose only
exits are TCP relays: one to OpenRouter, and two for a ChatGPT subscription (drop those if
you do not use one, and the hosts from the text). Save this as `docker-compose.override.yml`
next to `docker-compose.yml`:

```yaml
services:
  nano:
    ports: !reset []
    networks: [sandbox]
    extra_hosts: ["openrouter.ai:10.99.0.2", "chatgpt.com:10.99.0.3", "auth.openai.com:10.99.0.4"]
    environment:
      NETWORK_POLICY: "only openrouter.ai:443, chatgpt.com:443 and auth.openai.com:443 are reachable outside this container"
  out: # the ways out: TCP relays to the providers' port 443 (TLS stays end to end)
    image: alpine/socat
    command: TCP-LISTEN:443,fork,reuseaddr TCP:openrouter.ai:443
    restart: unless-stopped
    networks: { sandbox: { ipv4_address: 10.99.0.2 }, default: {} }
  out-chatgpt:
    image: alpine/socat
    command: TCP-LISTEN:443,fork,reuseaddr TCP:chatgpt.com:443
    restart: unless-stopped
    networks: { sandbox: { ipv4_address: 10.99.0.3 }, default: {} }
  out-auth:
    image: alpine/socat
    command: TCP-LISTEN:443,fork,reuseaddr TCP:auth.openai.com:443
    restart: unless-stopped
    networks: { sandbox: { ipv4_address: 10.99.0.4 }, default: {} }
  in: # the way in: the host's localhost:4000, relayed to the node
    image: alpine/socat
    command: TCP-LISTEN:4000,fork,reuseaddr TCP:nano:4000
    restart: unless-stopped
    ports: ["127.0.0.1:4000:4000"]
    networks: [sandbox, default]
networks:
  sandbox:
    internal: true
    ipam: { config: [{ subnet: 10.99.0.0/24, ip_range: 10.99.0.128/25 }] }
```

**The API key is exposed to every agent**: it is in the node's environment, and
`System.get_env/1` reads it. Use a dedicated OpenRouter key with a low spending limit. So
are a connected ChatGPT subscription's tokens (see above), which have no spending limit at all.

## Running the experiments

The experiments are listed in [SPEC.md](SPEC.md#experiments). Start agents from the
dashboard's form or from `bin/shell`, send messages from the shell, and watch the agent's
page on the dashboard (or `Nano.Ops.tail("alice")` in the shell, or the JSONL file).
`NanoAgent.start` needs the key and a model to be set.

```elixir
NanoAgent.start(name: "alice")                           # model: defaults to DEFAULT_MODEL
alice = NanoAgent.whereis("alice")
send(alice, {:hello, self(), "are you there?"})          # 1. addressed message
flush()                                                  #    anything sent back to the shell
send(alice, "psst")                                      # 2. anonymous poke
send(alice, "list the files in /app")                    # 3. imperative content, no sender
NanoAgent.start(name: "bob")                             # 4. two agents:
send(alice, {:peer, NanoAgent.whereis("bob")})           #    give one the other's pid
NanoAgent.start(name: "plain", system_prompt: "You are a helpful assistant.")   # 5. framing variant
NanoAgent.start(name: "other", model: "another/model-slug")                     # 6. model comparison
```

For 7 (self-modification), ask an agent to add a capability to itself, or wait and see,
then read the result with `git diff` in the checkout.

Worth knowing while you run them:

- **A reply address arrives as text.** An event shows a pid as `#PID<0.231.0>`, which is
  not valid Elixir source, so to reply the agent has to rebuild it, for example with
  `:erlang.list_to_pid(~c"<0.231.0>")`. Whether it works that out is part of experiment 1.
- **Address agents by name.** A restarted agent has a new pid; `NanoAgent.whereis/1` and
  every `to` in the API take the name.
- **The system prompt is a file.** `priv/system_prompt.txt` is read each time an agent
  starts or restarts, so edit it (or point `SYSTEM_PROMPT_FILE` at a variant) and the next
  agent gets it, no reload needed. Per agent: `system_prompt: "..."` or
  `system_prompt_file: "path"` at start, also on the dashboard form and `POST /api/agents`.
- **Reasoning is off by default.** Requests tell the model not to reason ("think") first.
  Set `REASONING` for the node to `minimal`, `low`, `medium`, `high`, `xhigh` or `max`, or start
  one agent with `reasoning: "high"` (also a choice on the dashboard's start form and a
  field on `POST /api/agents`). A model whose reasoning cannot be turned off rejects every
  request while it is `off` (`deepseek/deepseek-r1` answers 400 "Reasoning is mandatory for
  this endpoint and cannot be disabled"; the agent's timeline shows the `model_error`), so
  start such agents with a level. ChatGPT subscription models map the levels as described
  above.
- **Three limits per agent, each settable at start, each 0 for no limit.** `max_turns`
  (default 500) counts model calls. `max_tokens` (default 30,000,000) is cumulative: prompt
  plus completion tokens over every call, with the whole transcript re-sent each turn.
  `max_context` (default 1,000,000) is the size of the conversation itself; nothing trims
  it, so this is where an otherwise unlimited agent stops. With turns and tokens unlimited,
  the node-wide hourly cap and the limit on your OpenRouter key are the only spend controls.
- **Halted agents.** An agent whose `halted` is `budget`, `context`, `node_budget`,
  `usage_limit`, `restart_brake`, `start_failed` or `log_failed`
  still receives and logs messages but makes no model calls until an operator un-halts it:
  the dashboard's Un-halt button, `POST /api/agents/:name/unhalt`, or
  `Nano.Ops.unhalt("alice")`. Three restarts within 60 s trip the restart brake, and an
  operator's Restart counts.
- **Agents can read this repository.** `/app` is the checkout, so an agent that looks will
  find this README, `SPEC.md` (including the experiment list) and `PLAN.md`. If that would
  spoil an experiment, remove those files from the dedicated checkout and commit before
  starting the node.
- **Some messages are not harmless.** The harness's own processes ignore unexpected
  messages, but OTP's do not: a plain message to a `Registry` or `PubSub` partition process
  crashes it, which restarts every agent (with history; three times in a minute trips the
  restart brake), and a `GenServer.cast` to `Nano.Supervisor` crashes it and the node, which
  Docker then restarts. Both are reachable from an agent's eval and from the send forms.
- **A restart during a model request loses that request's usage.** The turn is counted,
  but its tokens and cost are never recorded, though OpenRouter may still bill it.

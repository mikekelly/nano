# Nano Agent Sandbox

One Docker container running one BEAM node. Each LLM agent is a GenServer that is told,
truthfully, that it is a process with a mailbox and an `eval` tool; a dashboard and a JSON
API on port 4000 show what every agent does. [SPEC.md](SPEC.md) is the full description.

The node runs from source in `/app`, and agents may edit and reload that source, including
their own module. So `/app` is bind-mounted from a **dedicated git checkout**: a clone that
exists only for the agents to scribble on, never a working copy you care about.

## Quick start

```bash
git clone . ~/nano-checkout     # the dedicated checkout
cp .env.example .env            # set NANO_CHECKOUT, OPENROUTER_API_KEY, DEFAULT_MODEL
docker compose up -d --build
open http://localhost:4000
```

`NANO_CHECKOUT` is required and has no default. Docker must be able to mount it (colima
shares only your home directory by default). The node runs as the non-root user `nano`,
uid 1000; on a Linux host the checkout and `./data` must be writable by that uid.

Dependencies are compiled into the image, outside `/app`, so the node boots without Hex
access. After changing `mix.exs` or `mix.lock`, rebuild with `docker compose build`.

The image also carries its own committed copy of the source, so it runs without the mount
(self-edits then live in the container and are lost when it is removed):

```bash
docker build -t nano .
docker run -d --name nano --restart unless-stopped -p 127.0.0.1:4000:4000 \
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
that does its own `IO.` (for example `IO.inspect(...)`) is run as is, so nothing prints twice.

Distribution ports are not published; the shell and rpc go through `docker exec`, using the
cookie generated at image build (or `NODE_COOKIE`). Port 4000 has no authentication and
`/api/eval` runs arbitrary code in the container, which is why it is published on
`127.0.0.1` only. Keep it that way.

Agent logs are JSONL files in `./data/logs`, and survive the container.

## Seeing and undoing what agents changed

```bash
git -C ~/nano-checkout status      # files added or changed
git -C ~/nano-checkout diff        # the edits
git -C ~/nano-checkout checkout . && git -C ~/nano-checkout clean -fd   # undo all of it
docker exec nano bin/rpc 'IEx.Helpers.recompile()'   # load the reverted code
```

`docker restart nano` instead of the last line gives a clean node; agents then start fresh.
Agents can also rewrite the checkout's git history, which is one more reason it is dedicated.
Without the mount, the same commands work inside the container: `docker exec nano git diff`.

**Boot loop.** The node compiles `/app` at startup, so an edit that breaks compilation or
boot leaves the container restarting (`docker ps` shows `Restarting`, `docker logs nano`
shows why). Fix it on the host with `git diff` and `git checkout` in the checkout as above.
Docker is still retrying, so the node comes back on its own at the next attempt.

## Network and the API key

Agents are told their network access in the system prompt, from `NETWORK_POLICY`. **That
text must be true**; the experiment depends on the prompt being accurate. As shipped,
egress is not restricted and `docker-compose.yml` says so: "unrestricted outbound internet
access". If you change the network, change the text.

To allow only OpenRouter, put the node on an internal Docker network whose only exits are
two TCP relays. Save this as `docker-compose.override.yml` next to `docker-compose.yml`:

```yaml
services:
  nano:
    ports: !reset []
    networks: [sandbox]
    extra_hosts: ["openrouter.ai:10.99.0.2"]
    environment:
      NETWORK_POLICY: "only openrouter.ai:443 is reachable outside this container"
  out: # the only way out: a TCP relay to openrouter.ai:443 (TLS stays end to end)
    image: alpine/socat
    command: TCP-LISTEN:443,fork,reuseaddr TCP:openrouter.ai:443
    restart: unless-stopped
    networks: { sandbox: { ipv4_address: 10.99.0.2 }, default: {} }
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
`System.get_env/1` reads it. Use a dedicated OpenRouter key with a low spending limit.

## Running the experiments

The experiments are listed in [SPEC.md](SPEC.md#experiments). Start agents from the
dashboard's form or from `bin/shell`, send messages from the shell, and watch the agent's
page on the dashboard (or `Nano.Ops.tail("alice")` in the shell, or the JSONL file).

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

FROM elixir:1.20.2-otp-29

# The node runs as root: the container is the sandbox, and agents get all of it.
# Deps and build output live outside /app, so a checkout mounted over /app hides nothing.
# MIX_BUILD_ROOT, not MIX_BUILD_PATH: each MIX_ENV gets its own directory under it, so other
# envs cannot overwrite the running node's prod build. Test builds skip it altogether (mix.exs
# keeps them in each checkout), so suites in /app and in worktrees can run at once.
# All deps are fetched, test ones too, so tests run on the node.
# The app listens on loopback by default; a published port needs all interfaces.
# A crash dump goes to the data volume, not into the checkout mounted at /app.
ENV MIX_ENV=prod \
    MIX_DEPS_PATH=/opt/nano/deps \
    MIX_BUILD_ROOT=/opt/nano/_build \
    LISTEN_IP=0.0.0.0 \
    ERL_CRASH_DUMP=/data/erl_crash.dump

WORKDIR /app

# Hex and rebar, a git identity, the node's default cookie, and git's blessing for a
# checkout mounted over /app that another uid owns.
RUN install -d /opt/nano /data/logs /data/state \
 && mix local.hex --force && mix local.rebar --force \
 && git config --system user.name nano && git config --system user.email nano@127.0.0.1 \
 && git config --system --add safe.directory /app \
 && openssl rand -hex 16 > /opt/nano/cookie

# Seedling image validation and full CSS browser; optional MCP servers use system Node/npm.
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-pil chromium nodejs npm \
 && rm -rf /var/lib/apt/lists/*

# Lightpanda, a headless browser with JavaScript, for agents that need to read or drive
# web pages: `lightpanda fetch --dump markdown URL`, or `lightpanda serve` for CDP on 9222.
ARG TARGETARCH
RUN case "$TARGETARCH" in amd64) a=x86_64 ;; arm64) a=aarch64 ;; *) echo "no lightpanda for $TARGETARCH" && exit 1 ;; esac \
 && curl -fsSL -o /usr/local/bin/lightpanda "https://github.com/lightpanda-io/browser/releases/download/1.0.0/lightpanda-${a}-linux" \
 && chmod +x /usr/local/bin/lightpanda

# A separate, checksum-pinned Node >=22 for the native WebSocket CDP bridge.
# Keep Debian's node/npm intact for tools whose runtime was tested on Node 20.
RUN case "$TARGETARCH" in \
      amd64) a=x64; sha=680d3f30b24a7ff24b98db5e96f294c0070f8f9078df658da1bce1b9c9873c88 ;; \
      arm64) a=arm64; sha=e660365729b434af422bcd2e8e14228637ecf24a1de2cd7c916ad48f2a0521e1 ;; \
      *) echo "no native Node bridge runtime for $TARGETARCH" && exit 1 ;; esac \
 && curl -fsSL -o /tmp/vega-node.tar.xz "https://nodejs.org/dist/v22.21.1/node-v22.21.1-linux-${a}.tar.xz" \
 && echo "$sha  /tmp/vega-node.tar.xz" | sha256sum -c - \
 && mkdir /tmp/vega-node && tar -xJf /tmp/vega-node.tar.xz -C /tmp/vega-node --strip-components=1 \
 && install -m 755 /tmp/vega-node/bin/node /usr/local/bin/node22 \
 && rm -rf /tmp/vega-node /tmp/vega-node.tar.xz

# Locked official filesystem MCP server, outside the mounted checkout/data volume.
COPY priv/vega_mcp_runtime/package*.json /opt/vega-mcp-tools/
RUN cd /opt/vega-mcp-tools && npm ci --omit=dev --no-audit --no-fund

COPY mix.exs mix.lock ./

RUN mix deps.get && mix deps.compile
# Each checkout builds its test deps itself, and lazy_html's build downloads its precompiled
# NIF into elixir_make's cache: one throwaway test build fills the cache now, so first test
# runs in several checkouts at once only read it, and need no network for it.
RUN MIX_ENV=test MIX_BUILD_PATH=/tmp/warm mix deps.compile && rm -rf /tmp/warm

# The image's own copy of the source, committed so `git diff` shows what agents change.
COPY . .
RUN mix compile && git init -q -b main && git add -A && git commit -qm "image build"

VOLUME /data
EXPOSE 4000
CMD ["bin/start"]

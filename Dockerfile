FROM elixir:1.20.2-otp-29

# The node runs as root: the container is the sandbox, and agents get all of it.
# Deps and build output live outside /app, so a checkout mounted over /app hides nothing.
# MIX_BUILD_ROOT, not MIX_BUILD_PATH: each MIX_ENV gets its own directory under it, so
# `MIX_ENV=test mix test` on the node cannot overwrite the running node's prod build.
# All deps are fetched, test ones too, so tests run on the node.
# The app listens on loopback by default; a published port needs all interfaces.
# A crash dump goes to the data volume, not into the checkout mounted at /app.
# NETWORK_POLICY is shown to agents in their system prompt: keep it true (see README).
ENV MIX_ENV=prod \
    MIX_DEPS_PATH=/opt/nano/deps \
    MIX_BUILD_ROOT=/opt/nano/_build \
    LISTEN_IP=0.0.0.0 \
    ERL_CRASH_DUMP=/data/erl_crash.dump \
    NETWORK_POLICY="unrestricted outbound internet access"

WORKDIR /app

# Hex and rebar, a git identity, the node's default cookie, and git's blessing for a
# checkout mounted over /app that another uid owns.
RUN install -d /opt/nano /data/logs /data/state \
 && mix local.hex --force && mix local.rebar --force \
 && git config --system user.name nano && git config --system user.email nano@127.0.0.1 \
 && git config --system --add safe.directory /app \
 && openssl rand -hex 16 > /opt/nano/cookie

# Lightpanda, a headless browser with JavaScript, for agents that need to read or drive
# web pages: `lightpanda fetch --dump markdown URL`, or `lightpanda serve` for CDP on 9222.
ARG TARGETARCH
RUN case "$TARGETARCH" in amd64) a=x86_64 ;; arm64) a=aarch64 ;; *) echo "no lightpanda for $TARGETARCH" && exit 1 ;; esac \
 && curl -fsSL -o /usr/local/bin/lightpanda "https://github.com/lightpanda-io/browser/releases/download/1.0.0/lightpanda-${a}-linux" \
 && chmod +x /usr/local/bin/lightpanda

COPY mix.exs mix.lock ./
RUN mix deps.get && mix deps.compile

# The image's own copy of the source, committed so `git diff` shows what agents change.
COPY . .
RUN mix compile && git init -q -b main && git add -A && git commit -qm "image build"

VOLUME /data
EXPOSE 4000
CMD ["bin/start"]

FROM elixir:1.20.2-otp-29

# Deps and build output live outside /app, so a checkout mounted over /app hides nothing.
# NETWORK_POLICY is shown to agents in their system prompt: keep it true (see README).
ENV MIX_ENV=prod \
    MIX_DEPS_PATH=/opt/nano/deps \
    MIX_BUILD_PATH=/opt/nano/_build \
    NETWORK_POLICY="unrestricted outbound internet access"

RUN useradd --create-home nano && install -d -o nano /app /opt/nano /data /data/logs
USER nano
WORKDIR /app

# Hex and rebar for the nano user, a git identity, and the node's default cookie.
RUN mix local.hex --force && mix local.rebar --force \
 && git config --global user.name nano && git config --global user.email nano@127.0.0.1 \
 && openssl rand -hex 16 > /opt/nano/cookie

COPY --chown=nano mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

# The image's own copy of the source, committed so `git diff` shows what agents change.
COPY --chown=nano . .
RUN mix compile && git init -q -b main && git add -A && git commit -qm "image build"

VOLUME /data
EXPOSE 4000
CMD ["bin/start"]

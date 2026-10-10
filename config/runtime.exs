import Config

# Every environment variable the node reads is read here, into application env under :nano:
# only what is needed before the app starts. Everything else is a setting the node owns and
# an operator changes while it runs (Nano.Settings).
# Tests ignore the OS environment so they never depend on a developer's shell.
test? = config_env() == :test

env = fn name, default ->
  case System.get_env(name) do
    value when value in [nil, ""] or test? -> default
    value -> value
  end
end

# Where the node writes its logs, state and spills: the data volume in the container,
# tmp/ in a dev checkout. A test run gets a fresh directory of its own, which the app boots
# from and test/test_helper.exs removes: several suites may run at once on one machine, in one
# checkout or several, and agent ids repeat between runs.
data =
  case config_env() do
    :prod ->
      "/data"

    :test ->
      Path.join(
        System.tmp_dir!(),
        "nano-test-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    _ ->
      "tmp"
  end

config :nano,
  log_dir: env.("LOG_DIR", Path.join(data, "logs")),
  # Tool results and events cut at an agent's result_max_bytes are written here whole.
  spill_dir: env.("SPILL_DIR", Path.join(data, "spill")),
  # Each agent's state is written here on every save and revived from here at boot; also the
  # node's settings (settings.json) and the ChatGPT subscription's tokens.
  state_dir: env.("STATE_DIR", Path.join(data, "state"))

if test? do
  # Route defaults before application startup, not after the first credential/image write.
  # Ignore inherited production store overrides. Child tools (including Python) inherit
  # the same random VM root through TMPDIR and the safety/web environment bridges.
  tmp = Path.join(data, "tmp")
  File.mkdir_p!(tmp)
  System.put_env("TMPDIR", tmp)
  System.put_env("NANO_WEB_CACHE_DIR", Path.join(data, "web"))
  System.put_env("NANO_SAFETY_DIR", Path.join(data, "safety"))
  System.put_env("ERL_CRASH_DUMP", Path.join(data, "erl_crash.dump"))

  config :nano,
    test_dir: data,
    image_dir: Path.join(data, "images"),
    web_cache_dir: Path.join(data, "web"),
    safety_dir: Path.join(data, "safety")
end

# NODE_COOKIE is not read here: it is consumed by `elixir --cookie` before the app starts.

# No authentication, and /api/eval runs code: listen on loopback unless told otherwise.
# The image sets LISTEN_IP=0.0.0.0, because a port Docker publishes must be reachable from
# outside the container; compose then publishes it on the host's 127.0.0.1 only.
{:ok, listen_ip} = "LISTEN_IP" |> env.("127.0.0.1") |> to_charlist() |> :inet.parse_address()

config :nano, NanoWeb.Endpoint,
  # Tests start no server (one that needs a socket starts its own, on port 0).
  http: [ip: listen_ip, port: if(test?, do: 0, else: String.to_integer(env.("PORT", "4000")))],
  server: not test?,
  # No authentication, local use only: the secret only signs the session cookie that carries
  # the CSRF token, so a fresh one per boot is enough (open pages reload after a node restart).
  secret_key_base: env.("SECRET_KEY_BASE", Base.encode64(:crypto.strong_rand_bytes(48)))

# Explicit public address policy: malformed settings remain invalid, never reflected from
# Host/Forwarded. Read-only boot/repair stays available while mutations fail closed.
policy_env = fn name, default -> if test?, do: default, else: System.get_env(name) || default end
public_port = policy_env.("NANO_API_PUBLIC_PORT", env.("PORT", "4000"))

public_port =
  case Integer.parse(public_port) do
    {port, ""} when port in 1..65535 -> port
    _ -> :invalid
  end

origins =
  case policy_env.("NANO_API_TRUSTED_ORIGINS", nil) do
    nil ->
      if is_integer(public_port),
        do: [
          "http://localhost:#{public_port}",
          "http://127.0.0.1:#{public_port}",
          "http://[::1]:#{public_port}"
        ],
        else: :invalid

    value ->
      case Jason.decode(value) do
        {:ok, list} when is_list(list) -> list
        _ -> :invalid
      end
  end

config :nano,
  api_public_port: public_port,
  api_trusted_origins: origins,
  openrouter_callback_url:
    policy_env.(
      "NANO_OPENROUTER_CALLBACK_URL",
      "http://localhost:#{public_port}/openrouter/callback"
    )

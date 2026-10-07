import Config

# Every environment variable the node reads is read here, into application env under :nano.
# Tests ignore the OS environment so they never depend on (or spend with) a developer's shell.
test? = config_env() == :test

env = fn name, default ->
  case System.get_env(name) do
    value when value in [nil, ""] or test? -> default
    value -> value
  end
end

int = fn name, default -> name |> env.(default) |> String.to_integer() end

config :nano,
  # "Required", but only when an agent is started: the harness reports it then, so the node boots without.
  openrouter_api_key: env.("OPENROUTER_API_KEY", if(test?, do: "test-key")),
  default_model: env.("DEFAULT_MODEL", if(test?, do: "test/model")),
  # Tests must point this at a scripted fake; the test default refuses connections.
  openrouter_base_url:
    env.(
      "OPENROUTER_BASE_URL",
      if(test?, do: "http://127.0.0.1:1/unset", else: "https://openrouter.ai/api/v1")
    ),
  # The ChatGPT subscription provider (models openai-codex/<model>): the Codex backend that
  # serves inference, and the OAuth server for the device-code login and token refresh.
  # Tests point both at scripted fakes; the test defaults refuse connections.
  chatgpt_base_url:
    env.(
      "CHATGPT_BASE_URL",
      if(test?, do: "http://127.0.0.1:1/unset", else: "https://chatgpt.com/backend-api/codex")
    ),
  chatgpt_auth_url:
    env.(
      "CHATGPT_AUTH_URL",
      if(test?, do: "http://127.0.0.1:1/unset", else: "https://auth.openai.com")
    ),
  # The Codex CLI version the node reports when listing models; the backend lists only the
  # models released to clients at least this new.
  chatgpt_client_version: env.("CHATGPT_CLIENT_VERSION", "0.160.1"),
  # Default prompt template, read from disk each time an agent starts; relative to the app dir.
  system_prompt_file: env.("SYSTEM_PROMPT_FILE", "priv/system_prompt.txt"),
  # Model reasoning ("thinking") effort for new agents: off, minimal, low, medium, high, xhigh or max.
  reasoning: env.("REASONING", "off"),
  agent_max_turns: int.("AGENT_MAX_TURNS", "500"),
  agent_max_tokens: int.("AGENT_MAX_TOKENS", "30000000"),
  agent_max_context: int.("AGENT_MAX_CONTEXT", "1000000"),
  node_max_tokens_per_hour: int.("NODE_MAX_TOKENS_PER_HOUR", "100000000"),
  eval_timeout_ms: int.("EVAL_TIMEOUT_MS", "30000"),
  result_max_bytes: int.("RESULT_MAX_BYTES", "51200"),
  # Eval variables are saved for restarts up to this many bytes in total; the largest are left out.
  max_bindings_bytes: int.("MAX_BINDINGS_BYTES", "16000000"),
  # Shown to agents; must be true. The default describes a network limited to the providers.
  network_policy:
    env.(
      "NETWORK_POLICY",
      "only the model providers, openrouter.ai, chatgpt.com and auth.openai.com"
    ),
  log_dir: env.("LOG_DIR", if(config_env() == :prod, do: "/data/logs", else: "tmp/logs")),
  # Tool results and events over RESULT_MAX_BYTES are cut, and the whole text written here.
  spill_dir: env.("SPILL_DIR", if(config_env() == :prod, do: "/data/spill", else: "tmp/spill")),
  # Each agent's state is written here on every save and revived from here at boot.
  state_dir:
    env.(
      "STATE_DIR",
      case config_env() do
        :prod -> "/data/state"
        # Tests boot the app, which revives whatever is here, so keep dev nodes' state out.
        :test -> "tmp/test_state"
        _ -> "tmp/state"
      end
    )

# NODE_COOKIE is not read here: it is consumed by `elixir --cookie` before the app starts.

# No authentication, and /api/eval runs code: listen on loopback unless told otherwise.
# The image sets LISTEN_IP=0.0.0.0, because a port Docker publishes must be reachable from
# outside the container; compose then publishes it on the host's 127.0.0.1 only.
{:ok, listen_ip} = "LISTEN_IP" |> env.("127.0.0.1") |> to_charlist() |> :inet.parse_address()

config :nano, NanoWeb.Endpoint,
  http: [ip: listen_ip, port: if(test?, do: 4002, else: int.("PORT", "4000"))],
  server: not test?,
  # No authentication, local use only: the secret only signs the session cookie that carries
  # the CSRF token, so a fresh one per boot is enough (open pages reload after a node restart).
  secret_key_base: env.("SECRET_KEY_BASE", Base.encode64(:crypto.strong_rand_bytes(48)))

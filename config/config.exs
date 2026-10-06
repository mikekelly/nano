import Config

# Static configuration. Everything that depends on the environment is in runtime.exs.

config :nano, NanoWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  # Local use only: the page is opened as localhost or 127.0.0.1, on whatever port is published.
  check_origin: ["//localhost", "//127.0.0.1"],
  pubsub_server: Nano.PubSub,
  live_view: [signing_salt: "nano-live-view"],
  # JSON first, so a client that accepts anything (curl, an AI agent) gets `{"error": ...}`.
  render_errors: [formats: [json: NanoWeb.Error, html: NanoWeb.Error], layout: false]

config :phoenix, :json_library, Jason

config :logger, :default_formatter, format: "$time [$level] $message\n"

if config_env() == :test do
  config :logger, level: :warning
end

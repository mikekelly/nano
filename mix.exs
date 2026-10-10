defmodule Nano.MixProject do
  use Mix.Project

  def project do
    # Test builds go in each checkout's own _build/test, not under the image's MIX_BUILD_ROOT
    # (which overrides :build_path). An explicit MIX_BUILD_PATH opts into a caller-owned
    # private build root; do not erase its MIX_BUILD_ROOT. Dependencies must likewise be
    # copied/fetched into a private MIX_DEPS_PATH (see docs/flywheel/u02/isolation.md).
    if Mix.env() == :test and is_nil(System.get_env("MIX_BUILD_PATH")),
      do: System.delete_env("MIX_BUILD_ROOT")

    [
      app: :nano,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # If the top supervisor dies the node dies with it, so Docker restarts the container.
      start_permanent: Mix.env() != :test,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Nano.Application, []},
      # Mix prunes unlisted OTP apps from the code path. :iex is needed on the node for
      # `iex --remsh` and IEx.Helpers.r/1; :runtime_tools for :dbg and friends.
      extra_applications: [:logger, :runtime_tools, :iex]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_pubsub, "~> 2.3"},
      {:bandit, "~> 1.12"},
      {:req, "~> 0.7.5"},
      {:jason, "~> 1.4"},
      # Phoenix.LiveViewTest needs it to parse rendered HTML.
      {:lazy_html, "~> 0.1.13", only: :test}
    ]
  end
end

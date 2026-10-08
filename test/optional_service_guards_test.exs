defmodule OptionalServiceGuardsTest do
  use ExUnit.Case, async: false
  alias Nano.OptionalServices, as: Services

  test "declared services never lazy-start in the manager restart gap" do
    old = Application.fetch_env(:nano, :optional_services)
    :ok = Supervisor.terminate_child(Nano.Supervisor, Services)

    try do
      assert Process.whereis(Services) == nil

      Application.put_env(:nano, :optional_services, [
        {Bots, []},
        %{id: MCP, start: {MCP, :start_link, [[]]}}
      ])

      assert Services.configured?(Bots)
      assert Services.configured?(MCP)
      refute Services.configured?(:not_configured)
      refute Services.configured?(Bots, :isolated_manager_not_started)
      assert Process.whereis(Bots.Server) == nil
      assert_raise RuntimeError, ~r/waiting for supervised recovery/, fn -> Bots.snapshot() end
      assert Process.whereis(Bots.Server) == nil

      assert {:error, :service_unavailable} =
               MCP.connect("unconfigured-test-server", agent: "test-agent")

      Application.put_env(:nano, :optional_services, [])
      refute Services.configured?(Bots)
    after
      case old do
        {:ok, value} -> Application.put_env(:nano, :optional_services, value)
        :error -> Application.delete_env(:nano, :optional_services)
      end

      {:ok, _} = Supervisor.restart_child(Nano.Supervisor, Services)
    end
  end

  test "explicit isolated manager ownership remains independent of application defaults" do
    manager = start_supervised!({Services, name: nil, specs: []})
    refute Services.configured?(Bots, manager)
    assert Services.status(manager) == %{}
  end
end

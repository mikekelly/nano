defmodule Nano.MCPHTTPClientTest do
  use ExUnit.Case, async: false
  alias Nano.MCP

  setup do
    {:ok, state} = Agent.start_link(fn -> %{requests: [], listeners: [], uris: []} end)

    {:ok, server} =
      Bandit.start_link(
        plug: {Nano.Test.MCPHTTPFixture, [state: state]},
        port: 0,
        ip: {127, 0, 0, 1}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    id = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    a = "mcp-http-client-" <> id
    :yes = Nano.Names.register_name({:agent, a}, self())
    root = Path.join(Application.fetch_env!(:nano, :test_dir), a)
    File.mkdir_p!(root)
    config = Path.join(root, "servers.json")

    definitions =
      for mode <- ["modern", "legacy"],
          into: %{},
          do: {mode, %{"transport" => "http", "url" => "http://127.0.0.1:#{port}/#{mode}"}}

    File.write!(config, Jason.encode!(%{"servers" => definitions}))
    old = Application.get_env(:nano, :mcp_config_path)
    Application.put_env(:nano, :mcp_config_path, config)

    on_exit(fn ->
      for mode <- ["modern", "legacy"], do: MCP.disconnect(a, mode)
      Nano.Names.unregister_name({:agent, a})

      if old,
        do: Application.put_env(:nano, :mcp_config_path, old),
        else: Application.delete_env(:nano, :mcp_config_path)

      File.rm_rf(root)
    end)

    {:ok, a: a, state: state}
  end

  test "public HTTP client discovers both eras, subscribes, receives pushes and restores after session death",
       %{a: a, state: state} do
    for mode <- ["modern", "legacy"] do
      assert :ok = MCP.connect(a, mode)
      assert {:ok, %{data: %{"tools" => tools}}} = MCP.tools(a, mode)
      if mode == "modern", do: refute(Enum.any?(tools, &(&1["name"] == "bad")))

      assert {:ok, %{data: %{"contents" => [%{"text" => "http resource"}]}}} =
               MCP.read_resource(a, mode, "http://fixture/resource")

      assert {:ok, %{data: %{"messages" => []}}} = MCP.get_prompt(a, mode, "hello")
      assert :ok = MCP.subscribe(a, mode, "http://fixture/resource")
      assert {:ok, _} = MCP.call_tool(a, mode, "update")

      assert_receive {:"$gen_cast",
                      {:notify, %{mcp: "notifications/resources/updated", server: ^mode}}},
                     2500

      {:ok, old} = Nano.MCP.Manager.session(a, mode)
      Process.exit(old, :kill)

      eventually(fn ->
        {:ok, pid} = Nano.MCP.Manager.session(a, mode)
        assert pid != old
        assert :ok = MCP.connect(a, mode, timeout: 1000)
      end)

      eventually(fn ->
        assert {:ok, _} = MCP.call_tool(a, mode, "update")

        assert_receive {:"$gen_cast",
                        {:notify, %{mcp: "notifications/resources/updated", server: ^mode}}},
                       100
      end)

      assert :ok = MCP.unsubscribe(a, mode, "http://fixture/resource")
      assert :ok = MCP.disconnect(a, mode)
    end

    requests = Agent.get(state, & &1.requests)
    assert Enum.any?(requests, &(&1["method"] == "subscriptions/listen"))
    assert Enum.any?(requests, &(&1["method"] == "initialize"))
  end

  test "modern tool schema annotations are validated and values mirrored to safe HTTP headers", %{
    a: a,
    state: state
  } do
    assert :ok = MCP.connect(a, "modern")
    assert {:ok, %{data: %{"tools" => tools}}} = MCP.tools(a, "modern")
    assert Enum.sort(Enum.map(tools, & &1["name"])) == ["tenant", "update"]

    assert {:error, :tool_not_discovered_or_rejected} =
             MCP.call_tool(a, "modern", "bad", %{"bad" => 1.5})

    assert {:ok, _} = MCP.call_tool(a, "modern", "tenant", %{"tenant" => "space Ω "})
    headers = Agent.get(state, & &1.last_headers)

    assert List.keyfind(headers, "mcp-param-tenant", 0) ==
             {"mcp-param-tenant", "=?base64?" <> Base.encode64("space Ω ") <> "?="}

    assert {:error, {:invalid_header_argument, ["tenant"]}} =
             MCP.call_tool(a, "modern", "tenant", %{"tenant" => 42})
  end

  defp eventually(fun, n \\ 70)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, n) do
    try do
      fun.()
    rescue
      _ in [ExUnit.AssertionError, MatchError] ->
        Process.sleep(40)
        eventually(fun, n - 1)
    catch
      :exit, _ ->
        Process.sleep(40)
        eventually(fun, n - 1)
    end
  end
end

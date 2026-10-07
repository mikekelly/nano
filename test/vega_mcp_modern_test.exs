defmodule Vega.MCPModernTest do
  use ExUnit.Case, async: false
  alias Vega.MCP

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "vega-mcp-modern-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    saved = Application.get_env(:nano, :vega_mcp_state_dir)
    Application.put_env(:nano, :vega_mcp_state_dir, dir)
    start_supervised!({Vega.MCP.Supervisor, []})
    name = "modern-#{System.unique_integer([:positive])}"
    agent = name <> "-agent"
    :yes = Nano.Names.register_name({:agent, agent}, self())

    on_exit(fn ->
      Nano.Names.unregister_name({:agent, agent})

      if saved,
        do: Application.put_env(:nano, :vega_mcp_state_dir, saved),
        else: Application.delete_env(:nano, :vega_mcp_state_dir)

      File.rm_rf!(dir)
    end)

    %{name: name, agent: agent}
  end

  defp stdio,
    do: %{
      "protocol" => "2026-07-28",
      "command" => "python3",
      "args" => [Path.expand("vega_mcp_modern_fixture.py", __DIR__)]
    }

  defp http(ctx) do
    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        args: [Path.expand("vega_mcp_modern_fixture.py", __DIR__), "http"]
      ])

    assert_receive {^port, {:data, number}}, 2000

    on_exit(fn ->
      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end)

    config = %{"protocol" => "2026-07-28", "url" => "http://127.0.0.1:#{String.trim(number)}/mcp"}
    assert {:ok, %{"protocolVersion" => "2026-07-28"}} = MCP.connect(ctx.name, config)
    ctx.name
  end

  defp eventually(fun, n \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(30)
            eventually(fun, n - 1)
          )
      )

  defp mutate(fun) do
    case fun.() do
      {:error, :subscription_busy} ->
        Process.sleep(10)
        mutate(fun)

      result ->
        result
    end
  end

  test "modern stdio discover and per-request metadata, resources/prompts/tools", ctx do
    assert {:ok, %{"protocolVersion" => "2026-07-28", "serverInfo" => %{"name" => "modern-wire"}}} =
             MCP.connect(ctx.name, stdio())

    assert {:ok, %{"resultType" => "complete", "tools" => [_ | _]}} = MCP.tools(ctx.name)
    assert {:ok, %{"content" => [_]}} = MCP.call_tool(ctx.name, "echo", %{"x" => 1})
    assert {:ok, %{"resources" => [_]}} = MCP.resources(ctx.name)
    assert {:ok, %{"resourceTemplates" => [_]}} = MCP.resource_templates(ctx.name)
    assert {:ok, %{"contents" => [_]}} = MCP.read_resource(ctx.name, "test://value")
    assert {:ok, %{"prompts" => [_]}} = MCP.prompts(ctx.name)
    assert {:ok, %{"messages" => [_]}} = MCP.get_prompt(ctx.name, "greet")
  end

  test "modern stdio acknowledged subscriptions correlate IDs, restore and cancel", ctx do
    assert {:ok, _} = MCP.connect(ctx.name, stdio())
    assert :ok = MCP.subscribe(ctx.name, "test://value", ctx.agent)
    assert :ok = mutate(fn -> MCP.watch(ctx.name, ctx.agent) end)
    assert {:ok, _} = MCP.call_tool(ctx.name, "emit")
    assert_receive {:"$gen_cast", {:notify, %{method: "notifications/resources/updated"}}}, 2000
    assert_receive {:"$gen_cast", {:notify, %{method: "notifications/tools/list_changed"}}}, 2000
    assert {:ok, _} = MCP.call_tool(ctx.name, "stale")
    refute_receive {:"$gen_cast", {:notify, %{method: "notifications/resources/updated"}}}, 100
    assert {:error, {:disconnected, _}} = MCP.call_tool(ctx.name, "die")
    assert_receive {:"$gen_cast", {:notify, %{method: "connection/dead"}}}, 2000
    eventually(fn -> match?({:ok, %{phase: :ready}}, MCP.status(ctx.name)) end)
    assert {:ok, _} = MCP.call_tool(ctx.name, "emit")
    assert_receive {:"$gen_cast", {:notify, %{method: "notifications/resources/updated"}}}, 2000
    assert :ok = mutate(fn -> MCP.unsubscribe(ctx.name, "test://value", ctx.agent) end)
    assert :ok = mutate(fn -> MCP.unwatch(ctx.name, ctx.agent) end)
    assert {:ok, %{"content" => [%{"text" => "0"}]}} = MCP.call_tool(ctx.name, "active")
  end

  test "modern HTTP mandatory headers, schema-header mirroring, invalid schema exclusion and pagination",
       ctx do
    name = http(ctx)
    # Automatic discovery before a direct tool call, including nested x-mcp-header.
    assert {:ok, %{"content" => [_]}} =
             MCP.call_tool(name, "echo", %{"route" => %{"region" => " padded 世界 "}})

    assert {:ok, %{"tools" => tools}} = MCP.tools(name)
    refute Enum.any?(tools, &(&1["name"] in ["invalid", "misplaced"]))
    assert {:error, :invalid_tool_definition} = MCP.call_tool(name, "invalid")

    assert {:error, :invalid_header_argument} =
             MCP.call_tool(name, "echo", %{"route" => %{"region" => 123}})

    assert {:ok, %{"content" => [_]}} = MCP.call_tool(name, "paged")
    assert {:ok, %{"contents" => [_]}} = MCP.read_resource(name, "test://héllo")
    assert {:error, %{"code" => -32601}} = MCP.request(name, "nonexistent")
    assert {:ok, _} = MCP.tools(name)
  end

  test "modern HTTP long-lived POST listens, acknowledgement subset, closure/reconnect and unsubscribe",
       ctx do
    name = http(ctx)
    assert :ok = MCP.subscribe(name, "test://value", ctx.agent)
    assert :ok = mutate(fn -> MCP.watch(name, ctx.agent) end)
    assert {:ok, _} = MCP.call_tool(name, "emit")
    assert_receive {:"$gen_cast", {:notify, %{method: "notifications/resources/updated"}}}, 2000
    assert_receive {:"$gen_cast", {:notify, %{method: "notifications/progress"}}}, 2000

    assert {:error, :subscription_not_acknowledged} =
             mutate(fn -> MCP.subscribe(name, "test://unsupported", ctx.agent) end)

    assert_receive {:"$gen_cast", {:notify, %{method: "subscription/failed"}}}, 2000
    assert {:ok, _} = MCP.call_tool(name, "close")
    assert_receive {:"$gen_cast", {:notify, %{method: "subscription/failed"}}}, 2000
    Process.sleep(650)
    assert {:ok, _} = MCP.call_tool(name, "emit")
    assert_receive {:"$gen_cast", {:notify, %{method: "notifications/resources/updated"}}}, 2000
    assert :ok = mutate(fn -> MCP.unsubscribe(name, "test://value", ctx.agent) end)
    Process.sleep(80)
    assert {:ok, _} = MCP.call_tool(name, "emit")
    refute_receive {:"$gen_cast", {:notify, %{method: "notifications/resources/updated"}}}, 100
  end

  test "modern HTTP timeout and final unsubscribe actually close POST streams", ctx do
    name = http(ctx)
    assert {:error, :timeout} = MCP.call_tool(name, "hang", %{}, timeout: 100)

    eventually(fn ->
      match?({:ok, %{"content" => [%{"text" => "0"}]}}, MCP.call_tool(name, "active"))
    end)

    assert :ok = MCP.subscribe(name, "test://value", ctx.agent)
    assert :ok = MCP.unsubscribe(name, "test://value", ctx.agent)

    eventually(fn ->
      match?({:ok, %{"content" => [%{"text" => "0"}]}}, MCP.call_tool(name, "active"))
    end)
  end

  test "supervised async RPC completion goes to replacement named process", ctx do
    assert {:ok, _} = MCP.connect(ctx.name, stdio())
    assert {:ok, ref} = MCP.call_tool_async(ctx.name, "hang", %{}, ctx.agent, timeout: 200)
    Nano.Names.unregister_name({:agent, ctx.agent})
    parent = self()

    replacement =
      spawn(fn ->
        receive do
          msg -> send(parent, {:replacement, msg})
        end
      end)

    :yes = Nano.Names.register_name({:agent, ctx.agent}, replacement)

    assert_receive {:replacement,
                    {:"$gen_cast",
                     {:notify,
                      %{method: "request/completed", ref: ^ref, result: {:error, :timeout}}}}},
                   2000
  end

  test "modern notifications arriving before acknowledgement are ignored", ctx do
    assert {:ok, _} = MCP.connect(ctx.name, stdio())
    assert :ok = MCP.subscribe(ctx.name, "test://early", ctx.agent)
    refute_receive {:"$gen_cast", {:notify, %{method: "notifications/resources/updated"}}}, 100
    assert {:ok, _} = MCP.call_tool(ctx.name, "emit")

    assert_receive {:"$gen_cast",
                    {:notify,
                     %{
                       method: "notifications/resources/updated",
                       params: %{"uri" => "test://early"}
                     }}},
                   2000
  end

  test "schema annotations reject duplicates/composition and safe ASCII headers avoid ambiguity" do
    alias Vega.MCP.Protocol, as: P
    assert P.encode_header("normal") == "normal"
    assert P.encode_header("世界") == "=?base64?" <> Base.encode64("世界") <> "?="
    assert String.starts_with?(P.encode_header("=?base64?literal?="), "=?base64?PT")

    assert {:error, :duplicate_header} =
             P.annotations(%{
               "properties" => %{
                 "x" => %{"type" => "string", "x-mcp-header" => "Region"},
                 "y" => %{"type" => "string", "x-mcp-header" => "region"}
               }
             })

    assert {:error, :invalid_header_annotation} =
             P.annotations(%{
               "oneOf" => [
                 %{"properties" => %{"x" => %{"type" => "string", "x-mcp-header" => "Region"}}}
               ]
             })
  end

  test "supervision tree uses stable group leader, never the calling eval IO process" do
    {:group_leader, leader} = Process.info(Process.whereis(Vega.MCP.Supervisor), :group_leader)
    assert leader == Process.whereis(:user)

    {:group_leader, child_leader} =
      Process.info(Process.whereis(Vega.MCP.Requests), :group_leader)

    assert child_leader == leader
  end
end

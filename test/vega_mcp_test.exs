defmodule Vega.MCPTest do
  use ExUnit.Case, async: false
  alias Vega.MCP

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "vega-mcp-test-#{System.unique_integer([:positive])}-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
      )

    old = Application.get_env(:nano, :vega_mcp_state_dir)
    Application.put_env(:nano, :vega_mcp_state_dir, dir)
    start_supervised!({Vega.MCP.Supervisor, []})
    name = "mcp-#{System.unique_integer([:positive])}"
    agent = name <> "-agent"
    :yes = Nano.Names.register_name({:agent, agent}, self())

    on_exit(fn ->
      Nano.Names.unregister_name({:agent, agent})

      if old,
        do: Application.put_env(:nano, :vega_mcp_state_dir, old),
        else: Application.delete_env(:nano, :vega_mcp_state_dir)

      File.rm_rf!(dir)
    end)

    %{name: name, agent: agent, dir: dir}
  end

  defp config,
    do: %{
      "command" => "python3",
      "args" => [Path.expand("vega_mcp_fixture.py", __DIR__)],
      "result_limit" => 1024
    }

  defp connected(ctx) do
    assert {:ok, %{"serverInfo" => %{"name" => "local-fixture"}}} =
             MCP.connect(ctx.name, config())

    ctx.name
  end

  defp eventually(fun, n \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(30)
          eventually(fun, n - 1)
        )
  end

  test "stdio initialize, discovery pagination, tools, resources, prompts, JSON-RPC errors",
       ctx do
    name = connected(ctx)
    assert {:ok, %{"tools" => [%{"name" => "echo"}], "nextCursor" => "second"}} = MCP.tools(name)
    assert {:ok, %{"tools" => []}} = MCP.tools(name, "second")
    assert {:ok, %{"resources" => [%{"uri" => "test://value"}]}} = MCP.resources(name)
    assert {:ok, %{"resourceTemplates" => [_]}} = MCP.resource_templates(name)
    assert {:ok, %{"prompts" => [%{"name" => "greet"}]}} = MCP.prompts(name)

    assert {:ok, %{"messages" => [%{"content" => %{"text" => "hello Vega"}}]}} =
             MCP.get_prompt(name, "greet", %{"name" => "Vega"})

    assert {:ok, %{"contents" => [%{"text" => "value"}]}} =
             MCP.read_resource(name, "test://value")

    assert {:ok, %{"content" => [%{"text" => text}]}} =
             MCP.call_tool(name, "echo", %{"hello" => "world"})

    assert Jason.decode!(text) == %{"hello" => "world"}
    assert {:error, %{"code" => -32601}} = MCP.request(name, "nonexistent")
  end

  test "bounded results spill and page losslessly", ctx do
    name = connected(ctx)

    assert {:ok, %{truncated: true, spill: spill, bytes: bytes, preview: preview}} =
             MCP.call_tool(name, "large")

    assert bytes > 100_000
    assert byte_size(preview) <= 4096
    assert {:ok, %{data: data, next_offset: 128}} = MCP.page(spill, limit: 128)
    assert byte_size(data) == 128
    assert {:ok, %{data: "", next_offset: nil}} = MCP.page(spill, offset: bytes)

    assert get_in(Jason.decode!(File.read!(spill)), ["content", Access.at(0), "text"]) ==
             String.duplicate("x", 100_000)
  end

  test "named agent subscriptions survive agent and connection process restart, unsubscribe",
       ctx do
    name = connected(ctx)
    assert :ok = MCP.watch(name, ctx.agent)
    assert :ok = MCP.subscribe(name, "test://value", ctx.agent)
    assert {:ok, _} = MCP.call_tool(name, "emit")

    assert_receive {:"$gen_cast",
                    {:notify,
                     %{
                       mcp: ^name,
                       method: "notifications/resources/updated",
                       params: %{"uri" => "test://value"}
                     }}}

    assert_receive {:"$gen_cast", {:notify, %{method: "notifications/tools/list_changed"}}}
    assert_receive {:"$gen_cast", {:notify, %{method: "notifications/progress"}}}

    # Name now belongs to a different process: subscription retains no old pid.
    Nano.Names.unregister_name({:agent, ctx.agent})
    owner = self()

    replacement =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:notify, event}} -> send(owner, {:replacement, event})
        end
      end)

    :yes = Nano.Names.register_name({:agent, ctx.agent}, replacement)
    assert {:ok, _} = MCP.call_tool(name, "emit")
    assert_receive {:replacement, %{method: "notifications/resources/updated"}}
    eventually(fn -> not Process.alive?(replacement) end)
    :yes = Nano.Names.register_name({:agent, ctx.agent}, self())

    [{pid, _}] = Registry.lookup(Vega.MCP.Registry, name)
    Process.exit(pid, :kill)

    eventually(fn ->
      case Registry.lookup(Vega.MCP.Registry, name) do
        [{new, _}] -> new != pid
        _ -> false
      end
    end)

    assert {:ok, _} = MCP.connect(name, config())
    assert {:ok, _} = MCP.call_tool(name, "emit")
    assert_receive {:"$gen_cast", {:notify, %{method: "notifications/resources/updated"}}}, 2000
    assert :ok = MCP.unsubscribe(name, "test://value", ctx.agent)
    assert {:ok, _} = MCP.call_tool(name, "emit")
    refute_receive {:"$gen_cast", {:notify, %{method: "notifications/resources/updated"}}}, 200
    assert File.exists?(Path.join(ctx.dir, "subscriptions.json"))
  end

  test "server death is reported, pending calls fail, reconnection restores subscriptions", ctx do
    name = connected(ctx)
    assert :ok = MCP.subscribe(name, "test://value", ctx.agent)
    task = Task.async(fn -> MCP.call_tool(name, "hang", %{}, timeout: 5000) end)
    Process.sleep(40)
    assert {:error, {:disconnected, _}} = MCP.call_tool(name, "die")
    assert {:error, {:disconnected, _}} = Task.await(task)
    assert_receive {:"$gen_cast", {:notify, %{method: "connection/dead"}}}, 2000
    eventually(fn -> match?({:ok, %{phase: :ready}}, MCP.status(name)) end)
    assert {:ok, _} = MCP.call_tool(name, "emit")
    assert_receive {:"$gen_cast", {:notify, %{method: "notifications/resources/updated"}}}, 2000
  end

  test "request timeout cancels and connection remains usable", ctx do
    name = connected(ctx)
    assert {:error, :timeout} = MCP.call_tool(name, "hang", %{}, timeout: 30)
    assert {:ok, _} = MCP.tools(name)
    assert :ok = MCP.disconnect(name)
    assert {:error, :not_connected} = MCP.tools(name)
  end

  test "Streamable HTTP JSON, POST SSE and independent GET push events", ctx do
    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        args: [Path.expand("vega_mcp_fixture.py", __DIR__), "http"]
      ])

    assert_receive {^port, {:data, number}}, 2000

    on_exit(fn ->
      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end)

    config = %{"url" => "http://127.0.0.1:#{String.trim(number)}/mcp"}
    assert {:ok, _} = MCP.connect(ctx.name, config)
    assert {:ok, %{"tools" => [_]}} = MCP.tools(ctx.name)
    assert :ok = MCP.watch(ctx.name, ctx.agent)
    assert :ok = MCP.subscribe(ctx.name, "test://value", ctx.agent)
    assert {:ok, %{"content" => [%{"text" => "emitted"}]}} = MCP.call_tool(ctx.name, "emit")
    assert_receive {:"$gen_cast", {:notify, %{method: "notifications/resources/updated"}}}, 2000
    assert_receive {:"$gen_cast", {:notify, %{method: "notifications/progress"}}}, 2000
  end

  test "resource push is logged in a real NanoAgent timeline before and after restart", ctx do
    name = connected(ctx)
    alias Nano.FakeOpenRouter, as: Fake
    old_url = Nano.Settings.get(:openrouter_base_url)
    Fake.start()
    model = Fake.model()
    agent = ctx.name <> "-real"
    Fake.push(model, calls: [idle: nil])
    {:ok, pid} = NanoAgent.start([name: agent] ++ Fake.opts(model, max_turns: 1))
    id = NanoAgent.info(agent).id

    on_exit(fn ->
      if live = NanoAgent.whereis(agent) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, live)
        NanoAgent.kill_tasks(live)
      end

      Nano.StateStore.delete(agent)
      Nano.Settings.put(:openrouter_base_url, old_url)
    end)

    send(pid, :begin)
    eventually(fn -> NanoAgent.info(agent).halted != nil end)
    assert :ok = MCP.subscribe(name, "test://value", agent)
    {:ok, _} = MCP.call_tool(name, "emit")

    event_count = fn ->
      Nano.Log.read(id)
      |> Enum.count(fn entry ->
        entry["type"] == "event_received" and
          String.contains?(entry["message"] || "", "notifications/resources/updated")
      end)
    end

    eventually(fn -> event_count.() == 1 end)
    Process.exit(pid, :kill)

    eventually(fn ->
      new = NanoAgent.whereis(agent)
      is_pid(new) and new != pid
    end)

    {:ok, _} = MCP.call_tool(name, "emit")
    eventually(fn -> event_count.() == 2 end)
  end

  test "persisted subscriptions restore after state process restart", ctx do
    name = connected(ctx)
    assert :ok = MCP.subscribe(name, "test://value", ctx.agent)
    old_state = Process.whereis(Vega.MCP.State)
    Process.exit(old_state, :kill)

    eventually(fn ->
      new = Process.whereis(Vega.MCP.State)
      is_pid(new) and new != old_state
    end)

    eventually(fn -> is_pid(Process.whereis(Vega.MCP.Connections)) end)
    assert Vega.MCP.State.get(name)["resources"]["test://value"] == [ctx.agent]
    assert :ok = MCP.disconnect(name)
    assert {:ok, _} = MCP.connect(name, config())
    assert {:ok, _} = MCP.call_tool(name, "emit")
    assert_receive {:"$gen_cast", {:notify, %{method: "notifications/resources/updated"}}}, 2000
  end

  test "config errors are explicit and negotiates older legacy revision", ctx do
    assert {:error, :invalid_server_config} = MCP.connect(ctx.name, %{"command" => 10})

    assert {:error, :invalid_server_config} =
             MCP.connect(ctx.name, %{"url" => "file:///tmp/test"})

    assert {:error, :invalid_server_config} =
             MCP.connect(ctx.name, %{"command" => "python3", "result_limit" => -1})

    path = Path.join(ctx.dir, "bad.json")
    File.write!(path, "{}")
    assert {:error, :invalid_config_file} = MCP.servers(path)
    older = Map.put(config(), "env", %{"VEGA_MCP_PROTOCOL" => "2025-06-18"})
    assert {:ok, %{"protocolVersion" => "2025-06-18"}} = MCP.connect(ctx.name, older)
    assert {:ok, _} = MCP.tools(ctx.name)
  end

  test "unsupported modern revision is refused, never falsely marked ready", ctx do
    modern = Map.put(config(), "env", %{"VEGA_MCP_PROTOCOL" => "2026-07-28"})
    assert {:error, {:disconnected, {:initialize_failed, _}}} = MCP.connect(ctx.name, modern)
    assert {:ok, %{phase: :disconnected}} = MCP.status(ctx.name)
  end

  test "concurrent subscription acknowledgements preserve resource interests and watchers", ctx do
    name = connected(ctx)
    tasks = for n <- 1..8, do: Task.async(fn -> MCP.subscribe(name, "test://#{n}", ctx.agent) end)
    assert :ok = MCP.watch(name, ctx.agent)
    Enum.each(tasks, fn task -> assert :ok = Task.await(task) end)
    state = Vega.MCP.State.get(name)
    assert map_size(state["resources"]) == 8
    assert state["watchers"] == [ctx.agent]
  end

  test "server launch failure returns promptly", ctx do
    assert {:error, {:disconnected, :executable_not_found}} =
             MCP.connect(ctx.name, %{"command" => "vega-mcp-nonexistent-program"})
  end

  test "SSE GET retry and cursor parsing" do
    gen = make_ref()
    Process.put(:mcp_kind, :get)
    assert "" == Vega.MCP.HTTP.consume("id: abc\nretry: 1234\ndata:\n\n", self(), gen)
    assert_receive {:sse_state, ^gen, "abc", 1234}
    Process.delete(:mcp_kind)
  end

  test "HTTP GET resumes cursor, honors retry, allows 405, and reports expired session", ctx do
    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        args: [Path.expand("vega_mcp_fixture.py", __DIR__), "http"]
      ])

    assert_receive {^port, {:data, number}}, 2000

    on_exit(fn ->
      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end)

    url = "http://127.0.0.1:#{String.trim(number)}"
    assert {:ok, _} = MCP.connect(ctx.name, %{"url" => url <> "/resume"})
    assert :ok = MCP.watch(ctx.name, ctx.agent)

    assert_receive {:"$gen_cast",
                    {:notify, %{method: "notifications/message", params: %{"data" => "resumed"}}}},
                   2000

    assert :ok = MCP.disconnect(ctx.name)
    assert {:ok, _} = MCP.connect(ctx.name, %{"url" => url <> "/nostream"})
    assert {:ok, _} = MCP.tools(ctx.name)
    assert {:error, {:disconnected, {:http_status, 404}}} = MCP.call_tool(ctx.name, "expire")
    assert_receive {:"$gen_cast", {:notify, %{method: "connection/dead"}}}, 2000
    eventually(fn -> match?({:ok, %{phase: :ready}}, MCP.status(ctx.name)) end)
    assert {:ok, _} = MCP.tools(ctx.name)
  end

  test "spill filesystem failure is bounded rather than crashing connection", ctx do
    name = connected(ctx)
    File.write!(Path.join(ctx.dir, "results"), "not a directory")
    assert {:ok, %{truncated: true, spill_error: _}} = MCP.call_tool(name, "large")
    assert {:ok, _} = MCP.tools(name)
    assert {:error, :invalid_request} = MCP.request(name, "tools/list", %{}, timeout: -10)
  end

  test "SSE parser handles fragmented multiline data and comments" do
    gen = make_ref()

    fragment =
      "id: 9\r\n:comment\r\ndata: {\"jsonrpc\":\"2.0\",\r\ndata: \"method\":\"event\"}\r\n\r"

    assert ^fragment = Vega.MCP.HTTP.consume(fragment, self(), gen)
    assert "tail" = Vega.MCP.HTTP.consume(fragment <> "\ntail", self(), gen)
    assert_receive {:wire, ^gen, %{"method" => "event"}}
  end
end

defmodule Seedling.MCPTest do
  use ExUnit.Case, async: true
  alias Seedling.MCP
  @fixture Path.expand("mcp_fixture.py", __DIR__)

  defp unique, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    case fun.() do
      false ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      nil ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  defp setup_instance(transport, era) do
    dir = Path.join(System.tmp_dir!(), "mcp-test-" <> unique())
    File.mkdir_p!(dir)
    instance = unique()
    agent = "mcp-agent-" <> unique()
    assert :yes == Nano.Names.register_name({:agent, agent}, self())
    config = %{"transport" => transport}

    config =
      if transport == "stdio" do
        Map.merge(config, %{
          "command" => "python3",
          "args" => ["-u", @fixture, transport, era, dir]
        })
      else
        port =
          Port.open({:spawn_executable, System.find_executable("python3")}, [
            :binary,
            :exit_status,
            {:args, ["-u", @fixture, transport, era, dir]}
          ])

        on_exit(fn ->
          try do
            Port.close(port)
          catch
            _, _ -> :ok
          end
        end)

        assert eventually(fn -> File.exists?(Path.join(dir, "port")) end)
        port_number = File.read!(Path.join(dir, "port"))
        Map.put(config, "url", "http://127.0.0.1:#{port_number}/mcp")
      end

    path = Path.join(dir, "config.json")
    File.write!(path, Jason.encode!(%{servers: %{fixture: config}}))
    supervisor_opts = [instance: instance, state_dir: Path.join(dir, "state"), config_path: path]
    start_supervised!({Seedling.MCP.Supervisor, supervisor_opts})

    on_exit(fn ->
      Nano.Names.unregister_name({:agent, agent})
      File.rm_rf(dir)
    end)

    opts = [instance: instance, agent: agent, spill_dir: Path.join(dir, "spills")]
    %{dir: dir, agent: agent, instance: instance, opts: opts, supervisor_opts: supervisor_opts}
  end

  for {transport, era} <- [
        {"stdio", "modern"},
        {"stdio", "legacy"},
        {"http", "modern"},
        {"http", "legacy"}
      ] do
    test "#{transport} #{era}: discovery, calls, binary resources, paged lists, prompts and pushed mailbox events" do
      ctx = setup_instance(unquote(transport), unquote(era))
      opts = ctx.opts
      result = MCP.connect("fixture", opts)

      if not match?({:ok, _}, result),
        do:
          IO.inspect(
            {result, MCP.status("fixture", opts), File.read(Path.join(ctx.dir, "wire.jsonl"))},
            label: "connect failure"
          )

      assert {:ok, %{status: :ready, era: era}} = result
      assert era == String.to_existing_atom(unquote(era))
      assert_receive %{mcp: "fixture", type: :connected}, 3000

      assert {:ok, %{"tools" => [%{"name" => "echo"}], "nextCursor" => "next"}} =
               MCP.tools("fixture", opts)

      assert {:ok, %{"tools" => [%{"name" => "second"}]}} =
               MCP.tools("fixture", Keyword.put(opts, :cursor, "next"))

      assert {:ok, %{"resources" => [%{"uri" => "file://demo"}]}} = MCP.resources("fixture", opts)
      assert {:ok, %{"resourceTemplates" => [_]}} = MCP.resource_templates("fixture", opts)
      assert {:ok, %{"prompts" => [%{"name" => "greeting"}]}} = MCP.prompts("fixture", opts)
      assert {:ok, %{"messages" => [_]}} = MCP.get_prompt("fixture", "greeting", %{}, opts)

      assert {:ok, %{"content" => [%{"text" => text}]}} =
               MCP.call("fixture", "echo", %{"hello" => "world"}, opts)

      assert text =~ "world"
      assert_receive %{mcp: "fixture", type: :request, method: "tools/call"}, 3000
      assert_receive %{mcp: "fixture", type: :response, method: "tools/call", status: :ok}, 3000

      assert_receive %{mcp: "fixture", type: :notification, method: "notifications/progress"},
                     3000

      assert_receive %{mcp: "fixture", type: :notification, method: "notifications/message"}, 3000
      assert {:error, %{"code" => -32602}} = MCP.call("fixture", "error", %{}, opts)

      assert {:ok, %{"contents" => [%{"text" => "hello"}, %{"blob" => "AAECAw=="}]}} =
               MCP.read("fixture", "file://demo", opts)

      assert {:ok, %{truncated: true, path: path, bytes: bytes}} =
               MCP.read("fixture", "file://large", opts)

      assert bytes > 50_000
      assert {:ok, %{text: page, next_offset: offset}} = MCP.result_page(path, limit: 256)
      assert byte_size(page) <= 256 and offset > 0
      assert {:ok, %{text: next}} = MCP.result_page(path, offset: offset, limit: 256)
      assert next != ""
      assert {:ok, %{durable: true}} = MCP.subscribe("fixture", "file://demo", opts)

      assert_receive %{
                       mcp: "fixture",
                       type: :notification,
                       method: "notifications/resources/updated",
                       params: %{"uri" => "file://demo"}
                     },
                     3000

      assert {:ok, %{durable: true}} = MCP.unsubscribe("fixture", "file://demo", opts)

      assert eventually(fn ->
               messages = File.read!(Path.join(ctx.dir, "wire.jsonl"))

               if unquote(era) == "modern",
                 do: messages =~ "resourceSubscriptions\": []",
                 else: messages =~ "resources/unsubscribe"
             end)

      assert :ok = MCP.disconnect("fixture", opts)
      assert {:error, :not_connected} = MCP.status("fixture", opts)
    end
  end

  test "stable agent and full MCP tree restart restore durable subscription intent" do
    ctx = setup_instance("stdio", "modern")
    assert {:ok, _} = MCP.connect("fixture", ctx.opts)
    assert {:ok, _} = MCP.subscribe("fixture", "file://demo", ctx.opts)
    assert_receive %{method: "notifications/resources/updated"}, 3000
    # A restarted agent registers under the same stable name, not its previous pid.
    Nano.Names.unregister_name({:agent, ctx.agent})
    parent = self()

    replacement =
      spawn(fn ->
        assert :yes == Nano.Names.register_name({:agent, ctx.agent}, self())

        receive do
          event -> send(parent, {:replacement, event})
        end

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(replacement, :kill) end)
    assert_receive {:replacement, %{method: "notifications/resources/updated"}}, 3000
    send(replacement, :stop)
    assert eventually(fn -> not Process.alive?(replacement) end)
    assert :yes == Nano.Names.register_name({:agent, ctx.agent}, self())
    assert :ok = stop_supervised(Seedling.MCP.Supervisor)
    start_supervised!({Seedling.MCP.Supervisor, ctx.supervisor_opts})
    assert_receive %{type: :connected, protocol: "2026-07-28"}, 3000

    assert_receive %{
                     method: "notifications/resources/updated",
                     params: %{"uri" => "file://demo"}
                   },
                   3000
  end

  test "stdio OS death fails pending calls, reconnects and restores subscriptions without replay" do
    ctx = setup_instance("stdio", "modern")
    assert {:ok, _} = MCP.connect("fixture", ctx.opts)
    assert {:ok, _} = MCP.subscribe("fixture", "file://demo", ctx.opts)
    assert_receive %{method: "notifications/resources/updated"}, 3000
    assert {:error, {:disconnected, _}} = MCP.call("fixture", "die", %{}, ctx.opts)
    assert_receive %{type: :disconnected}, 3000
    assert_receive %{type: :connected}, 3000
    assert_receive %{method: "notifications/resources/updated"}, 3000

    count =
      File.read!(Path.join(ctx.dir, "wire.jsonl"))
      |> String.split("\n")
      |> Enum.count(&String.contains?(&1, "\"name\": \"die\""))

    assert count == 1
  end

  test "timeouts are bounded, unknown config is actionable, intents reject anonymous pids" do
    ctx = setup_instance("stdio", "modern")
    assert {:error, :stable_agent_required} = MCP.connect("fixture", instance: ctx.instance)
    assert {:error, {:unknown_server, "missing"}} = MCP.connect("missing", ctx.opts)
    assert {:ok, _} = MCP.connect("fixture", ctx.opts)

    assert {:error, :stable_agent_required} =
             MCP.subscribe("fixture", "file://demo", instance: ctx.instance, agent: self())

    assert {:error, :timeout} =
             MCP.call("fixture", "slow", %{}, Keyword.put(ctx.opts, :timeout, 25))
  end

  test "durable subscriptions resume in a genuinely new BEAM VM without connect or subscribe" do
    ctx = setup_instance("stdio", "modern")
    # Our local instance is intentionally never connected. Two separate VMs share ONLY disk.
    config = Path.join(ctx.dir, "config.json")
    dir = Path.join(ctx.dir, "vm-state")
    paths = Path.wildcard(Path.expand("../../_build/test/lib/*/ebin", __DIR__))
    # __DIR__ is test/seedling: project root is ../.. .
    assert paths != []

    base =
      "owner = self(); {:ok, _} = Seedling.MCP.Supervisor.start_link(config_path: #{inspect(config)}, state_dir: #{inspect(dir)}, resolver: fn _ -> owner end); "

    first =
      base <>
        "{:ok, _} = Seedling.MCP.connect(\"fixture\", agent: \"durable\"); {:ok, _} = Seedling.MCP.subscribe(\"fixture\", \"file://demo\", agent: \"durable\"); "

    wait =
      "receive do %{method: \"notifications/resources/updated\"} -> IO.puts(\"received-update\") after 5000 -> raise \"missing durable event\" end"

    args = Enum.flat_map(paths, &["-pa", &1])

    assert {output, 0} =
             System.cmd(System.find_executable("elixir"), args ++ ["-e", first <> wait],
               stderr_to_stdout: true
             )

    assert output =~ "received-update"

    assert {output, 0} =
             System.cmd(System.find_executable("elixir"), args ++ ["-e", base <> wait],
               stderr_to_stdout: true
             )

    assert output =~ "received-update"
  end

  test "HTTP modern mirrors safe encoded names and discovered schema parameter headers" do
    ctx = setup_instance("http", "modern")
    assert {:ok, _} = MCP.connect("fixture", ctx.opts)
    assert {:ok, %{"tools" => [%{"name" => "echo"}]}} = MCP.tools("fixture", ctx.opts)
    assert_receive %{type: :protocol_warning, tool: "invalid"}, 3000
    assert {:ok, _} = MCP.call("fixture", "echo", %{"region" => " 世界 "}, ctx.opts)
    assert {:ok, _} = MCP.call("fixture", "écho", %{}, ctx.opts)
    wire = File.read!(Path.join(ctx.dir, "wire.jsonl"))
    assert wire =~ "=?base64?"
    assert wire =~ "mcp-param-region"
  end

  test "supervised client kill rehydrates latest intent rather than original start args" do
    ctx = setup_instance("stdio", "modern")
    assert {:ok, _} = MCP.connect("fixture", ctx.opts)
    assert {:ok, _} = MCP.subscribe("fixture", "file://demo", ctx.opts)
    assert_receive %{method: "notifications/resources/updated"}, 3000
    {:ok, pid} = GenServer.call(MCP.manager(ctx.opts), {:client, "fixture"})
    Process.exit(pid, :kill)
    assert_receive %{type: :connected}, 3000
    assert_receive %{method: "notifications/resources/updated"}, 3000

    assert eventually(fn ->
             case MCP.status("fixture", ctx.opts) do
               {:ok, %{subscriptions: ["file://demo"]}} -> true
               _ -> false
             end
           end)
  end

  test "shared server subscriptions route URI events only to interested stable agents" do
    ctx = setup_instance("stdio", "modern")
    assert {:ok, _} = MCP.connect("fixture", ctx.opts)
    other_name = "mcp-other-" <> unique()
    parent = self()

    relay =
      spawn(fn ->
        assert :yes == Nano.Names.register_name({:agent, other_name}, self())

        loop = fn loop ->
          receive do
            event ->
              send(parent, {:other_agent, event})
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    on_exit(fn ->
      Process.exit(relay, :kill)
      Nano.Names.unregister_name({:agent, other_name})
    end)

    assert eventually(fn -> Nano.Names.whereis_name({:agent, other_name}) == relay end)
    other_opts = Keyword.put(ctx.opts, :agent, other_name)
    assert {:ok, _} = MCP.connect("fixture", other_opts)
    assert {:ok, _} = MCP.subscribe("fixture", "file://demo", ctx.opts)
    assert_receive %{method: "notifications/resources/updated"}, 3000
    refute_receive {:other_agent, %{method: "notifications/resources/updated"}}, 200
    assert {:ok, _} = MCP.subscribe("fixture", "file://demo", other_opts)
    assert_receive {:other_agent, %{method: "notifications/resources/updated"}}, 3000
    assert :ok = MCP.disconnect("fixture", ctx.opts)
    # Last URI still belongs to the other stable agent, so the shared server remains active.
    assert_receive {:other_agent, %{method: "notifications/resources/updated"}}, 3000

    assert {:ok, %{status: :ready, subscriptions: ["file://demo"]}} =
             MCP.status("fixture", other_opts)
  end
end

defmodule Seedling.MCPTest do
  use ExUnit.Case, async: false
  alias Seedling.MCP

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "mcp-test-#{System.unique_integer([:positive])}-#{Base.encode16(:crypto.strong_rand_bytes(4))}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp stdio(ctx, mode, extra \\ %{}, opts \\ []) do
    cfg =
      Map.merge(
        %{
          "transport" => "stdio",
          "command" => System.find_executable("python3"),
          "args" => [Path.expand("test/fixtures/seedling/mcp_stdio.py"), mode]
        },
        extra
      )

    connect(ctx, cfg, opts)
  end

  defp connect(ctx, cfg, opts \\ []) do
    path = Path.join(ctx.dir, "config.json")
    File.write!(path, Jason.encode!(%{"servers" => %{"script" => cfg}}))
    assert {:ok, c} = MCP.connect("script", [config_path: path, state_dir: ctx.dir] ++ opts)
    on_exit(fn -> MCP.disconnect(c) end)
    c
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

  defp ready?(c) do
    match?({:ok, %{status: :ready}}, MCP.status(c))
  end

  test "modern stdio discovers, invokes, pages cursor, resources binary and prompts", ctx do
    c = stdio(ctx, "modern")
    assert {:ok, %{version: "2026-07-28", status: :ready}} = MCP.status(c)

    assert {:ok, %{data: %{"tools" => tools}, next_cursor: "page2", truncated: false}} =
             MCP.tools(c)

    assert length(tools) == 5

    assert {:ok, %{data: %{"tools" => [%{"name" => "next"}]}, next_cursor: nil}} =
             MCP.tools(c, cursor: "page2")

    assert {:ok, %{data: %{"content" => [%{"text" => "{\"hello\": \"world\"}"}]}}} =
             MCP.call_tool(c, "echo", %{"hello" => "world"})

    assert {:ok, %{data: %{"resources" => [%{"uri" => "test://one"}]}}} = MCP.resources(c)
    assert {:ok, %{data: %{"resourceTemplates" => [_]}}} = MCP.resource_templates(c)

    assert {:ok, %{data: %{"contents" => [_, %{"blob" => "AAEC"}]}}} =
             MCP.read_resource(c, "test://one")

    assert {:ok, %{data: %{"prompts" => [%{"name" => "hello"}]}}} = MCP.prompts(c)

    assert {:ok, %{data: %{"messages" => [%{"content" => %{"text" => "Hello atlas"}}]}}} =
             MCP.get_prompt(c, "hello", %{"who" => "atlas"})

    assert {:error, %{reason: :rpc_error, rpc: %{data: %{"code" => -32601}}}} =
             MCP.request(c, "unknown")

    assert {:error, %{reason: :invalid_options}} = MCP.tools(c, max_bytes: 0)

    assert {:error, %{reason: :invalid_options}} =
             MCP.request(c, "test/invalid", %{"_meta" => "not a map"})

    assert {:error, %{reason: :invalid_connection}} = MCP.status(:not_a_handle)
  end

  test "bounded results preserve full data, byte paging UTF-8 and item cuts", ctx do
    c = stdio(ctx, "modern")
    assert {:ok, r} = MCP.call_tool(c, "big", %{}, max_bytes: 101)
    assert r.truncated and byte_size(r.text) <= 101 and String.valid?(r.text)
    assert r.data == nil
    assert r.notice =~ "Complete JSON"
    assert %{"content" => [%{"text" => full}]} = Jason.decode!(File.read!(r.output_path))
    assert String.length(full) == 10000
    assert {:ok, p} = MCP.page(r.output_path, max_bytes: 101)
    assert p.text == r.text
    assert {:ok, p2} = MCP.page(r.output_path, offset: p.next_offset, max_bytes: 101)
    assert String.valid?(p2.text) and p2.next_offset > p.next_offset
    assert {:error, %{reason: :invalid_offset}} = MCP.page(r.output_path, offset: 1_000_000)

    assert {:ok, %{truncated: true, data: %{"tools" => [_]}, output_path: path}} =
             MCP.tools(c, max_items: 1)

    assert length(Jason.decode!(File.read!(path))["tools"]) == 5
  end

  test "progress, logs, subscription correlation and unsubscribe", ctx do
    c = stdio(ctx, "modern")
    assert :ok = MCP.watch(c, self())
    assert :ok = MCP.subscribe(c, "test://one", self())
    assert_receive {:seedling_mcp, "script", "notifications/subscriptions/acknowledged", _}, 1000
    assert {:ok, _} = MCP.call_tool(c, "changes", %{}, progress: true, log_level: "info")

    assert_receive {:seedling_mcp, "script", "notifications/resources/updated",
                    %{data: %{"uri" => "test://one"}}},
                   1000

    assert_receive {:seedling_mcp, "script", "notifications/tools/list_changed", _}, 1000
    assert_receive {:seedling_mcp, "script", "notifications/progress", _}, 1000
    assert_receive {:seedling_mcp, "script", "notifications/message", _}, 1000
    assert {:ok, _} = MCP.request(c, "test/stale")
    refute_receive {:seedling_mcp, "script", "notifications/resources/updated", _}, 100
    assert :ok = MCP.unsubscribe(c, "test://one", self())
    assert {:ok, _} = MCP.call_tool(c, "changes")
    refute_receive {:seedling_mcp, "script", "notifications/resources/updated", _}, 100
    assert {:error, %{reason: :timeout}} = MCP.call_tool(c, "hang", %{}, timeout: 100)
    assert {:ok, _} = MCP.call_tool(c, "echo")
  end

  test "acknowledgment compares the original listen filter, not newer pending intents", ctx do
    c = stdio(ctx, "modern")
    assert :ok = MCP.watch(c, self())
    assert_receive {:seedling_mcp, "script", "notifications/subscriptions/acknowledged", _}, 1000
    parent = self()
    # Reproduce the exact mailbox interleaving: subscribe's new intent is present,
    # but its queued refresh has not yet replaced the active listen request.
    state =
      :sys.replace_state(c.pid, fn state ->
        %{state | subs: Map.put(state.subs, "test://one", MapSet.new([parent]))}
      end)

    send(
      c.pid,
      {:wire, state.epoch, :stdio,
       %{
         "jsonrpc" => "2.0",
         "method" => "notifications/subscriptions/acknowledged",
         "params" => %{
           "_meta" => %{"io.modelcontextprotocol/subscriptionId" => state.listening},
           "notifications" => state.listen_filter
         }
       }}
    )

    assert_receive {:seedling_mcp, "script", "notifications/subscriptions/acknowledged", _}, 1000
    refute_receive {:seedling_mcp, "script", :subscription_rejected, _}, 100
  end

  test "legacy fallback process death is visible and restores subscriptions", ctx do
    c = stdio(ctx, "legacy")
    assert {:ok, %{version: "2025-11-25", os_pid: old_pid}} = MCP.status(c)
    assert :ok = MCP.subscribe(c, "test://one", self())
    assert_receive {:seedling_mcp, "script", :restored, _}, 1000
    assert {:error, %{reason: reason}} = MCP.call_tool(c, "exit")
    assert reason in [:server_exit, :port_exit]
    assert_receive {:seedling_mcp, "script", :disconnected, _}, 1000
    assert_receive {:seedling_mcp, "script", :connected, _}, 3000
    assert_receive {:seedling_mcp, "script", :restored, _}, 1000
    assert {:ok, %{os_pid: new_pid}} = MCP.status(c)
    assert old_pid != new_pid
    assert {:ok, _} = MCP.call_tool(c, "changes")
    assert_receive {:seedling_mcp, "script", "notifications/resources/updated", _}, 1000
  end

  test "name resolution queues while agent absent and intent survives worker kill", ctx do
    {:ok, resolver} = Agent.start_link(fn -> %{"alice" => self()} end)
    # Resolve to test process, then replace it with a fresh sink simulating an agent restart.
    parent = self()
    Agent.update(resolver, fn _ -> %{"alice" => parent} end)
    resolve = fn name -> Agent.get(resolver, &Map.get(&1, name)) end
    c = stdio(ctx, "modern", %{}, resolver: resolve)
    assert :ok = MCP.subscribe(c, "test://one", {:agent, "alice"})
    assert_receive {:seedling_mcp, "script", "notifications/subscriptions/acknowledged", _}, 1000
    Agent.update(resolver, fn _ -> %{} end)
    assert {:ok, _} = MCP.call_tool(c, "changes")

    sink =
      spawn(fn ->
        receive do
          msg -> send(parent, {:restarted_agent, msg})
        end
      end)

    Agent.update(resolver, fn _ -> %{"alice" => sink} end)

    assert_receive {:restarted_agent,
                    {:seedling_mcp, "script", "notifications/resources/updated", _}},
                   1000

    Agent.update(resolver, fn _ -> %{"alice" => parent} end)
    Process.exit(c.pid, :kill)
    eventually(fn -> ready?(c) end)

    assert_receive {:seedling_mcp, "script", "notifications/subscriptions/acknowledged",
                    %{data: %{"notifications" => %{"resourceSubscriptions" => ["test://one"]}}}},
                   2000

    assert {:ok, _} = MCP.call_tool(c, "changes")
    assert_receive {:seedling_mcp, "script", "notifications/resources/updated", _}, 1000
  end

  test "malformed and oversized frames disconnect instead of hanging callers", ctx do
    c = stdio(ctx, "modern", %{"max_message_bytes" => 2000})
    assert :ok = MCP.watch(c, self())
    assert {:error, %{reason: :invalid_frame}} = MCP.call_tool(c, "malformed")
    assert_receive {:seedling_mcp, "script", :disconnected, _}, 1000
    eventually(fn -> ready?(c) end)
    assert {:error, %{reason: r}} = MCP.call_tool(c, "oversize")
    assert r in [:oversize, :invalid_frame]
    eventually(fn -> ready?(c) end)
    assert {:error, %{reason: :invalid_frame}} = MCP.call_tool(c, "bad_notification")
  end

  test "modern streamable HTTP validates metadata/header mirrors and SSE fragmentation", ctx do
    server =
      start_supervised!(
        {Bandit,
         plug: {Seedling.MCP.TestHTTP, [owner: self(), mode: :modern]},
         port: 0,
         ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    c = connect(ctx, %{"transport" => "http", "url" => "http://127.0.0.1:#{port}/mcp"})
    assert :ok = MCP.watch(c, self())
    assert :ok = MCP.subscribe(c, "test://one", self())
    assert_receive {:seedling_mcp, "script", "notifications/resources/updated", _}, 2000

    assert {:error, %{reason: :discover_tools_first}} =
             MCP.call_tool(c, "echo", %{"tenant" => "x"})

    assert {:ok, %{data: %{"tools" => [%{"name" => "echo"}]}}} = MCP.tools(c)
    assert_receive {:seedling_mcp, "script", "client/warning", _}, 1000

    assert {:ok, %{data: %{"content" => [%{"text" => "done"}]}}} =
             MCP.call_tool(c, "echo", %{"tenant" => "λ\n"}, progress: true, log_level: "info")

    assert_receive {:seedling_mcp, "script", "notifications/progress", _}, 1000
    assert_receive {:seedling_mcp, "script", "notifications/message", _}, 1000
    assert_receive {:http_request, "POST", headers, %{"method" => "tools/call"}}, 1000
    assert headers["mcp-param-tenant"] == "=?base64?zrsK?="
    refute_receive {:http_request, "GET", _, _}, 100
  end

  test "legacy HTTP session expiry reinitializes and GET resumes with cursor", ctx do
    table = :ets.new(:expiry, [:set, :public])

    server =
      start_supervised!(
        {Bandit,
         plug: {Seedling.MCP.TestHTTP, [owner: self(), mode: :legacy, table: table]},
         port: 0,
         ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    c = connect(ctx, %{"transport" => "http", "url" => "http://127.0.0.1:#{port}/mcp"})
    assert :ok = MCP.subscribe(c, "test://one", self())
    assert_receive {:seedling_mcp, "script", :restored, _}, 1000
    assert_receive {:seedling_mcp, "script", "notifications/resources/updated", _}, 1000
    assert_receive {:http_request, "GET", _, _}, 1000
    assert_receive {:http_request, "GET", %{"last-event-id" => "cursor-1"}, _}, 2000
    assert {:error, %{reason: :session_expired}} = MCP.call_tool(c, "echo")
    assert_receive {:seedling_mcp, "script", :connected, _}, 2000
    assert_receive {:seedling_mcp, "script", :restored, _}, 1000
    eventually(fn -> ready?(c) end)
    assert {:ok, _} = MCP.call_tool(c, "echo")
  end

  test "a brutally killed connection cleans even a SIGTERM-ignoring descendant", ctx do
    c = stdio(ctx, "modern")
    assert {:ok, %{data: %{"childPid" => child}}} = MCP.call_tool(c, "fork")
    stat = Path.join(["/proc", Integer.to_string(child), "stat"])
    assert File.exists?(stat)
    Process.exit(c.pid, :kill)

    eventually(fn ->
      case File.read(stat) do
        {:error, :enoent} -> true
        {:ok, text} -> Regex.match?(~r/\) Z /, text)
        _ -> false
      end
    end)

    eventually(fn -> ready?(c) end)
  end

  test "absent name delivery is bounded with explicit overflow", ctx do
    parent = self()
    {:ok, resolver} = Agent.start_link(fn -> nil end)
    c = stdio(ctx, "modern", %{}, resolver: fn _ -> Agent.get(resolver, & &1) end)
    assert :ok = MCP.subscribe(c, "test://one", {:agent, "alice"})
    for _ <- 1..60, do: assert({:ok, _} = MCP.call_tool(c, "changes"))
    Agent.update(resolver, fn _ -> parent end)

    assert_receive {:seedling_mcp, "script", :delivery_overflow,
                    %{data: %{"message" => message}}},
                   2000

    assert message =~ "oldest events lost"
  end

  test "disconnect forgets durable subscriptions and cleans the OS group", ctx do
    parent = self()
    c = stdio(ctx, "legacy", %{}, resolver: fn _ -> parent end)
    assert :ok = MCP.subscribe(c, "test://one", {:agent, "alice"})
    assert_receive {:seedling_mcp, "script", :restored, _}, 1000
    assert {:ok, %{os_pid: pid}} = MCP.status(c)
    assert File.exists?(Path.join(["/proc", Integer.to_string(pid), "stat"]))
    assert :ok = MCP.disconnect(c)
    eventually(fn -> not File.exists?(Path.join(["/proc", Integer.to_string(pid), "stat"])) end)
    refute File.exists?(Path.join([ctx.dir, c.key, "intent.json"]))
    c2 = stdio(ctx, "legacy", %{}, resolver: fn _ -> parent end)
    assert {:ok, %{subscription_count: 0}} = MCP.status(c2)
    assert {:error, %{reason: :invalid_options}} = MCP.call_tool(c2, "echo", %{"bad" => self()})
  end

  test "configuration errors and safe custom headers", ctx do
    path = Path.join(ctx.dir, "bad.json")
    File.write!(path, "{}")
    assert {:error, %{reason: :invalid_config}} = MCP.servers(path)

    File.write!(
      path,
      Jason.encode!(%{
        "servers" => %{
          "x" => %{"transport" => "stdio", "command" => "${SEEDLING_MCP_TEST_UNSET_VARIABLE}"}
        }
      })
    )

    assert {:error, %{reason: :missing_env}} =
             MCP.connect("x", config_path: path, state_dir: ctx.dir)

    assert {:error, %{reason: :unknown_server}} =
             MCP.connect("missing", config_path: path, state_dir: ctx.dir)

    assert Seedling.MCP.Headers.encode(" plain ") == "=?base64?IHBsYWluIA==?="
    assert Seedling.MCP.Headers.encode("=?base64?x?=") != "=?base64?x?="

    assert {:error, _} =
             Seedling.MCP.Headers.tool(%{
               "inputSchema" => %{"oneOf" => [%{"type" => "string", "x-mcp-header" => "X"}]}
             })
  end
end

defmodule Nano.MCPTest do
  use ExUnit.Case, async: false
  alias Nano.MCP

  setup do
    id = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    root = Path.join(Application.fetch_env!(:nano, :test_dir), "mcp-" <> id)
    File.mkdir_p!(root)
    agent = "mcp-test-" <> id
    assert :yes = Nano.Names.register_name({:agent, agent}, self())
    config = Path.join(root, "servers.json")
    trace = Path.join(root, "trace.jsonl")

    definitions =
      for mode <- ["modern", "legacy", "broken"],
          into: %{},
          do:
            {mode,
             %{
               "transport" => "stdio",
               "command" => System.find_executable("python3"),
               "args" => [Path.expand("../fixtures/mcp_core.py", __DIR__), mode, trace]
             }}

    File.write!(config, Jason.encode!(%{"servers" => definitions}))
    old = Application.get_env(:nano, :mcp_config_path)
    Application.put_env(:nano, :mcp_config_path, config)

    on_exit(fn ->
      for server <- ["modern", "legacy", "broken", "reference"], do: MCP.disconnect(agent, server)
      Nano.Names.unregister_name({:agent, agent})

      if old,
        do: Application.put_env(:nano, :mcp_config_path, old),
        else: Application.delete_env(:nano, :mcp_config_path)

      File.rm_rf(root)
    end)

    {:ok, agent: agent, trace: trace, config: config}
  end

  test "dual-era discovery, cursor pages, tools/resources/prompts, pushes and subscription cancellation",
       %{agent: a, trace: trace} do
    for server <- ["modern", "legacy"] do
      assert :ok = MCP.connect(a, server)

      assert {:ok, %{data: %{"tools" => [%{"name" => "echo"}], "nextCursor" => "second"}}} =
               MCP.tools(a, server)

      assert {:ok, %{data: %{"tools" => [%{"name" => "update"}]}}} =
               MCP.tools(a, server, cursor: "second")

      assert {:ok, %{data: %{"contents" => [%{"text" => "resource"}]}}} =
               MCP.read_resource(a, server, "test://resource")

      assert {:ok, %{data: %{"messages" => [_]}}} = MCP.get_prompt(a, server, "hello")

      eventually(fn ->
        assert {:ok,
                %{
                  data: %{
                    catalog: %{
                      "tools" => _,
                      "resources" => _,
                      "prompts" => _,
                      "resourceTemplates" => _
                    }
                  }
                }} = MCP.catalog(a, server)
      end)

      assert :ok = MCP.subscribe(a, server, "test://resource")
      assert {:ok, _} = MCP.call_tool(a, server, "update")

      assert_receive {:"$gen_cast",
                      {:notify,
                       %{
                         mcp: "notifications/resources/updated",
                         server: ^server,
                         payload: %{data: %{"uri" => "test://resource"}}
                       }}},
                     2000

      assert :ok = MCP.unsubscribe(a, server, "test://resource")
      assert :ok = MCP.disconnect(a, server)
    end

    messages = trace(trace)
    modern = Enum.find(messages, &(&1["method"] == "server/discover"))
    assert modern["params"]["_meta"]["io.modelcontextprotocol/clientInfo"]["name"] == "nano"
    assert Enum.any?(messages, &(&1["method"] == "initialize"))
    assert Enum.any?(messages, &(&1["method"] == "notifications/initialized"))
  end

  test "bounded large Unicode and error responses retain original and support paging", %{agent: a} do
    assert :ok = MCP.connect(a, "modern")

    assert {:ok, %{cut: true, id: id, raw_path: raw, text: text, next_offset: next}} =
             MCP.call_tool(a, "modern", "large")

    assert byte_size(text) <= 4096
    assert String.valid?(text)
    assert next > 1
    assert {:ok, %{text: more}} = MCP.page(id, offset: next)
    assert String.valid?(more)
    assert %{"content" => [%{"text" => content}]} = raw |> File.read!() |> Jason.decode!()
    assert content == String.duplicate("😀", 20000)
    assert {:error, %{cut: true, id: _}} = MCP.call_tool(a, "modern", "error")
    assert {:error, :invalid_page_id} = MCP.page("../../state")
  end

  test "timeouts cancel; process exit fails pending requests and reconnect restores subscriptions",
       %{agent: a, trace: trace} do
    assert :ok = MCP.connect(a, "legacy")
    assert :ok = MCP.subscribe(a, "legacy", "test://resource")
    assert {:error, %{data: :timeout}} = MCP.call_tool(a, "legacy", "hang", %{}, timeout: 30)

    eventually(fn ->
      assert Enum.any?(trace(trace), &(&1["method"] == "notifications/cancelled"))
    end)

    assert {:error, :connection_lost} = MCP.call_tool(a, "legacy", "die")
    assert_receive {:"$gen_cast", {:notify, %{mcp: "disconnected"}}}, 2000
    eventually(fn -> assert :ok = MCP.connect(a, "legacy", timeout: 1000) end)

    eventually(fn ->
      assert Enum.count(trace(trace), &(&1["method"] == "resources/subscribe")) >= 2
    end)

    assert {:ok, _} = MCP.call_tool(a, "legacy", "update")
    assert_receive {:"$gen_cast", {:notify, %{mcp: "notifications/resources/updated"}}}, 2000
  end

  test "stable-name agent replacement and manager restart preserve subscription intent", %{
    agent: a,
    trace: trace
  } do
    assert :ok = MCP.connect(a, "modern")
    assert :ok = MCP.subscribe(a, "modern", "test://resource")
    Nano.Names.unregister_name({:agent, a})
    assert {:ok, _} = MCP.call_tool(a, "modern", "update")
    assert :yes = Nano.Names.register_name({:agent, a}, self())
    assert_receive {:"$gen_cast", {:notify, %{mcp: "notifications/resources/updated"}}}, 2500
    {:ok, old} = Nano.MCP.Manager.session(a, "modern")
    Process.exit(Process.whereis(Nano.MCP.Manager), :kill)

    eventually(fn ->
      {:ok, pid} = Nano.MCP.Manager.session(a, "modern")
      assert pid != old
      assert :ok = MCP.connect(a, "modern", timeout: 1000)
    end)

    eventually(fn ->
      listens =
        Enum.filter(
          trace(trace),
          &(&1["method"] == "subscriptions/listen" and
              "test://resource" in &1["params"]["notifications"]["resourceSubscriptions"])
        )

      assert length(listens) >= 2
    end)

    assert {:ok, _} = MCP.call_tool(a, "modern", "update")
    assert_receive {:"$gen_cast", {:notify, %{mcp: "notifications/resources/updated"}}}, 2500
  end

  test "initializer cleans newly created connections on failure; secrets are references", %{
    agent: a,
    config: config
  } do
    assert {:error, _} = MCP.initialize(a, ["modern", "missing"])
    assert {:error, :not_connected} = Nano.MCP.Manager.session(a, "modern")
    assert :ok = MCP.connect(a, "modern")
    assert {:error, _} = MCP.initialize(a, ["modern", "missing"])
    assert {:ok, _} = Nano.MCP.Manager.session(a, "modern")
    assert :ok = Nano.Settings.put("MCP_TEST_SECRET", "fixture-secret")

    File.write!(
      config,
      Jason.encode!(%{
        "servers" => %{
          "secret" => %{
            "transport" => "http",
            "url" => "http://localhost:1/mcp",
            "headers" => %{"authorization" => %{"setting" => "MCP_TEST_SECRET"}}
          }
        }
      })
    )

    assert {:ok, %{"headers" => %{"authorization" => "fixture-secret"}}} =
             Nano.MCP.Config.fetch("secret")

    refute File.read!(config) =~ "fixture-secret"
    assert {:error, :stable_agent_name_required} = MCP.connect(self(), "secret")
    assert {:error, :invalid_agent_name} = MCP.connect("../bad", "secret")
    assert {:error, :invalid_argument} = MCP.connect(a, "secret", timeout: "bad")
    assert {:error, :not_connected} = Nano.MCP.Manager.session(a, "secret")
    state = Path.join(Application.fetch_env!(:nano, :state_dir), "mcp.json")
    refute File.read!(state) =~ "fixture-secret"
  end

  test "subscription transactions reject concurrent mutations, verify ack filter, and reconcile failed streams",
       %{agent: a, trace: trace} do
    assert :ok = MCP.connect(a, "modern")
    first = Task.async(fn -> MCP.subscribe(a, "modern", "slow://resource") end)

    eventually(fn ->
      assert Enum.any?(
               trace(trace),
               &(&1["method"] == "subscriptions/listen" and
                   "slow://resource" in &1["params"]["notifications"]["resourceSubscriptions"])
             )
    end)

    assert {:error, :subscription_busy} = MCP.subscribe(a, "modern", "another://resource")
    assert :ok = Task.await(first)
    assert {:ok, ["slow://resource"]} = Nano.MCP.Manager.uris(a, "modern")
    assert {:error, :subscription_not_honored} = MCP.subscribe(a, "modern", "reject://resource")
    assert {:ok, ["slow://resource"]} = Nano.MCP.Manager.uris(a, "modern")
    assert {:error, :subscription_failed} = MCP.subscribe(a, "modern", "close://resource")
    assert {:ok, ["slow://resource"]} = Nano.MCP.Manager.uris(a, "modern")

    assert {:error, :subscription_failed} =
             MCP.subscribe(a, "modern", "hang://resource", timeout: 300)

    assert {:ok, ["slow://resource"]} = Nano.MCP.Manager.uris(a, "modern")
    assert :ok = MCP.subscribe(a, "modern", "test://resource")
    assert {:ok, ["slow://resource", "test://resource"]} = Nano.MCP.Manager.uris(a, "modern")
  end

  test "malformed peer shapes, request metadata and discovery fail safely", %{agent: a} do
    assert {:error, :invalid_discovery_response} = MCP.connect(a, "broken")
    assert :ok = MCP.connect(a, "modern")
    {:ok, pid} = Nano.MCP.Manager.session(a, "modern")

    assert {:error, :invalid_request_metadata} =
             MCP.request(a, "modern", "tools/list", %{"_meta" => []})

    assert {:ok, _} = MCP.call_tool(a, "modern", "malformed")
    assert Process.alive?(pid)
    assert {:ok, _} = MCP.tools(a, "modern")
  end

  test "persisted queued notifications retain mailbox envelope after manager restart", %{agent: a} do
    assert :ok = MCP.connect(a, "modern")
    Nano.Names.unregister_name({:agent, a})
    Nano.MCP.Manager.event(a, "modern", "custom_notice", %{"text" => "persisted payload"})
    assert {:ok, _} = Nano.MCP.Manager.uris(a, "modern")
    old = Process.whereis(Nano.MCP.Manager)
    Process.exit(old, :kill)
    eventually(fn -> assert Process.whereis(Nano.MCP.Manager) not in [nil, old] end)
    assert :yes = Nano.Names.register_name({:agent, a}, self())

    assert_receive {:"$gen_cast",
                    {:notify,
                     %{
                       mcp: "custom_notice",
                       server: "modern",
                       payload: %{data: %{"text" => "persisted payload"}}
                     }}},
                   2500
  end

  test "initializer restores pre-existing subscription
 intent on failure",
       %{agent: a} do
    assert :ok = MCP.connect(a, "modern")
    assert :ok = MCP.subscribe(a, "modern", "old://resource")

    assert {:error, _} =
             MCP.initialize(a, [%{server: "modern", subscriptions: ["new://resource"]}, "missing"])

    assert {:ok, ["old://resource"]} = Nano.MCP.Manager.uris(a, "modern")
  end

  test "state write failures preserve disconnect monitors and reconcile remote subscription changes",
       %{agent: a, config: config} do
    assert :ok = MCP.connect(a, "modern")
    {:ok, original} = Nano.MCP.Manager.session(a, "modern")
    old = Application.fetch_env!(:nano, :state_dir)
    file = Path.join(Path.dirname(config), "not-a-directory")
    File.write!(file, "file")
    Application.put_env(:nano, :state_dir, file)

    try do
      assert {:error, :state_write_failed} = MCP.disconnect(a, "modern")
      assert {:ok, ^original} = Nano.MCP.Manager.session(a, "modern")
    after
      Application.put_env(:nano, :state_dir, old)
    end

    Process.exit(original, :kill)

    eventually(fn ->
      {:ok, pid} = Nano.MCP.Manager.session(a, "modern")
      assert pid != original
      assert :ok = MCP.connect(a, "modern", timeout: 1000)
    end)

    {:ok, before_mutation} = Nano.MCP.Manager.session(a, "modern")
    Application.put_env(:nano, :state_dir, file)

    try do
      assert {:error, :state_write_failed} = MCP.subscribe(a, "modern", "new://resource")
    after
      Application.put_env(:nano, :state_dir, old)
    end

    assert {:ok, []} = Nano.MCP.Manager.uris(a, "modern")

    eventually(fn ->
      {:ok, pid} = Nano.MCP.Manager.session(a, "modern")
      assert pid != before_mutation
      assert :ok = MCP.connect(a, "modern", timeout: 1000)
    end)
  end

  test "stored pages have explicit retention and missing-page errors", %{agent: a} do
    assert :ok = MCP.connect(a, "modern")
    assert {:ok, %{id: id, raw_path: raw}} = MCP.call_tool(a, "modern", "large")
    assert :ok = File.touch(raw, System.os_time(:second) - 8 * 86400)
    assert :ok = Nano.MCP.Page.prune()
    refute File.exists?(raw)
    assert {:error, _} = MCP.page(id)
  end

  test "spill failure is explicit
 and does not crash a session",
       %{agent: a} do
    assert :ok = MCP.connect(a, "modern")
    old = Application.fetch_env!(:nano, :spill_dir)
    File.mkdir_p!(old)
    file = Path.join(old, "not-a-directory")
    File.write!(file, "file")
    Application.put_env(:nano, :spill_dir, file)

    try do
      assert {:ok, %{cut: true, error: :spill_failed}} = MCP.call_tool(a, "modern", "large")
      assert {:ok, _} = MCP.tools(a, "modern")
    after
      Application.put_env(:nano, :spill_dir, old)
      File.rm(file)
    end
  end

  @tag skip:
         is_nil(System.get_env("MCP_REFERENCE_NODE")) or
           is_nil(System.get_env("MCP_REFERENCE_FILESYSTEM"))
  test "real reference filesystem server via public client", %{agent: a, config: config} do
    root = Path.dirname(config)
    file = Path.join(root, "reference.txt")
    File.write!(file, "actual reference client round trip")

    definition = %{
      "transport" => "stdio",
      "command" => System.fetch_env!("MCP_REFERENCE_NODE"),
      "args" => [System.fetch_env!("MCP_REFERENCE_FILESYSTEM"), root]
    }

    File.write!(config, Jason.encode!(%{"servers" => %{"reference" => definition}}))
    assert :ok = MCP.connect(a, "reference")
    assert {:ok, result} = MCP.tools(a, "reference")
    # Reference tool schemas themselves may require stored paging.
    assert is_map(result)

    assert {:ok, %{data: %{"content" => content}}} =
             MCP.call_tool(a, "reference", "read_text_file", %{"path" => file})

    assert Enum.any?(content, &(&1["text"] == "actual reference client round trip"))
    assert {:error, :subscriptions_unsupported} = MCP.subscribe(a, "reference", "file://" <> file)
  end

  for {mode, reason} <- [{"legacy_error", "server_error"}, {"legacy_timeout", "timeout"}] do
    test "legacy durable restore #{mode} is visible, backed off and recovered", %{
      agent: a,
      config: config,
      trace: trace
    } do
      uri = "restore://resource"
      assert :ok = MCP.connect(a, "legacy")
      assert :ok = MCP.subscribe(a, "legacy", uri)
      prepare_restore_failure(config, "legacy", unquote(mode), 2)
      {:ok, old} = Nano.MCP.Manager.session(a, "legacy")
      Process.exit(old, :kill)

      assert_receive {:"$gen_cast",
                      {:notify,
                       %{
                         mcp: "subscription_restore_failed",
                         payload: %{
                           data: %{"uri" => ^uri, "reason" => unquote(reason), "retryMs" => 250}
                         }
                       }}},
                     3000

      assert {:ok, [^uri]} = Nano.MCP.Manager.uris(a, "legacy")

      assert {:ok, %{data: %{subscriptions: %{desired: [^uri], active: []}}}} =
               MCP.catalog(a, "legacy")

      assert_receive {:"$gen_cast",
                      {:notify,
                       %{
                         mcp: "subscription_restore_failed",
                         payload: %{data: %{"uri" => ^uri, "retryMs" => 500}}
                       }}},
                     3000

      assert_receive {:"$gen_cast",
                      {:notify,
                       %{mcp: "subscription_restored", payload: %{data: %{"uri" => ^uri}}}}},
                     3000

      assert {:ok, %{data: %{subscriptions: %{active: [^uri]}}}} = MCP.catalog(a, "legacy")

      assert Enum.count(
               trace(trace),
               &(&1["method"] == "resources/subscribe" and &1["params"]["uri"] == uri)
             ) >= 4

      assert {:ok, _} = MCP.call_tool(a, "legacy", "update")

      assert_receive {:"$gen_cast",
                      {:notify,
                       %{
                         mcp: "notifications/resources/updated",
                         payload: %{data: %{"uri" => ^uri}}
                       }}},
                     1000
    end
  end

  test "modern automatic restoration verifies acknowledged URIs and backs off rejection", %{
    agent: a,
    config: config
  } do
    uri = "restore://resource"
    assert :ok = MCP.connect(a, "modern")
    assert :ok = MCP.subscribe(a, "modern", uri)
    prepare_restore_failure(config, "modern", "modern_reject", 2)
    {:ok, old} = Nano.MCP.Manager.session(a, "modern")
    Process.exit(old, :kill)

    assert_receive {:"$gen_cast",
                    {:notify,
                     %{
                       mcp: "subscription_restore_failed",
                       payload: %{
                         data: %{"uris" => [^uri], "reason" => "not_honored", "retryMs" => 250}
                       }
                     }}},
                   3000

    assert {:ok, [^uri]} = Nano.MCP.Manager.uris(a, "modern")

    assert {:ok, %{data: %{subscriptions: %{desired: [^uri], active: []}}}} =
             MCP.catalog(a, "modern")

    assert_receive {:"$gen_cast",
                    {:notify,
                     %{
                       mcp: "subscription_restore_failed",
                       payload: %{data: %{"uris" => [^uri], "retryMs" => 500}}
                     }}},
                   3000

    eventually(fn ->
      assert {:ok, %{data: %{subscriptions: %{active: [^uri]}}}} = MCP.catalog(a, "modern")
    end)

    assert {:ok, _} = MCP.call_tool(a, "modern", "update")

    assert_receive {:"$gen_cast",
                    {:notify,
                     %{mcp: "notifications/resources/updated", payload: %{data: %{"uri" => ^uri}}}}},
                   1000
  end

  test "legacy retry never reinstalls a URI removed while restoration is degraded", %{
    agent: a,
    config: config,
    trace: trace
  } do
    uri = "restore://resource"
    assert :ok = MCP.connect(a, "legacy")
    assert :ok = MCP.subscribe(a, "legacy", uri)
    prepare_restore_failure(config, "legacy", "legacy_error", 20)
    {:ok, old} = Nano.MCP.Manager.session(a, "legacy")
    Process.exit(old, :kill)
    assert_receive {:"$gen_cast", {:notify, %{mcp: "subscription_restore_failed"}}}, 3000
    assert :ok = MCP.unsubscribe(a, "legacy", uri)
    count = Enum.count(trace(trace), &(&1["method"] == "resources/subscribe"))
    Process.sleep(600)
    assert Enum.count(trace(trace), &(&1["method"] == "resources/subscribe")) == count
    assert {:ok, []} = Nano.MCP.Manager.uris(a, "legacy")
    assert {:ok, %{data: %{subscriptions: %{desired: [], active: []}}}} = MCP.catalog(a, "legacy")
  end

  test "trace observations defer an incomplete append but keep complete records strict", %{
    config: config
  } do
    file = Path.join(Path.dirname(config), "partial.jsonl")
    File.write!(file, "{\"one\":1}\n{\"two\":")
    assert trace(file) == [%{"one" => 1}]
    File.write!(file, "2}\n", [:append])
    assert trace(file) == [%{"one" => 1}, %{"two" => 2}]
    File.write!(file, "bad json\n", [:append])
    assert_raise Jason.DecodeError, fn -> trace(file) end
  end

  defp prepare_restore_failure(config, server, mode, remaining) do
    control = Path.join(Path.dirname(config), "restore-control.json")
    File.write!(control, Jason.encode!(%{"mode" => mode, "remaining" => remaining}))
    cfg = config |> File.read!() |> Jason.decode!()
    cfg = put_in(cfg, ["servers", server, "env"], %{"MCP_RESTORE_CONTROL" => control})
    cfg = put_in(cfg, ["servers", server, "subscription_timeout_ms"], 80)
    File.write!(config, Jason.encode!(cfg))
  end

  defp trace(path),
    # Newline commits a fixture record; a concurrent append may expose an incomplete tail.
    # Do not soften decode errors for completed records.
    do: path |> File.read!() |> String.split("\n") |> Enum.drop(-1) |> Enum.map(&Jason.decode!/1)

  defp eventually(fun, n \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, n) do
    try do
      fun.()
    rescue
      _ in [ExUnit.AssertionError, MatchError] ->
        Process.sleep(30)
        eventually(fun, n - 1)
    catch
      :exit, _ ->
        Process.sleep(30)
        eventually(fun, n - 1)
    end
  end
end

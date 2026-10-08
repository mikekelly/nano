defmodule MCPTest do
  use ExUnit.Case, async: true

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "deneb-mcp-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    owner = self()

    config = %{
      "servers" => %{
        "modern" => %{
          "transport" => "stdio",
          "command" => "python3",
          "args" => [Path.expand("../config/mcp_demo.py", __DIR__)],
          "cwd" => root,
          "timeout_ms" => 1000
        },
        "legacy" => %{
          "transport" => "stdio",
          "command" => "python3",
          "args" => [Path.expand("../config/mcp_demo.py", __DIR__), "--legacy"],
          "cwd" => root,
          "timeout_ms" => 1000
        }
      }
    }

    path = Path.join(root, "config.json")
    File.write!(path, Jason.encode!(config))

    start_opts = [
      name: nil,
      config_path: path,
      state_dir: root,
      deliver: fn agent, event -> send(owner, {agent, event}) end
    ]

    {:ok, manager} = MCP.start_link(start_opts)
    opts = [manager: manager, agent: "test-agent", spill_dir: Path.join(root, "spill")]
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    %{manager: manager, opts: opts, root: root, start_opts: start_opts}
  end

  test "modern discovery, metadata, paginated lists, call, read, prompt and bounded outputs", %{
    opts: opts
  } do
    assert {:ok, %{ready: true, protocol_version: "2026-07-28"}} = MCP.connect("modern", opts)

    assert {:ok, %{pages: %{tools: {:ok, %{"tools" => tools}}, resources: _, prompts: _}}} =
             MCP.discover("modern", opts)

    assert Enum.any?(tools, &(&1["name"] == "echo"))

    assert {:ok, %{"tools" => [%{"name" => "second_page"}]}} =
             MCP.list("modern", :tools, Keyword.put(opts, :cursor, "page2"))

    assert {:ok, %{"content" => [%{"text" => "hello"}]}} =
             MCP.call_tool("modern", "echo", %{"text" => "hello"}, opts)

    assert {:ok, %{"contents" => [%{"text" => "initial"}]}} =
             MCP.read_resource("modern", "demo://value", opts)

    assert {:ok, %{"messages" => [%{"content" => %{"text" => "Hello Ada"}}]}} =
             MCP.get_prompt("modern", "greeting", %{"name" => "Ada"}, opts)

    assert {:ok, %{"metadata" => meta}} = MCP.request("modern", "test/metadata", %{}, opts)
    assert meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
    assert meta["io.modelcontextprotocol/clientCapabilities"] == %{}

    assert {:ok, %{truncated: true, path: path, bytes: bytes}} =
             MCP.call_tool("modern", "large", %{}, opts)

    assert bytes > 50_000
    assert {:ok, %{next_offset: 1000, data: data}} = MCP.page(path, bytes: 1000)
    assert byte_size(data) == 1000
    assert {:error, :invalid_page} = MCP.page(path, offset: -1)
    assert {:error, {:input_required, _}} = MCP.request("modern", "test/input", %{}, opts)
    assert {:error, {:rpc, %{"code" => -32601}}} = MCP.request("modern", "missing", %{}, opts)
  end

  test "subscriptions, ordinary event forwarding, unsubscribe, crash reconnect, timeouts", %{
    opts: opts
  } do
    assert {:ok, _} = MCP.connect("modern", opts)
    assert :ok = MCP.subscribe("modern", "demo://value", opts)

    assert_receive {"test-agent",
                    {:mcp, "modern", "notifications/subscriptions/acknowledged", _}},
                   2000

    assert {:ok, _} = MCP.call_tool("modern", "set_value", %{"value" => "changed"}, opts)

    assert_receive {"test-agent",
                    {:mcp, "modern", "notifications/resources/updated",
                     %{"uri" => "demo://value"}}},
                   2000

    assert {:ok, _} = MCP.request("modern", "test/notifications", %{}, opts)
    assert_receive {"test-agent", {:mcp, "modern", "notifications/progress", _}}
    assert_receive {"test-agent", {:mcp, "modern", "notifications/message", _}}

    assert {:error, :timeout} =
             MCP.call_tool("modern", "hang", %{}, Keyword.put(opts, :timeout, 100))

    assert {:error, {:disconnected, _}} = MCP.call_tool("modern", "crash", %{}, opts)
    assert_receive {"test-agent", {:mcp, "modern", "client/disconnected", _}}, 2000
    assert {:ok, _} = MCP.await("modern", opts)
    assert {:ok, _} = MCP.call_tool("modern", "set_value", %{"value" => "after crash"}, opts)
    assert_receive {"test-agent", {:mcp, "modern", "notifications/resources/updated", _}}, 2000
    assert :ok = MCP.unsubscribe("modern", "demo://value", opts)
    assert {:ok, _} = MCP.call_tool("modern", "set_value", %{"value" => "unsubscribed"}, opts)
    refute_receive {"test-agent", {:mcp, "modern", "notifications/resources/updated", _}}, 100
  end

  test "legacy probe fallback and restart-stable named intent", %{
    manager: manager,
    opts: opts,
    root: root,
    start_opts: start_opts
  } do
    assert {:ok, %{protocol_version: "2025-11-25"}} = MCP.connect("legacy", opts)
    assert_receive {"test-agent", {:mcp, "legacy", "client/legacy_fallback", _}}
    assert :ok = MCP.subscribe("legacy", "demo://value", opts)

    assert_receive {"test-agent", {:mcp, "legacy", "client/subscription", %{result: {:ok, _}}}},
                   2000

    assert {:ok, _} = MCP.call_tool("legacy", "set_value", %{"value" => "legacy"}, opts)
    assert_receive {"test-agent", {:mcp, "legacy", "notifications/resources/updated", _}}, 2000
    saved = root |> Path.join("subscriptions.json") |> File.read!() |> Jason.decode!()
    assert saved["legacy"]["test-agent"] == ["demo://value"]
    GenServer.stop(manager)
    # New manager restores only names and URIs from disk; no PID or reattach required.
    {:ok, next} = MCP.start_link(start_opts)
    on_exit(fn -> if Process.alive?(next), do: GenServer.stop(next) end)
    opts = Keyword.put(opts, :manager, next)
    assert {:ok, _} = MCP.await("legacy", opts)

    assert_receive {"test-agent", {:mcp, "legacy", "client/subscription", %{result: {:ok, _}}}},
                   2000

    assert {:ok, _} = MCP.call_tool("legacy", "set_value", %{"value" => "restored"}, opts)
    assert_receive {"test-agent", {:mcp, "legacy", "notifications/resources/updated", _}}, 2000
    assert :ok = MCP.detach("legacy", opts)
    assert {:error, :not_connected} = MCP.status("legacy", opts)
  end

  test "bad config and unknown server fail clearly", %{opts: opts, root: root} do
    assert {:error, :unknown_server} = MCP.connect("missing", opts)
    assert {:error, :not_connected} = MCP.list("modern", :tools, opts)
    assert {:error, :invalid_list_kind} = MCP.list("modern", :nope, opts)
    path = Path.join(root, "bad.json")
    File.write!(path, ~s({"servers":{"bad":{"transport":"stdio","command":4}}}))
    assert {:error, {:invalid_server_config, "bad"}} = MCP.Config.load(path)
  end
end

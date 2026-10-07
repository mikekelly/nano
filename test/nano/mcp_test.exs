defmodule Nano.MCPTest do
  # Not async: the registry, store and supervisor are node-wide named processes.
  use ExUnit.Case, async: false

  alias Nano.MCP, as: M

  @fake Path.join([__DIR__, "..", "support", "fake_mcp_server.py"])

  setup do
    on_exit(fn ->
      for id <- M.servers(), do: M.disconnect(id)
      # Drop this test's subscriptions so they do not leak into other tests.
      for sub <- M.Store.list(nil),
          sub["pid"] != nil,
          do: M.Store.remove(sub["agent"], sub["server"], sub["uri"])
    end)

    :ok
  end

  defp fake!(id) do
    {:ok, info} = M.connect(id, ["python3", @fake])
    info
  end

  test "config_example is valid JSON with a servers map" do
    assert {:ok, %{"servers" => servers}} = Jason.decode(M.config_example())
    assert Map.has_key?(servers, "fs")
  end

  test "connects a stdio server and negotiates the protocol" do
    info = fake!("t-fake")
    assert info.protocolVersion == M.protocol_version()
    assert info.serverInfo["name"] == "fake"
    assert Map.has_key?(info.capabilities, "tools")
    assert "t-fake" in M.servers()
  end

  test "lists and calls tools" do
    fake!("t-tools")
    tools = M.tools("t-tools")
    assert Enum.any?(tools, &(&1["name"] == "echo"))
    {:ok, result} = M.call("t-tools", "echo", %{"text" => "hi"})
    assert result["text"] =~ "echo: hi"
  end

  test "lists and reads resources" do
    fake!("t-res")
    assert [%{"uri" => "test://doc"} | _] = M.resources("t-res")
    {:ok, result} = M.read_resource("t-res", "test://doc")
    assert result["text"] =~ "hello from fake"
  end

  test "lists and gets prompts" do
    fake!("t-prompt")
    assert Enum.any?(M.prompts("t-prompt"), &(&1["name"] == "greet"))
    {:ok, result} = M.get_prompt("t-prompt", "greet", %{})
    assert result["description"] == "greeting"
  end

  test "catalogue returns everything connected in one call" do
    fake!("t-cat")
    cat = M.catalogue()
    assert Map.has_key?(cat, "t-cat")
    assert Enum.any?(cat["t-cat"].tools, &(&1["name"] == "echo"))
  end

  test "a tool error comes back as {:error, {:mcp_error, _}}, not a raise" do
    fake!("t-err")
    assert {:error, {:mcp_error, %{"code" => -32601}}} = M.call("t-err", "nosuch", %{})
  end

  test "calls on an unconnected server return an error with the servers that are up" do
    assert {:error, {:not_connected, "nope", servers}} = M.call("nope", "x", %{})
    assert is_list(servers)
  end

  test "subscribe stores a subscription and delivers notifications as mailbox messages" do
    M.subscribe("t-sub", agent: self(), uri: "test://doc")
    assert Enum.any?(M.Store.list(nil), &(&1["server"] == "t-sub" and &1["uri"] == "test://doc"))

    # Deliver through the same path the server process uses.
    M.deliver(
      "t-sub",
      "test://doc",
      {:mcp,
       %{
         server: "t-sub",
         method: "notifications/resources/updated",
         params: %{"uri" => "test://doc"}
       }}
    )

    assert_receive {:mcp, %{server: "t-sub", method: "notifications/resources/updated"}}, 2_000
  end

  test "deliver only reaches agents subscribed to that resource" do
    M.subscribe("t-d", agent: self(), uri: "test://doc")
    M.deliver("t-d", "test://other", {:mcp, %{server: "t-d"}})
    refute_receive {:mcp, _}, 200
    M.deliver("t-d", "test://doc", {:mcp, %{server: "t-d", method: "ok"}})
    assert_receive {:mcp, %{method: "ok"}}, 500
  end

  test "subscriptions survive a node restart (reloaded from the store file)" do
    M.subscribe("t-persist", agent: self(), uri: "test://doc")
    assert File.exists?(M.Store.file())
    assert Enum.any?(M.Store.list(nil), &(&1["server"] == "t-persist"))
  end

  test "the protocol module extracts SSE data events" do
    body =
      "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\ndata: {\"method\":\"x\"}\n\n"

    messages = Nano.MCP.Protocol.decode_sse(body)
    assert length(messages) == 2
    assert hd(messages)["id"] == 1
  end

  test "the protocol module frames newline-delimited messages" do
    assert {:ok, %{"a" => 1}, "rest"} = Nano.MCP.Protocol.take_message("{\"a\":1}\nrest")
    assert :more = Nano.MCP.Protocol.take_message("partial")
    assert {:invalid, _reason, "x"} = Nano.MCP.Protocol.take_message("not json\nx")
  end

  test "normalize_result caps text and references binary payloads" do
    long = String.duplicate("a", 100_000)

    result =
      Nano.MCP.Protocol.normalize_result(%{"content" => [%{"type" => "text", "text" => long}]})

    assert byte_size(result["text"]) < 20_000

    image =
      Nano.MCP.Protocol.normalize_result(%{
        "content" => [%{"type" => "image", "mimeType" => "image/png", "data" => "AAAA"}]
      })

    [part] = image["content"]
    assert part["data"] =~ "reference"
    assert part["bytes"] == 4
  end
end

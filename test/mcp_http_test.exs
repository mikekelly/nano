defmodule MCP.HTTPTest do
  use ExUnit.Case, async: true
  alias MCP.HTTP
  alias MCP.HTTPTestServer, as: Server

  @protocol "2025-11-25"
  @initialize %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "initialize",
    "params" => %{
      "protocolVersion" => @protocol,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "test", "version" => "1"}
    }
  }
  @initialized %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

  setup do
    server = start_supervised!({Server, self()})
    %{url: Server.url(server)}
  end

  defp start_transport(url, options \\ %{}, owner \\ self()) do
    config = Map.merge(%{"transport" => "http", "url" => url, "timeout_ms" => 2000}, options)
    assert {:ok, transport} = HTTP.start(config, owner)
    on_exit(fn -> HTTP.close(transport) end)
    transport
  end

  test "per-message headers are isolated and override configured headers", %{url: url} do
    transport = start_transport(url, %{"headers" => %{"X-Custom" => "base"}})

    message = %{
      "jsonrpc" => "2.0",
      "id" => 10,
      "method" => "tools/call",
      "params" => %{"name" => "example", "arguments" => %{}}
    }

    assert :ok =
             HTTP.send_message(transport, message, %{
               "Mcp-Param-Region" => "west",
               "x-custom" => "request"
             })

    {connection, req} = request("POST")
    assert req.headers["mcp-param-region"] == "west"
    assert req.headers["x-custom"] == "request"
    assert req.headers["mcp-method"] == "tools/call"
    assert req.headers["mcp-name"] == "example"

    Server.reply(
      connection,
      200,
      [{"content-type", "application/json"}],
      Jason.encode!(%{"id" => 10, "result" => %{}})
    )

    assert_receive {:mcp_transport, ^transport, {:message, %{"id" => 10}}}, 2000
    HTTP.send_message(transport, %{"jsonrpc" => "2.0", "method" => "notifications/custom"})
    {connection, req} = request("POST")
    assert req.headers["x-custom"] == "base"
    refute Map.has_key?(req.headers, "mcp-param-region")
    Server.reply(connection, 202, [], "")
  end

  test "per-message headers reject injection and transport-owned overrides", %{url: url} do
    for headers <- [
          %{"x-test" => "a\r\nb"},
          %{"Accept" => "text/plain"},
          %{"MCP-Protocol-Version" => "wrong"},
          %{"x-test" => 123}
        ] do
      transport = start_transport(url)
      HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}, headers)
      assert_receive {:mcp_transport, ^transport, {:down, :invalid_message_headers}}, 2000
    end

    refute_receive {:http_request, _, _}, 30
  end

  defp request(method) do
    assert_receive {:http_request, connection, %{method: ^method} = request}, 2000
    {connection, request}
  end

  defp initialize(transport) do
    assert :ok = HTTP.send_message(transport, @initialize)
    {connection, request} = request("POST")
    assert Jason.decode!(request.body) == @initialize
    assert request.path == "/mcp"
    assert request.headers["content-type"] =~ "application/json"
    assert request.headers["accept"] =~ "application/json"
    assert request.headers["accept"] =~ "text/event-stream"

    response = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{
        "protocolVersion" => @protocol,
        "capabilities" => %{},
        "serverInfo" => %{"name" => "fixture", "version" => "1"}
      }
    }

    assert :ok =
             Server.reply(
               connection,
               200,
               [{"content-type", "application/json"}, {"mcp-session-id", "session-fixture"}],
               Jason.encode!(response)
             )

    assert_receive {:mcp_transport, ^transport, {:message, ^response}}, 2000
    assert :ok = HTTP.send_message(transport, @initialized)
    {initialized_connection, initialized_request} = request("POST")
    assert Jason.decode!(initialized_request.body) == @initialized
    assert :ok = Server.reply(initialized_connection, 202)
    {request, initialized_request}
  end

  test "initialize learns session and protocol headers and preserves configured headers", %{
    url: url
  } do
    transport =
      start_transport(url, %{
        "headers" => %{"authorization" => "Bearer test-secret", "x-fixture" => "yes"}
      })

    refute transport in elem(Process.info(self(), :links), 1)
    {initial, initialized} = initialize(transport)
    assert initial.headers["authorization"] == "Bearer test-secret"
    assert initial.headers["x-fixture"] == "yes"
    assert initialized.headers["mcp-session-id"] == "session-fixture"
    assert initialized.headers["mcp-protocol-version"] == @protocol
    assert initialized.headers["authorization"] == "Bearer test-secret"
    {get, get_request} = request("GET")
    assert get_request.headers["mcp-session-id"] == "session-fixture"
    assert get_request.headers["mcp-protocol-version"] == @protocol
    assert get_request.headers["accept"] =~ "text/event-stream"
    Server.reply(get, 405)
    refute_receive {:mcp_transport, ^transport, {:down, _}}, 100
  end

  test "GET SSE parses split CRLF, comments and multiline data exactly once", %{url: url} do
    transport = start_transport(url)
    initialize(transport)
    {get, _} = request("GET")
    assert :ok = Server.sse(get)

    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tools/list_changed",
      "params" => %{}
    }

    for fragment <- [
          ": heartbeat\r",
          "\n\r",
          "\nevent: message\r\ndata: {\"jsonrpc\":\"2.0\",\r",
          "\ndata: \"method\":\"notifications/tools/list_changed\",\"params\":{}}\r",
          "\n\r",
          "\n"
        ] do
      assert :ok = Server.chunk(get, fragment)
    end

    assert_receive {:mcp_transport, ^transport, {:message, ^notification}}, 2000
    refute_receive {:mcp_transport, ^transport, {:message, _}}, 100
    refute_receive {:mcp_transport, ^transport, {:down, _}}, 50
  end

  test "POST SSE delivers response and notification while stream stays open", %{url: url} do
    transport = start_transport(url)
    message = %{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/list"}
    response = %{"jsonrpc" => "2.0", "id" => 9, "result" => %{"tools" => []}}
    notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
    assert :ok = HTTP.send_message(transport, message)
    {post, req} = request("POST")
    assert Jason.decode!(req.body) == message
    assert :ok = Server.sse(post)
    assert :ok = Server.chunk(post, "data: " <> Jason.encode!(notification) <> "\n\n")
    assert :ok = Server.chunk(post, "data: " <> Jason.encode!(response) <> "\n\n")
    assert_receive {:mcp_transport, ^transport, {:message, ^notification}}, 2000
    assert_receive {:mcp_transport, ^transport, {:message, ^response}}, 2000
  end

  test "405 GET is nonfatal and later POST requests still work", %{url: url} do
    transport = start_transport(url)
    initialize(transport)
    {get, _} = request("GET")
    assert :ok = Server.reply(get, 405)
    refute_receive {:mcp_transport, ^transport, {:down, _}}, 100

    assert :ok =
             HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})

    {post, _} = request("POST")
    response = %{"jsonrpc" => "2.0", "id" => 2, "result" => %{}}
    Server.reply(post, 200, [{"content-type", "application/json"}], Jason.encode!(response))
    assert_receive {:mcp_transport, ^transport, {:message, ^response}}, 2000
  end

  test "404 for an established session reports down", %{url: url} do
    transport = start_transport(url)
    initialize(transport)
    {get, _} = request("GET")
    Server.reply(get, 405)

    assert :ok =
             HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})

    {post, _} = request("POST")
    Server.reply(post, 404)
    assert_receive {:mcp_transport, ^transport, {:down, _reason}}, 2000
    refute_receive {:mcp_transport, ^transport, {:down, _}}, 100
  end

  test "oversized JSON response reports down without delivering a message", %{url: url} do
    transport = start_transport(url, %{"max_message_bytes" => 256})
    HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
    {post, _} = request("POST")
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => String.duplicate("x", 400)})
    Server.reply(post, 200, [{"content-type", "application/json"}], body)
    assert_receive {:mcp_transport, ^transport, {:down, _}}, 2000
    refute_receive {:mcp_transport, ^transport, {:message, _}}, 50
  end

  test "unterminated oversized SSE frame is bounded", %{url: url} do
    transport = start_transport(url, %{"max_message_bytes" => 256})
    HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
    {post, _} = request("POST")
    Server.sse(post)
    Server.chunk(post, "data: " <> String.duplicate("x", 400))
    assert_receive {:mcp_transport, ^transport, {:down, _}}, 2000
    refute_receive {:mcp_transport, ^transport, {:message, _}}, 50
  end

  test "close stops transport and cancels open streaming connections", %{url: url} do
    transport = start_transport(url)
    HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
    {post, _} = request("POST")
    Server.sse(post)
    ref = Process.monitor(transport)
    assert :ok = HTTP.close(transport)
    assert_receive {:DOWN, ^ref, :process, ^transport, _}, 2000
    assert_receive {:http_closed, ^post}, 2000
    assert :ok = HTTP.close(transport)
  end

  test "owner death stops transport and cancels a pending HTTP request", %{url: url} do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(owner, :kill) end)
    transport = start_transport(url, %{}, owner)
    HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
    {post, _} = request("POST")
    ref = Process.monitor(transport)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^transport, _}, 2000
    assert_receive {:http_closed, ^post}, 2000
  end

  test "modern metadata mirrors protocol, method, and encoded name without legacy initialization",
       %{url: url} do
    transport = start_transport(url)
    name = "例 tool"

    message = %{
      "jsonrpc" => "2.0",
      "id" => 4,
      "method" => "tools/call",
      "params" => %{
        "name" => name,
        "arguments" => %{},
        "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
      }
    }

    assert :ok = HTTP.send_message(transport, message)
    {post, req} = request("POST")
    assert req.headers["mcp-protocol-version"] == "2026-07-28"
    assert req.headers["mcp-method"] == "tools/call"
    assert req.headers["mcp-name"] == "=?base64?" <> Base.encode64(name) <> "?="
    refute Map.has_key?(req.headers, "mcp-session-id")
    assert Jason.decode!(req.body) == message
    response = %{"jsonrpc" => "2.0", "id" => 4, "result" => %{"content" => []}}
    Server.reply(post, 200, [{"content-type", "application/json"}], Jason.encode!(response))
    assert_receive {:mcp_transport, ^transport, {:message, ^response}}, 2000
    refute_receive {:http_request, _, %{method: "GET"}}, 100
  end

  test "JSON-RPC error body on HTTP 400 reaches the owner", %{url: url} do
    transport = start_transport(url)
    HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 1, "method" => "missing"})
    {post, _} = request("POST")

    response = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "error" => %{"code" => -32601, "message" => "Method not found"}
    }

    Server.reply(
      post,
      400,
      [{"content-type", "application/json; charset=utf-8"}],
      Jason.encode!(response)
    )

    assert_receive {:mcp_transport, ^transport, {:message, ^response}}, 2000
    refute_receive {:mcp_transport, ^transport, {:down, _}}, 50
  end

  test "redirects are not followed with credentials", %{url: url} do
    transport = start_transport(url, %{"headers" => %{"authorization" => "Bearer secret"}})
    HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
    {post, _} = request("POST")
    Server.reply(post, 307, [{"location", url <> "?redirected=true"}])
    assert_receive {:mcp_transport, ^transport, {:down, _}}, 2000
    refute_receive {:http_request, _, _}, 100
  end

  test "modern subscription is idle without timing out and cancellation closes only its stream",
       %{url: url} do
    transport = start_transport(url, %{"timeout_ms" => 100, "protocol_version" => "2026-07-28"})

    listen = %{
      "jsonrpc" => "2.0",
      "id" => 71,
      "method" => "subscriptions/listen",
      "params" => %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}}
    }

    HTTP.send_message(transport, listen)
    {stream, _} = request("POST")
    Server.sse(stream)
    notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
    Server.chunk(stream, "data: " <> Jason.encode!(notification) <> "\n\n")
    assert_receive {:mcp_transport, ^transport, {:message, ^notification}}, 2000
    refute_receive {:mcp_transport, ^transport, {:down, _}}, 250
    refute_receive {:http_closed, ^stream}, 10

    assert :ok =
             HTTP.send_message(transport, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/cancelled",
               "params" => %{"requestId" => 71}
             })

    assert_receive {:http_closed, ^stream}, 2000
    refute_receive {:http_request, _, _}, 100
    refute_receive {:mcp_transport, ^transport, {:down, _}}, 10
    assert Process.alive?(transport)

    HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 72, "method" => "ping"})
    {post, _} = request("POST")
    response = %{"jsonrpc" => "2.0", "id" => 72, "result" => %{}}
    Server.reply(post, 200, [{"content-type", "application/json"}], Jason.encode!(response))
    assert_receive {:mcp_transport, ^transport, {:message, ^response}}, 2000
  end

  test "SSE ignores an initial UTF-8 BOM split across chunks", %{url: url} do
    transport = start_transport(url)
    HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 8, "method" => "ping"})
    {post, _} = request("POST")
    Server.sse(post)
    response = %{"jsonrpc" => "2.0", "id" => 8, "result" => %{}}
    Server.chunk(post, <<0xEF>>)
    Server.chunk(post, <<0xBB>>)
    Server.chunk(post, <<0xBF>> <> "data: " <> Jason.encode!(response) <> "\n\n")
    assert_receive {:mcp_transport, ^transport, {:message, ^response}}, 2000
    refute_receive {:mcp_transport, ^transport, {:down, _}}, 50
  end

  test "abrupt transport death closes its outstanding request socket", %{url: url} do
    transport = start_transport(url)
    HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
    {post, _} = request("POST")
    ref = Process.monitor(transport)
    Process.exit(transport, :kill)
    assert_receive {:DOWN, ^ref, :process, ^transport, :killed}, 2000
    assert_receive {:http_closed, ^post}, 2000
  end

  test "a request that never receives headers times out", %{url: url} do
    transport = start_transport(url, %{"timeout_ms" => 100})
    HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
    {post, _} = request("POST")
    assert_receive {:mcp_transport, ^transport, {:down, _}}, 2000
    assert_receive {:http_closed, ^post}, 2000
  end

  test "malformed JSON response is a transport error", %{url: url} do
    transport = start_transport(url)
    HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
    {post, _} = request("POST")
    Server.reply(post, 200, [{"content-type", "application/json"}], "{not-json")
    assert_receive {:mcp_transport, ^transport, {:down, _}}, 2000
    refute_receive {:mcp_transport, ^transport, {:message, _}}, 50
  end

  test "invalid configuration is rejected synchronously without linking to caller", %{url: url} do
    for config <- [
          %{},
          %{"url" => "file:///tmp/not-http"},
          %{"url" => "not a URL"},
          %{"url" => url, "headers" => []},
          %{"url" => url, "timeout_ms" => 0},
          %{"url" => url, "max_message_bytes" => -1}
        ] do
      assert {:error, _reason} = HTTP.start(config, self())
    end
  end
end

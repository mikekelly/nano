defmodule Seedling.MCP.HTTPTest do
  use ExUnit.Case, async: true
  alias Seedling.MCP.HTTP

  defmodule Endpoint do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      send(opts[:owner], {:http_request, conn.method, conn.req_headers, body})
      opts[:handler].(conn, body)
    end
  end

  defp server(handler) do
    {:ok, server} =
      Bandit.start_link(
        plug: {Endpoint, [owner: self(), handler: handler]},
        ip: :loopback,
        port: 0,
        startup_log: false
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}/mcp"
  end

  defp request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list"}

  test "JSON initialization session and negotiated version carried to subsequent requests" do
    url =
      server(fn conn, body ->
        value = Jason.decode!(body)

        conn
        |> Plug.Conn.put_resp_header("mcp-session-id", "session-1")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => value["id"], "result" => %{}})
        )
      end)

    {:ok, transport} = HTTP.start_link(%{url: url, listen: false}, self())
    on_exit(fn -> if Process.alive?(transport), do: HTTP.close(transport) end)
    assert :ok = HTTP.send_message(transport, request(1))
    assert_receive {:http_request, "POST", headers, _}
    assert {"accept", "application/json, text/event-stream"} in headers
    assert_receive {:mcp_message, ^transport, %{"id" => 1}}, 2000
    assert :ok = HTTP.set_version(transport, "2025-11-25")
    assert :ok = HTTP.send_message(transport, request(2))
    assert_receive {:http_request, "POST", headers, _}
    assert {"mcp-session-id", "session-1"} in headers
    assert {"mcp-protocol-version", "2025-11-25"} in headers
    assert_receive {:mcp_message, ^transport, %{"id" => 2}}, 2000
  end

  test "fragmented SSE with multiline data forwards notifications before response" do
    url =
      server(fn conn, _ ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        chunks = [
          ":keepalive\r",
          "\nid: cursor\r\ndata: {\"jsonrpc\":\"2.0\",\r\n",
          "data: \"method\":\"notifications/tools/list_changed\"}\r\n\r\n",
          "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n\n"
        ]

        Enum.reduce(chunks, conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)

    {:ok, transport} = HTTP.start_link(%{url: url, listen: false}, self())
    assert :ok = HTTP.send_message(transport, request(7))

    assert_receive {:mcp_message, ^transport, %{"method" => "notifications/tools/list_changed"}},
                   2000

    assert_receive {:mcp_message, ^transport, %{"id" => 7}}, 2000
    HTTP.close(transport)
  end

  test "SSE reconnect uses GET cursor, never replays POST" do
    url =
      server(fn conn, _ ->
        data =
          if conn.method == "POST",
            do: "id: prime\nretry: 1\ndata:\n\n",
            else: "data: {\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{}}\n\n"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, data)
      end)

    {:ok, transport} = HTTP.start_link(%{url: url, listen: false}, self())
    HTTP.send_message(transport, request(8))
    assert_receive {:http_request, "POST", _, _}, 2000
    assert_receive {:http_request, "GET", headers, ""}, 2000
    assert {"last-event-id", "prime"} in headers
    assert_receive {:mcp_message, ^transport, %{"id" => 8}}, 2000
    HTTP.close(transport)
  end

  test "202 notification, optional GET 405, session expiration" do
    url =
      server(fn conn, body ->
        cond do
          conn.method == "GET" ->
            Plug.Conn.send_resp(conn, 405, "")

          Jason.decode!(body)["method"] == "notifications/initialized" ->
            Plug.Conn.send_resp(conn, 202, "")

          true ->
            conn
            |> Plug.Conn.put_resp_header("mcp-session-id", "s")
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, "{\"id\":1,\"result\":{}}")
        end
      end)

    {:ok, transport} = HTTP.start_link(%{url: url}, self())
    HTTP.send_message(transport, request(1))
    assert_receive {:mcp_message, ^transport, _}, 2000
    HTTP.send_message(transport, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    assert_receive {:http_request, "GET", _, _}, 2000
    refute_receive {:mcp_transport_down, ^transport, _}, 50
    HTTP.close(transport)
  end

  test "response cap and wall timeout bound independent network jobs" do
    url =
      server(fn conn, _ ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, String.duplicate("x", 1000))
      end)

    {:ok, transport} = HTTP.start_link(%{url: url, max_bytes: 50, listen: false}, self())
    HTTP.send_message(transport, request(1))
    assert_receive {:mcp_transport_down, ^transport, :response_too_large}, 2000
    HTTP.close(transport)

    url =
      server(fn conn, _ ->
        Process.sleep(500)
        Plug.Conn.send_resp(conn, 200, "")
      end)

    {:ok, transport} = HTTP.start_link(%{url: url, timeout: 50, listen: false}, self())
    assert :ok = HTTP.send_message(transport, request(2))
    assert :ok = HTTP.set_version(transport, "2025-11-25")
    assert_receive {:mcp_transport_down, ^transport, _}, 1000
    HTTP.close(transport)
  end

  test "modern request headers, validated annotated tools, and recognized HTTP errors" do
    url =
      server(fn conn, _ ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32020,\"message\":\"Mismatch\"}}"
        )
      end)

    {:ok, transport} = HTTP.start_link(%{url: url}, self())

    valid = %{
      "name" => "こんにちは",
      "inputSchema" => %{
        "properties" => %{
          "nested" => %{
            "properties" => %{"region" => %{"type" => "string", "x-mcp-header" => "Region"}}
          }
        }
      }
    }

    invalid = %{
      "name" => "bad",
      "inputSchema" => %{"items" => %{"type" => "string", "x-mcp-header" => "X"}}
    }

    assert HTTP.register_tools(transport, [invalid, valid]) == [valid]

    message = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "こんにちは",
        "arguments" => %{"nested" => %{"region" => " padded "}},
        "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
      }
    }

    HTTP.send_message(transport, message)
    assert_receive {:http_request, "POST", headers, _}, 2000
    assert {"mcp-protocol-version", "2026-07-28"} in headers
    assert {"mcp-method", "tools/call"} in headers
    assert {"mcp-name", "=?base64?" <> Base.encode64("こんにちは") <> "?="} in headers
    assert {"mcp-param-region", "=?base64?" <> Base.encode64(" padded ") <> "?="} in headers
    assert_receive {:mcp_message, ^transport, %{"error" => %{"code" => -32020}}}, 2000
    refute_receive {:mcp_transport_down, ^transport, _}, 50
    HTTP.close(transport)
  end

  test "modern listen remains open past ordinary timeout with bounded per-event data" do
    url =
      server(fn conn, _ ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\"}\n\n"
          )

        Process.sleep(100)

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\"}\n\n"
          )

        Process.sleep(100)
        conn
      end)

    {:ok, transport} =
      HTTP.start_link(%{url: url, timeout: 30, stream_timeout: 1000, max_bytes: 120}, self())

    HTTP.set_version(transport, "2026-07-28")

    HTTP.send_message(transport, %{
      "jsonrpc" => "2.0",
      "id" => 9,
      "method" => "subscriptions/listen"
    })

    assert_receive {:mcp_message, ^transport,
                    %{"method" => "notifications/subscriptions/acknowledged"}},
                   2000

    assert_receive {:mcp_message, ^transport, %{"method" => "notifications/resources/updated"}},
                   2000

    assert_receive {:mcp_transport_down, ^transport, :stream_closed}, 2000
    refute_receive {:http_request, "GET", _, _}, 50
    HTTP.close(transport)
  end

  test "modern disconnected stream does not resume by GET even with event cursor" do
    url =
      server(fn conn, _ ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "id: cursor\ndata:\n\n")
      end)

    {:ok, transport} = HTTP.start_link(%{url: url}, self())
    HTTP.set_version(transport, "2026-07-28")
    HTTP.send_message(transport, request(4))
    assert_receive {:mcp_transport_down, ^transport, :stream_closed}, 2000
    refute_receive {:http_request, "GET", _, _}, 50
    HTTP.close(transport)
  end

  test "modern cancellation closes worker without sending notification POST" do
    url =
      server(fn conn, _ ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        conn =
          case Plug.Conn.chunk(conn, ": keepalive\n\n") do
            {:ok, conn} -> conn
            {:error, :closed} -> conn
          end

        Process.sleep(1000)
        conn
      end)

    {:ok, transport} = HTTP.start_link(%{url: url}, self())
    HTTP.set_version(transport, "2026-07-28")
    HTTP.send_message(transport, request(42))
    assert_receive {:http_request, "POST", _, _}, 2000

    assert :ok =
             HTTP.send_message(transport, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/cancelled",
               "params" => %{"requestId" => 42}
             })

    assert :sys.get_state(transport).jobs == %{}
    refute_receive {:http_request, "POST", _, _}, 50
    refute_receive {:mcp_transport_down, ^transport, _}, 50
    HTTP.close(transport)
  end
end

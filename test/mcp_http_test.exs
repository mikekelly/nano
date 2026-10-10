defmodule Nano.MCP.HTTPTest do
  use ExUnit.Case, async: true
  alias Nano.MCP.HTTP

  defmodule Server do
    def init(opts), do: opts

    def call(conn, {owner, handler}) do
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 5_000_000)
      send(owner, {:request, conn.method, conn.req_headers, body})
      handler.(conn, body)
    end
  end

  defp server(handler) do
    {:ok, pid} = Bandit.start_link(plug: {Server, {self(), handler}}, port: 0, ip: {127, 0, 0, 1})
    Process.unlink(pid)
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    "http://127.0.0.1:#{port}/mcp"
  end

  defp client(url) do
    {:ok, pid} =
      HTTP.start_link(self(), %{
        "url" => url,
        "protocol_version" => "2025-11-25",
        "headers" => %{"authorization" => "Bearer test"}
      })

    on_exit(fn ->
      try do
        HTTP.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    pid
  end

  defp json(conn, data),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(data))

  defp sse(conn, chunks) do
    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    Enum.reduce(chunks, conn, fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end

  test "JSON initialization, session and negotiated protocol on POST and GET; GET 405 allowed" do
    url =
      server(fn conn, body ->
        cond do
          conn.method == "GET" ->
            Plug.Conn.send_resp(conn, 405, "")

          Jason.decode!(body)["method"] == "initialize" ->
            conn
            |> Plug.Conn.put_resp_header("mcp-session-id", "session-test")
            |> json(%{
              "jsonrpc" => "2.0",
              "id" => 1,
              "result" => %{"protocolVersion" => "2025-06-18"}
            })

          true ->
            Plug.Conn.send_resp(conn, 202, "")
        end
      end)

    pid = client(url)

    assert :ok =
             HTTP.send_message(pid, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})

    assert_receive {:request, "POST", headers, _}, 2000
    assert headers |> Map.new() |> Map.fetch!("accept") == "application/json, text/event-stream"
    assert_receive {:mcp_transport, ^pid, {:message, %{"id" => 1}}}, 2000
    assert_receive {:request, "GET", headers, _}, 2000
    assert Map.new(headers)["mcp-session-id"] == "session-test"
    assert Map.new(headers)["mcp-protocol-version"] == "2025-06-18"
    assert Map.new(headers)["authorization"] == "Bearer test"
    HTTP.send_message(pid, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    assert_receive {:request, "POST", headers, _}, 2000
    assert Map.new(headers)["mcp-session-id"] == "session-test"
    refute_receive {:mcp_transport, ^pid, {:down, _}}, 50
  end

  test "POST SSE resumes via GET with cursor and receives multiline response" do
    url =
      server(fn conn, _ ->
        if conn.method == "POST" do
          sse(conn, [":comment\r\n", "id: cursor-1\r", "\ndata:\r\nretry: 10\r\n\r\n"])
        else
          sse(conn, [
            "event: message\nid: cursor-2\ndata: {\"jsonrpc\":\"2.0\",\n",
            "data: \"id\":2,\"result\":{}}\n\n"
          ])
        end
      end)

    pid = client(url)
    HTTP.send_message(pid, %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})
    assert_receive {:request, "POST", _, _}, 2000
    assert_receive {:request, "GET", headers, _}, 2000
    assert Map.new(headers)["last-event-id"] == "cursor-1"
    assert_receive {:mcp_transport, ^pid, {:message, %{"id" => 2, "result" => %{}}}}, 2000
    refute_receive {:request, "GET", _, _}, 100
  end

  test "persistent push GET delivers notification and resumes its own cursor" do
    url =
      server(fn conn, _ ->
        cond do
          conn.method == "POST" ->
            json(conn, %{"id" => 1, "result" => %{}})

          Plug.Conn.get_req_header(conn, "last-event-id") == [] ->
            sse(conn, [
              "id: push-1\nretry: 10\ndata: {\"method\":\"notifications/tools/list_changed\"}\n\n"
            ])

          true ->
            Plug.Conn.send_resp(conn, 405, "")
        end
      end)

    pid = client(url)
    HTTP.send_message(pid, %{"id" => 1, "method" => "initialize"})
    assert_receive {:mcp_transport, ^pid, {:message, %{"id" => 1}}}, 2000

    assert_receive {:mcp_transport, ^pid,
                    {:message, %{"method" => "notifications/tools/list_changed"}}},
                   2000

    assert_receive {:request, "GET", headers, _}, 2000
    assert Map.new(headers)["last-event-id"] == nil
    assert_receive {:request, "GET", headers, _}, 2000
    assert Map.new(headers)["last-event-id"] == "push-1"
  end

  test "malformed JSON and oversized SSE report down" do
    for {content_type, body, expected} <- [
          {"application/json", "[1]", :invalid_json_message},
          {"text/event-stream", "data: " <> String.duplicate("x", 4 * 1024 * 1024 + 1),
           :input_too_large}
        ] do
      pid =
        client(
          server(fn conn, _ ->
            conn
            |> Plug.Conn.put_resp_content_type(content_type)
            |> Plug.Conn.send_resp(200, body)
          end)
        )

      HTTP.send_message(pid, %{"id" => 1, "method" => "ping"})
      assert_receive {:mcp_transport, ^pid, {:down, ^expected}}, 5000
    end
  end

  test "session expiration requires owner reinitialization" do
    pid =
      client(
        server(fn conn, _ ->
          if conn.method == "POST" do
            conn
            |> Plug.Conn.put_resp_header("mcp-session-id", "expired-session")
            |> json(%{"id" => 1, "result" => %{}})
          else
            Plug.Conn.send_resp(conn, 404, "")
          end
        end)
      )

    HTTP.send_message(pid, %{"id" => 1, "method" => "initialize"})
    assert_receive {:mcp_transport, ^pid, {:message, _}}, 2000
    assert_receive {:mcp_transport, ^pid, {:down, :session_expired}}, 2000
  end

  test "oversized JSON is bounded and a stopped transport cancels workers" do
    pid =
      client(
        server(fn conn, _ ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, String.duplicate("x", 4 * 1024 * 1024 + 1))
        end)
      )

    HTTP.send_message(pid, %{"id" => 1, "method" => "ping"})
    assert_receive {:mcp_transport, ^pid, {:down, :input_too_large}}, 5000

    pid =
      client(
        server(fn conn, _ ->
          Process.sleep(500)
          Plug.Conn.send_resp(conn, 202, "")
        end)
      )

    HTTP.send_message(pid, %{"method" => "notification"})
    assert_receive {:request, "POST", _, _}, 2000
    workers = :sys.get_state(pid).jobs |> Map.values() |> Enum.map(& &1.pid)
    assert workers != []
    HTTP.stop(pid)
    refute Process.alive?(pid)
    Enum.each(workers, fn worker -> refute Process.alive?(worker) end)
  end

  test "modern mirrored headers and error bodies permit protocol switching" do
    url =
      server(fn conn, _ ->
        if Plug.Conn.get_req_header(conn, "mcp-protocol-version") == ["2026-07-28"] do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            400,
            Jason.encode!(%{
              "id" => 8,
              "error" => %{"code" => -32001, "data" => %{"supported" => ["2025-11-25"]}}
            })
          )
        else
          json(conn, %{"id" => 9, "result" => %{}})
        end
      end)

    {:ok, pid} = HTTP.start_link(self(), %{"url" => url})

    HTTP.send_message(
      pid,
      %{
        "id" => 8,
        "method" => "tools/call",
        "params" => %{
          "name" => "Hello, 世界",
          "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
        }
      },
      %{"Mcp-Param-Region" => " padded "}
    )

    assert_receive {:request, "POST", headers, _}, 2000
    headers = Map.new(headers)
    assert headers["mcp-method"] == "tools/call"
    assert headers["mcp-name"] == "=?base64?" <> Base.encode64("Hello, 世界") <> "?="
    assert headers["mcp-param-region"] == "=?base64?" <> Base.encode64(" padded ") <> "?="
    assert_receive {:mcp_transport, ^pid, {:message, %{"error" => %{"code" => -32001}}}}, 2000
    assert :ok = HTTP.set_protocol(pid, "2025-11-25")
    HTTP.send_message(pid, %{"id" => 9, "method" => "ping"})
    assert_receive {:request, "POST", headers, _}, 2000
    assert Map.new(headers)["mcp-protocol-version"] == "2025-11-25"
    assert_receive {:mcp_transport, ^pid, {:message, %{"id" => 9}}}, 2000
    HTTP.stop(pid)
  end

  test "modern subscription cancellation closes worker without notification POST or GET" do
    url =
      server(fn conn, _ ->
        conn = sse(conn, ["data: {\"method\":\"notifications/subscriptions/acknowledged\"}\n\n"])
        Process.sleep(500)
        conn
      end)

    {:ok, pid} = HTTP.start_link(self(), %{"url" => url})
    HTTP.send_message(pid, %{"id" => 4, "method" => "subscriptions/listen"})
    assert_receive {:request, "POST", _, _}, 2000

    assert_receive {:mcp_transport, ^pid,
                    {:message, %{"method" => "notifications/subscriptions/acknowledged"}}},
                   2000

    [job] = :sys.get_state(pid).jobs |> Map.values()

    HTTP.send_message(pid, %{
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => 4}
    })

    assert :sys.get_state(pid).jobs == %{}
    refute Process.alive?(job.pid)
    refute_receive {:request, _, _, _}, 100
    refute_receive {:mcp_transport, ^pid, {:down, _}}, 100
    HTTP.stop(pid)
  end

  test "modern stream closure does not resume with Last-Event-ID" do
    url =
      server(fn conn, _ ->
        sse(conn, [
          "id: ignored\nretry: 1\ndata: {\"method\":\"notifications/subscriptions/acknowledged\"}\n\n"
        ])
      end)

    {:ok, pid} = HTTP.start_link(self(), %{"url" => url})
    HTTP.send_message(pid, %{"id" => 4, "method" => "subscriptions/listen"})
    assert_receive {:request, "POST", _, _}, 2000
    assert_receive {:mcp_transport, ^pid, {:down, :stream_closed}}, 2000
    refute_receive {:request, "GET", _, _}, 100
  end

  test "modern empty HTTP 400 is surfaced for fallback without killing transport" do
    {:ok, pid} =
      HTTP.start_link(self(), %{
        "url" => server(fn conn, _ -> Plug.Conn.send_resp(conn, 400, "") end)
      })

    HTTP.send_message(pid, %{"id" => 3, "method" => "server/discover"})

    assert_receive {:mcp_transport, ^pid,
                    {:message, %{"id" => 3, "error" => %{"data" => %{"http_status" => 400}}}}},
                   2000

    assert Process.alive?(pid)
    HTTP.stop(pid)
  end

  test "HTTP failure is reported without retrying POST" do
    pid = client(server(fn conn, _ -> Plug.Conn.send_resp(conn, 503, "unavailable") end))
    HTTP.send_message(pid, %{"id" => 1, "method" => "ping"})
    assert_receive {:mcp_transport, ^pid, {:down, {:http_status, 503}}}, 2000
    assert_receive {:request, "POST", _, _}
    refute_receive {:request, "POST", _, _}, 100
  end
end

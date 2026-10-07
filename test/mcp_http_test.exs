defmodule Nano.MCPHTTPFixture do
  use Plug.Router
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  post "/mcp" do
    message = conn.body_params
    config = conn.private[:fixture]
    send(config.owner, {:http_request, conn.method, message, conn.req_headers})
    id = message["id"]
    conn = put_resp_header(conn, "mcp-session-id", "test-session")

    cond do
      message["method"] == "initialize" ->
        result = %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"resources" => %{"subscribe" => true}},
          "serverInfo" => %{"name" => "http-fixture", "version" => "1"}
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))

      id == nil ->
        send_resp(conn, 202, "")

      message["method"] == "tools/call" ->
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

        event = %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{"progressToken" => "p", "progress" => 1}
        }

        {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(event) <> "\n\n")

        response = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"content" => [%{"type" => "text", "text" => "streamed"}]}
        }

        {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(response) <> "\n\n")
        conn

      message["method"] == "bad" ->
        send_resp(conn, 403, "no")

      true ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{}}))
    end
  end

  get "/mcp" do
    config = conn.private[:fixture]
    send(config.owner, {:http_request, conn.method, nil, conn.req_headers})
    conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

    event = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/message",
      "params" => %{"level" => "info", "data" => "pushed before EOF"}
    }

    {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(event) <> "\n\n")
    # The event must be delivered while this request is still open.
    Process.sleep(1_000)
    send(config.owner, :get_finished)
    conn
  end

  match _ do
    send_resp(conn, 404, "")
  end

  def init(config), do: config
  def call(conn, config), do: super(Plug.Conn.put_private(conn, :fixture, config), config)
end

defmodule Nano.MCPHTTPTest do
  use ExUnit.Case, async: false

  test "Streamable HTTP negotiates sessions, streams POST replies and delivers GET before EOF" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "nova-mcp-http-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    http = start_supervised!({Bandit, plug: {Nano.MCPHTTPFixture, %{owner: self()}}, port: 0})
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(http)
    name = "http-" <> Integer.to_string(port)

    assert {:ok, client} =
             Nano.MCP.connect(name,
               config: %{"url" => "http://127.0.0.1:" <> Integer.to_string(port) <> "/mcp"},
               state_dir: dir
             )

    on_exit(fn -> Nano.MCP.disconnect(client) end)
    assert_receive {:http_request, "POST", %{"method" => "initialize"}, _}
    assert_receive {:http_request, "POST", %{"method" => "notifications/initialized"}, headers}
    assert {"mcp-session-id", "test-session"} in headers
    assert {"mcp-protocol-version", "2025-11-25"} in headers
    assert_receive {:http_request, "GET", nil, headers}
    assert {"mcp-session-id", "test-session"} in headers
    assert_receive {:mcp, ^name, "notifications/message", %{"data" => "pushed before EOF"}}, 500
    refute_received :get_finished
    assert {:ok, %{"content" => [%{"text" => "streamed"}]}} = Nano.MCP.call_tool(client, "echo")
    assert_receive {:mcp, ^name, "notifications/progress", %{"progressToken" => "p"}}
    assert {:error, {:http_status, 403}} = Nano.MCP.request(client, "bad")
    assert :ok = Nano.MCP.subscribe(client, "test://one")
    assert :ok = Nano.MCP.unsubscribe(client, "test://one")
  end
end

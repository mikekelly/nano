defmodule Seedling.MCPModernHTTPFixture do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, parent) do
    {:ok, body, conn} = read_body(conn)
    msg = Jason.decode!(body)
    version = get_in(msg, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"])

    unless version == "2026-07-28" and get_req_header(conn, "mcp-protocol-version") == [version] and
             get_req_header(conn, "mcp-method") == [msg["method"]],
           do: raise("bad metadata/header")

    if conn.method != "POST", do: raise("unexpected HTTP method")

    case msg["method"] do
      "server/discover" ->
        reply(conn, msg["id"], %{
          "supportedVersions" => [version],
          "capabilities" => %{"tools" => %{}, "resources" => %{"subscribe" => true}}
        })

      "tools/list" ->
        tool = %{
          "name" => "echo",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"tenant" => %{"type" => "string", "x-mcp-header" => "Tenant"}}
          }
        }

        invalid =
          put_in(tool, ["name"], "bad")
          |> put_in(["inputSchema", "properties", "tenant", "x-mcp-header"], "bad\r\nheader")

        reply(conn, msg["id"], %{"tools" => [tool, invalid]})

      "tools/call" ->
        send(
          parent,
          {:headers, get_req_header(conn, "mcp-name"), get_req_header(conn, "mcp-param-tenant")}
        )

        reply(conn, msg["id"], %{"content" => [%{"type" => "text", "text" => "ok"}]})

      "subscriptions/listen" ->
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

        {:ok, conn} =
          chunk(
            conn,
            event("notifications/subscriptions/acknowledged", %{
              "_meta" => %{"io.modelcontextprotocol/subscriptionId" => msg["id"]},
              "notifications" => msg["params"]["notifications"]
            })
          )

        send(parent, {:stream, self()})
        loop(conn, msg["id"])
    end
  end

  defp loop(conn, id) do
    receive do
      :update ->
        case chunk(
               conn,
               event("notifications/resources/updated", %{
                 "uri" => "test://one",
                 "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id}
               })
             ) do
          {:ok, conn} -> loop(conn, id)
          _ -> conn
        end

      :close ->
        {:ok, conn} =
          chunk(
            conn,
            "data: " <>
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "id" => id,
                "result" => %{"resultType" => "complete"}
              }) <> "\n\n"
          )

        conn
    after
      100 ->
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> loop(conn, id)
          _ -> conn
        end
    end
  end

  defp event(method, params),
    do:
      "data: " <>
        Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params}) <> "\n\n"

  defp reply(conn, id, result),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => Map.put(result, "resultType", "complete")
        })
      )
end

defmodule Seedling.MCPModernHTTPTest do
  use ExUnit.Case, async: true

  test "modern HTTP long-lived subscriptions, metadata, mirrored headers and reconnect" do
    {:ok, listener} =
      Bandit.start_link(
        plug: {Seedling.MCPModernHTTPFixture, self()},
        port: 0,
        ip: {127, 0, 0, 1}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(listener)

    dir =
      Path.join(System.tmp_dir!(), "lyra-mcp-modern-http-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    parent = self()

    {:ok, c} =
      Seedling.MCP.Client.start_link(
        server_name: "modern-http",
        server: %{"url" => "http://127.0.0.1:#{port}/mcp"},
        state_dir: dir,
        resolver: fn _ -> parent end,
        reconnect_ms: 20
      )

    wait(c)
    assert Seedling.MCP.status(c).era == :modern
    assert :ok = Seedling.MCP.subscribe(c, "test://one", "agent")
    assert_receive {:stream, stream}
    send(stream, :update)
    assert_receive {:mcp, "modern-http", "notifications/resources/updated", _}
    assert {:ok, %{"tools" => [%{"name" => "echo"}]}} = Seedling.MCP.request(c, "tools/list")
    assert_receive {:mcp, "modern-http", "invalid_tool_schema", _}
    assert {:ok, _} = Seedling.MCP.call_tool(c, "echo", %{"tenant" => "日本"})
    assert_receive {:headers, ["echo"], ["=?base64?5pel5pys?="]}
    send(stream, :close)
    assert_receive {:mcp, "modern-http", "disconnected", _}
    wait(c)
    assert_receive {:mcp, "modern-http", "recovered", %{era: "modern"}}
    assert_receive {:stream, stream2}
    send(stream2, :update)
    assert_receive {:mcp, "modern-http", "notifications/resources/updated", _}
    GenServer.stop(c)
    Supervisor.stop(listener)
  end

  defp wait(c),
    do:
      Enum.reduce_while(1..100, nil, fn _, _ ->
        if Seedling.MCP.status(c).ready,
          do: {:halt, :ok},
          else:
            (
              Process.sleep(20)
              {:cont, nil}
            )
      end)
end

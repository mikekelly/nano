defmodule Seedling.MCPHTTPFixture do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, parent) do
    send(
      parent,
      {:http_request, conn.method, get_req_header(conn, "mcp-session-id"),
       get_req_header(conn, "mcp-protocol-version")}
    )

    if conn.method == "GET" do
      conn |> send_resp(405, "")
    else
      {:ok, body, conn} = read_body(conn)
      msg = Jason.decode!(body)

      cond do
        msg["method"] == "initialize" ->
          reply(conn |> put_resp_header("mcp-session-id", "test-session"), msg["id"], %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{"tools" => %{}, "resources" => %{"subscribe" => true}},
            "serverInfo" => %{"name" => "http-fixture", "version" => "1"}
          })

        !msg["id"] ->
          send_resp(conn, 202, "")

        msg["method"] == "tools/call" ->
          event =
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "method" => "notifications/resources/updated",
              "params" => %{"uri" => "test://one"}
            })

          result =
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => msg["id"],
              "result" => %{"content" => [%{"type" => "text", "text" => "ok"}]}
            })

          conn
          |> put_resp_content_type("text/event-stream")
          |> send_resp(200, "data: #{event}\r\n\r\ndata: #{result}\n\n")

        true ->
          reply(conn, msg["id"], %{})
      end
    end
  end

  defp reply(conn, id, result),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
end

defmodule Seedling.MCPHTTPTest do
  use ExUnit.Case, async: true

  test "streamable HTTP sessions, JSON response and SSE notification/response" do
    {:ok, listener} =
      Bandit.start_link(plug: {Seedling.MCPHTTPFixture, self()}, port: 0, ip: {127, 0, 0, 1})

    {:ok, {_, port}} = ThousandIsland.listener_info(listener)
    dir = Path.join(System.tmp_dir!(), "lyra-mcp-http-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    parent = self()

    {:ok, c} =
      Seedling.MCP.Client.start_link(
        server_name: "http",
        server: %{"url" => "http://127.0.0.1:#{port}/mcp"},
        state_dir: dir,
        resolver: fn _ -> parent end
      )

    Enum.reduce_while(1..100, nil, fn _, _ ->
      if Seedling.MCP.status(c).ready,
        do: {:halt, :ok},
        else:
          (
            Process.sleep(20)
            {:cont, nil}
          )
    end)

    assert Seedling.MCP.status(c).ready
    assert_receive {:http_request, "POST", [], ["2025-11-25"]}
    assert :ok = Seedling.MCP.subscribe(c, "test://one", "agent")
    assert_receive {:http_request, "POST", ["test-session"], ["2025-11-25"]}
    assert {:ok, %{"content" => [_]}} = Seedling.MCP.call_tool(c, "notify")
    assert_receive {:mcp, "http", "notifications/resources/updated", %{"uri" => "test://one"}}
    GenServer.stop(c)
    Supervisor.stop(listener)
  end
end

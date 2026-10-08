defmodule Seedling.MCP.TestHTTP do
  @moduledoc false
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)
    message = if body == "", do: nil, else: Jason.decode!(body)
    send(opts[:owner], {:http_request, conn.method, Map.new(conn.req_headers), message})

    cond do
      opts[:mode] == :legacy -> legacy(conn, message, opts)
      true -> modern(conn, message, opts)
    end
  end

  defp modern(conn, req, _opts) do
    true = get_req_header(conn, "mcp-protocol-version") == ["2026-07-28"]
    true = get_req_header(conn, "mcp-method") == [req["method"]]

    true =
      get_in(req, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"]) == "2026-07-28"

    case req["method"] do
      "server/discover" ->
        json(conn, req, %{
          "resultType" => "complete",
          "supportedVersions" => ["2026-07-28"],
          "capabilities" => %{
            "tools" => %{},
            "resources" => %{"subscribe" => true},
            "prompts" => %{}
          }
        })

      "tools/list" ->
        json(conn, req, %{
          "tools" => [
            %{
              "name" => "echo",
              "inputSchema" => %{
                "type" => "object",
                "properties" => %{"tenant" => %{"type" => "string", "x-mcp-header" => "Tenant"}}
              }
            },
            %{
              "name" => "bad",
              "inputSchema" => %{
                "type" => "object",
                "properties" => %{"x" => %{"type" => "number", "x-mcp-header" => "bad\n"}}
              }
            }
          ]
        })

      "tools/call" ->
        true = get_req_header(conn, "mcp-name") == ["echo"]

        true =
          get_req_header(conn, "mcp-param-tenant") == [
            Seedling.MCP.Headers.encode(req["params"]["arguments"]["tenant"])
          ]

        {:ok, conn} =
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)
          |> chunk(":keepalive\r\n\r\n")

        payload =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{
              "progressToken" => req["params"]["_meta"]["progressToken"],
              "progress" => 1
            }
          })

        {:ok, conn} = chunk(conn, "data: " <> payload <> "\r")
        {:ok, conn} = chunk(conn, "\n\r\n")

        {:ok, conn} =
          chunk(
            conn,
            "data: " <>
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "method" => "notifications/message",
                "params" => %{"level" => "info", "data" => "stream log"}
              }) <> "\n\n"
          )

        {:ok, conn} =
          chunk(
            conn,
            "data: " <>
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "id" => req["id"],
                "result" => %{"content" => [%{"type" => "text", "text" => "done"}]}
              }) <> "\n\n"
          )

        conn

      "subscriptions/listen" ->
        meta = %{"_meta" => %{"io.modelcontextprotocol/subscriptionId" => req["id"]}}

        {:ok, conn} =
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)
          |> chunk(
            sse(
              "notifications/subscriptions/acknowledged",
              Map.put(meta, "notifications", req["params"]["notifications"])
            )
          )

        conn =
          Enum.reduce(req["params"]["notifications"]["resourceSubscriptions"], conn, fn uri,
                                                                                        conn ->
            {:ok, conn} =
              chunk(conn, sse("notifications/resources/updated", Map.put(meta, "uri", uri)))

            conn
          end)

        Process.sleep(600)
        conn

      _ ->
        json(conn, req, %{})
    end
  end

  defp legacy(conn, req, opts) do
    case {conn.method, req && req["method"]} do
      {"GET", _} ->
        {:ok, conn} =
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)
          |> chunk(
            "id: cursor-1\n" <> sse("notifications/resources/updated", %{"uri" => "test://one"})
          )

        Process.sleep(600)
        conn

      {"POST", "server/discover"} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => req["id"],
            "error" => %{"code" => -32602, "message" => "Initialize first"}
          })
        )

      {"POST", "initialize"} ->
        conn
        |> put_resp_header("mcp-session-id", "session-1")
        |> json(req, %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"resources" => %{"subscribe" => true}, "tools" => %{}}
        })

      {"POST", "notifications/initialized"} ->
        send_resp(conn, 202, "")

      {"POST", "tools/call"} ->
        true = get_req_header(conn, "mcp-session-id") == ["session-1"]

        if :ets.insert_new(opts[:table], {:expired, true}),
          do: send_resp(conn, 404, ""),
          else: json(conn, req, %{"content" => []})

      {"POST", "resources/subscribe"} ->
        json(conn, req, %{})

      {"POST", "notifications/cancelled"} ->
        send_resp(conn, 202, "")

      {"DELETE", _} ->
        send_resp(conn, 204, "")

      _ ->
        json(conn, req, %{})
    end
  end

  defp json(conn, req, result),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => req["id"], "result" => result})
      )

  defp sse(method, params),
    do:
      "data: " <>
        Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params}) <> "\n\n"
end

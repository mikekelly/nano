defmodule Nano.Test.MCPHTTPFixture do
  @moduledoc false
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, opts) do
    state = opts[:state]
    modern = conn.request_path == "/modern"

    if conn.method == "GET" do
      if modern, do: send_resp(conn, 405, ""), else: listen(conn, state, nil, false)
    else
      {:ok, body, conn} = read_body(conn)
      message = Jason.decode!(body)
      Agent.update(state, &Map.update!(&1, :requests, fn r -> [message | r] end))
      method = message["method"]
      id = message["id"]
      params = Map.get(message, "params", %{})

      cond do
        not modern and method == "server/discover" ->
          send_resp(conn, 400, "initialize required")

        modern and method == "subscriptions/listen" ->
          meta = get_in(params, ["_meta", "io.modelcontextprotocol/protocolVersion"])

          if meta != "2026-07-28" or get_req_header(conn, "mcp-method") != [method] do
            send_resp(conn, 400, "metadata required")
          else
            listen(conn, state, {id, params["notifications"]}, true)
          end

        method == "notifications/initialized" ->
          send_resp(conn, 202, "")

        method == "notifications/cancelled" ->
          send_resp(conn, 202, "")

        true ->
          result =
            case method do
              "server/discover" ->
                %{"supportedVersions" => ["2026-07-28"], "capabilities" => caps()}

              "initialize" ->
                %{
                  "protocolVersion" => "2025-11-25",
                  "capabilities" => caps(),
                  "serverInfo" => %{"name" => "http-fixture", "version" => "1"}
                }

              "tools/list" ->
                %{
                  "tools" => [
                    %{"name" => "update", "inputSchema" => %{"type" => "object"}},
                    %{
                      "name" => "tenant",
                      "inputSchema" => %{
                        "type" => "object",
                        "properties" => %{
                          "tenant" => %{"type" => "string", "x-mcp-header" => "Tenant"}
                        }
                      }
                    },
                    %{
                      "name" => "bad",
                      "inputSchema" => %{
                        "type" => "object",
                        "properties" => %{"bad" => %{"type" => "number", "x-mcp-header" => "Bad"}}
                      }
                    }
                  ]
                }

              "resources/list" ->
                %{"resources" => [%{"uri" => "http://fixture/resource", "name" => "resource"}]}

              "resources/templates/list" ->
                %{"resourceTemplates" => []}

              "prompts/list" ->
                %{"prompts" => [%{"name" => "hello"}]}

              "prompts/get" ->
                %{"messages" => []}

              "resources/read" ->
                %{"contents" => [%{"uri" => params["uri"], "text" => "http resource"}]}

              "resources/subscribe" ->
                Agent.update(
                  state,
                  &Map.update!(&1, :uris, fn uris -> Enum.uniq([params["uri"] | uris]) end)
                )

                %{}

              "resources/unsubscribe" ->
                Agent.update(
                  state,
                  &Map.update!(&1, :uris, fn uris -> List.delete(uris, params["uri"]) end)
                )

                %{}

              "tools/call" ->
                Agent.update(state, &Map.put(&1, :last_headers, conn.req_headers))
                Agent.get(state, & &1.listeners) |> Enum.each(fn pid -> send(pid, :update) end)
                %{"content" => [%{"type" => "text", "text" => "updated"}]}

              _ ->
                %{}
            end

          conn =
            if method == "initialize",
              do: put_resp_header(conn, "mcp-session-id", "test-session"),
              else: conn

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
      end
    end
  end

  defp caps,
    do: %{
      "tools" => %{"listChanged" => true},
      "resources" => %{"subscribe" => true, "listChanged" => true},
      "prompts" => %{}
    }

  defp listen(conn, state, subscription, modern) do
    conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
    pid = self()

    Agent.update(
      state,
      &Map.update!(&1, :listeners, fn pids -> [pid | List.delete(pids, state)] end)
    )

    conn =
      case subscription do
        {id, filter} ->
          ack = %{
            "jsonrpc" => "2.0",
            "method" => "notifications/subscriptions/acknowledged",
            "params" => %{
              "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id},
              "notifications" => filter
            }
          }

          {:ok, conn} = chunk(conn, frame(ack))
          conn

        nil ->
          conn
      end

    loop(conn, state, subscription, modern)
  end

  defp loop(conn, state, subscription, modern) do
    receive do
      :update ->
        {id, uris} =
          case subscription do
            {id, filter} -> {id, filter["resourceSubscriptions"] || []}
            _ -> {nil, Agent.get(state, & &1.uris)}
          end

        frames =
          Enum.map(uris, fn uri ->
            params = %{"uri" => uri}

            params =
              if modern,
                do: Map.put(params, "_meta", %{"io.modelcontextprotocol/subscriptionId" => id}),
                else: params

            frame(%{
              "jsonrpc" => "2.0",
              "method" => "notifications/resources/updated",
              "params" => params
            })
          end)

        case chunk(conn, frames) do
          {:ok, conn} -> loop(conn, state, subscription, modern)
          _ -> conn
        end
    after
      5000 -> conn
    end
  end

  defp frame(message), do: "data: " <> Jason.encode!(message) <> "\n\n"
end

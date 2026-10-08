defmodule Seedling.MCP do
  @moduledoc """
  MCP client (2025-11-25 stable wire revision). No harness changes required.
  `{:ok, c} = Seedling.MCP.connect("filesystem", config: "config/mcp.json")`
  `discover(c)`, `call_tool(c, "name", %{})`, `read_resource(c, "uri")`.
  `subscribe(c, "uri", "agent-name")` routes ordinary mailbox events and persists
  names, not pids. Start the client under your supervisor for client-process recovery.
  StdIO connections reconnect and replay subscriptions after server exits. Raw results
  are returned; use `page/2` before printing large results.
  """
  alias Seedling.MCP.Client

  def connect(name, opts \\ []) do
    with {:ok, text} <- File.read(Keyword.get(opts, :config, "config/mcp.json")),
         {:ok, config} <- Jason.decode(text),
         server when is_map(server) <- get_in(config, ["mcpServers", name]) do
      Client.start_link(Keyword.merge(opts, server: server, server_name: name))
    else
      nil -> {:error, :unknown_server}
      error -> error
    end
  end

  @doc "Return/start a configured supervised connection; requires the MCP supervisor to be running."
  def ensure_connection(name, opts \\ []) do
    sup = Keyword.get(opts, :supervisor, Seedling.MCP.Supervisor)

    try do
      case Seedling.MCP.Supervisor.connections(sup)[name] do
        pid when is_pid(pid) ->
          {:ok, pid}

        :restarting ->
          {:error, :restarting}

        _ ->
          with {:ok, text} <- File.read(Keyword.get(opts, :config, "config/mcp.json")),
               {:ok, config} <- Jason.decode(text),
               server when is_map(server) <- get_in(config, ["mcpServers", name]) do
            child_opts =
              opts
              |> Keyword.drop([:supervisor, :config, :name])
              |> Keyword.merge(server_name: name, server: server)

            child = Supervisor.child_spec({Client, child_opts}, id: name)

            case Supervisor.start_child(sup, child) do
              {:error, {:already_started, pid}} -> {:ok, pid}
              {:error, :already_present} -> {:error, :restarting}
              result -> result
            end
          else
            nil -> {:error, :unknown_server}
            error -> error
          end
      end
    catch
      :exit, reason -> {:error, {:supervisor_unavailable, reason}}
    end
  end

  def request(c, method, params \\ %{}, timeout \\ 30_000),
    do: GenServer.call(c, {:request, method, params, timeout}, timeout + 1000)

  def discover(c) do
    for {key, method} <- [
          tools: "tools/list",
          resources: "resources/list",
          templates: "resources/templates/list",
          prompts: "prompts/list"
        ],
        into: %{} do
      {key, list(c, method, %{}, [])}
    end
  end

  defp list(c, method, params, pages) do
    case request(c, method, params) do
      {:ok, %{"nextCursor" => cursor} = page} when is_binary(cursor) ->
        if Enum.any?(pages, &(Map.get(&1, "nextCursor") == cursor)),
          do: {:error, :cursor_loop},
          else: list(c, method, %{"cursor" => cursor}, pages ++ [page])

      {:ok, page} ->
        {:ok, pages ++ [page]}

      error ->
        error
    end
  end

  def call_tool(c, name, arguments \\ %{}),
    do: request(c, "tools/call", %{"name" => name, "arguments" => arguments})

  def read_resource(c, uri), do: request(c, "resources/read", %{"uri" => uri})

  def get_prompt(c, name, arguments \\ %{}),
    do: request(c, "prompts/get", %{"name" => name, "arguments" => arguments})

  def subscribe(c, uri, agent), do: GenServer.call(c, {:subscription, :add, uri, agent}, 31_000)

  def unsubscribe(c, uri, agent),
    do: GenServer.call(c, {:subscription, :remove, uri, agent}, 31_000)

  def watch(c, agent), do: GenServer.call(c, {:watch, agent})
  def status(c), do: GenServer.call(c, :status)

  @doc "JSON text paged by Unicode character offset (default 8000, maximum 50000)."
  def page(result, opts \\ []) do
    text = Jason.encode!(result)
    offset = max(Keyword.get(opts, :offset, 0), 0)
    limit = Keyword.get(opts, :limit, 8000) |> min(50_000) |> max(1)
    length = String.length(text)

    %{
      text: String.slice(text, offset, limit),
      characters: length,
      bytes: byte_size(text),
      next_offset: if(offset + limit < length, do: offset + limit)
    }
  end
end

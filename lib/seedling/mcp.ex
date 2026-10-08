defmodule Seedling.MCP do
  @moduledoc """
  Dual-era MCP client (2026-07-28 current; legacy initialize fallback). No harness changes required.
  `{:ok, c} = Seedling.MCP.connect("filesystem", config: "config/mcp.json")`
  `discover(c)`, `call_tool(c, "name", %{})`, `read_resource(c, "uri")`.
  `subscribe(c, "uri", "agent-name")` routes ordinary mailbox events and persists
  names, not pids. Start the client under your supervisor for client-process recovery.
  Connections reconnect and replay durable subscriptions after server exits.
  Large results spill to disk automatically; use `result_page/2` to retrieve them.
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
    sup = Keyword.get(opts, :supervisor, Seedling.MCP.Connections)

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

  @doc "Discover one bounded page per category by default; all: true follows cursors (maximum 100 pages)."
  def discover(c, opts \\ []) do
    for {key, method} <- [
          tools: "tools/list",
          resources: "resources/list",
          templates: "resources/templates/list",
          prompts: "prompts/list"
        ],
        into: %{} do
      {key,
       if(Keyword.get(opts, :all, false),
         do: list(c, method, %{}, []),
         else:
           case request(c, method) do
             {:ok, page} -> {:ok, [page]}
             error -> error
           end
       )}
    end
  end

  defp list(c, method, params, pages) do
    case request(c, method, params) do
      {:ok, %{"nextCursor" => cursor} = page} when is_binary(cursor) ->
        if length(pages) >= 99 or Enum.any?(pages, &(Map.get(&1, "nextCursor") == cursor)),
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

  @doc "Read a spilled result without loading the entire file. Offsets/limits are bytes; pages end at UTF-8 boundaries."
  def result_page(path, opts \\ []) do
    offset = max(Keyword.get(opts, :offset, 0), 0)
    limit = Keyword.get(opts, :limit, 8000) |> max(4) |> min(50_000)

    with {:ok, stat} <- File.stat(path), {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        :file.position(io, offset)

        data =
          case IO.binread(io, limit) do
            :eof -> ""
            text when is_binary(text) -> text
          end

        case :unicode.characters_to_binary(data, :utf8, :utf8) do
          text when is_binary(text) ->
            {:ok,
             %{
               text: text,
               bytes: stat.size,
               next_offset: if(offset + byte_size(text) < stat.size, do: offset + byte_size(text))
             }}

          {:incomplete, text, _} ->
            {:ok, %{text: text, bytes: stat.size, next_offset: offset + byte_size(text)}}

          {:error, _, _} ->
            {:error, :offset_not_utf8_boundary}
        end
      after
        File.close(io)
      end
    end
  end

  @doc "JSON text paged
 by Unicode character offset (default 8000, maximum 50000)."
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

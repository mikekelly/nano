defmodule Nano.MCP do
  @moduledoc """
  MCP tools, resources, prompts and push events from `eval`, addressed by stable
  agent name and a server ID in `priv/mcp_servers.json`. See `Nano.MCP.Config`
  for configuration and secret references. Supervised connections are independent
  of agent pids. Subscription intent is stored under the node's state directory;
  server restarts reconnect with exponential backoff and re-subscribe. Failed restores
  emit subscription_restore_failed with URI(s), reason and retryMs and retry with
  exponential backoff (250 ms to 30 seconds). `catalog/2` shows desired and active
  subscriptions separately, so a ready transport is not mistaken for restored intent.
  Notifications,
  disconnects and catalog changes reach `NanoAgent.notify/2` and the timeline.

      Nano.MCP.connect("scout", "filesystem")
      Nano.MCP.catalog("scout", "filesystem")
      Nano.MCP.tools("scout", "filesystem")
      Nano.MCP.call_tool("scout", "filesystem", "read_file", %{"path" => "/tmp/a"})
      Nano.MCP.subscribe("scout", "watcher", "file:///tmp/a")
      Nano.MCP.page("<returned page id>", offset: 61)

  Current protocol researched 2026-10-10: **2026-07-28**, dual-era support with
  2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05 initialization fallback.
  Modern requests carry version, client info and capabilities in `_meta` and use
  `server/discover` and `subscriptions/listen`. Legacy servers use initialize,
  initialized and resources/subscribe. Both stdio and Streamable HTTP support
  notifications; deprecated HTTP+SSE transport is deliberately not supported.
  Sampling, roots, elicitation and optional extensions are not advertised.

  Automatic discovery keeps the first page of each advertised catalog, including
  resource templates; list-change events refresh it. List functions accept `cursor:`
  for subsequent server pages. All results and errors are bounded with stored paging
  (`Nano.MCP.Page`). Stored pages expire after seven days or 128 MiB retained;
  a wrapped display view is paged while the original JSON stays available at raw_path.
  Modern HTTP tool schemas with invalid x-mcp-header annotations are rejected, and
  valid argument headers are encoded/mirrored. Call tools/3 first for unknown tools
  and cursor pages; schema cache is bounded to 4 MiB/10,000 entries.
  Concurrent subscription mutations return :subscription_busy, so callers can retry.
  Request timeout defaults to 30 seconds; cancellation is sent
  and pending calls fail immediately on disconnect. Calls are not automatically
  retried (a tool may have side effects). Queued events while an agent is absent
  are bounded to 64 and persisted; delivery is best-effort, not exactly-once.

  Delegation integration: application env `:nano, :delegation_mcp_initializer`
  is `{Nano.MCP, :initialize, []}`. `initialize/2` accepts a list of server IDs or
  `%{server: id, subscriptions: [uri]}` maps; it cleans up sessions it created on
  failure without disturbing pre-existing sessions. Config is empty by default:
  no third-party executable or credential is silently installed or run at boot.
  """
  alias Nano.MCP.{Manager, Connection}

  def servers do
    with {:ok, config} <- Nano.MCP.Config.load(), do: {:ok, Enum.sort(Map.keys(config))}
  end

  def connect(agent, server, opts \\ []) do
    case safe(fn -> connect_owned(agent, server, opts) end) do
      {:ok, _created} -> :ok
      error -> error
    end
  end

  defp connect_owned(agent, server, opts) do
    ms = timeout(opts)

    with {:ok, pid, created} <- Manager.connect(agent, server) do
      case safe(fn -> Connection.await(pid, ms) end) do
        :ok ->
          {:ok, created}

        error ->
          if created, do: Manager.disconnect(agent, server)
          error
      end
    end
  end

  def disconnect(agent, server), do: safe(fn -> Manager.disconnect(agent, server) end)
  def connections, do: safe(fn -> Manager.list() end)

  def catalog(agent, server) do
    with {:ok, pid} <- safe(fn -> Manager.session(agent, server) end),
         do: safe(fn -> Connection.catalog(pid) end)
  end

  def tools(agent, server, opts \\ []), do: listing(agent, server, "tools/list", opts)
  def resources(agent, server, opts \\ []), do: listing(agent, server, "resources/list", opts)

  def resource_templates(agent, server, opts \\ []),
    do: listing(agent, server, "resources/templates/list", opts)

  def prompts(agent, server, opts \\ []), do: listing(agent, server, "prompts/list", opts)

  def call_tool(agent, server, name, arguments \\ %{}, opts \\ []),
    do: request(agent, server, "tools/call", %{"name" => name, "arguments" => arguments}, opts)

  def read_resource(agent, server, uri, opts \\ []),
    do: request(agent, server, "resources/read", %{"uri" => uri}, opts)

  def get_prompt(agent, server, name, arguments \\ %{}, opts \\ []),
    do: request(agent, server, "prompts/get", %{"name" => name, "arguments" => arguments}, opts)

  def request(agent, server, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) do
    with {:ok, pid} <- safe(fn -> Manager.session(agent, server) end) do
      Manager.event(agent, server, "request_started", %{"method" => method})
      result = safe(fn -> Connection.request(pid, method, params, timeout(opts)) end)

      Manager.event(agent, server, "request_finished", %{
        "method" => method,
        "success" => match?({:ok, _}, result)
      })

      result
    end
  end

  def subscribe(agent, server, uri, opts \\ []),
    do: change_subscription(agent, server, uri, :add, opts)

  def unsubscribe(agent, server, uri, opts \\ []),
    do: change_subscription(agent, server, uri, :remove, opts)

  defp change_subscription(agent, server, uri, action, opts)
       when is_binary(uri) and byte_size(uri) <= 8192 do
    safe(fn -> Manager.change_subscription(agent, server, uri, action, timeout(opts)) end)
  end

  defp change_subscription(_, _, _, _, _), do: {:error, :invalid_resource_uri}
  def page(id, opts \\ []), do: Nano.MCP.Page.read(id, opts)
  @doc "Delegation's optional MCP initializer MFA contract, with cleanup on failure."
  def initialize(child_name, servers) when is_list(servers) do
    Enum.reduce_while(servers, {:ok, %{created: [], snapshots: %{}}}, fn spec, {:ok, acc} ->
      case initializer_spec(spec) do
        {:ok, id, uris} ->
          case safe(fn -> connect_owned(child_name, id, []) end) do
            {:ok, new?} ->
              acc =
                cond do
                  new? ->
                    %{acc | created: [id | acc.created]}

                  id in acc.created or Map.has_key?(acc.snapshots, id) ->
                    acc

                  true ->
                    {:ok, old} = Manager.uris(child_name, id)
                    %{acc | snapshots: Map.put(acc.snapshots, id, old)}
                end

              result =
                Enum.reduce_while(uris, :ok, fn uri, _ ->
                  case subscribe(child_name, id, uri) do
                    :ok -> {:cont, :ok}
                    error -> {:halt, error}
                  end
                end)

              if result == :ok, do: {:cont, {:ok, acc}}, else: {:halt, {:error, result, acc}}

            error ->
              {:halt, {:error, error, acc}}
          end

        error ->
          {:halt, {:error, error, acc}}
      end
    end)
    |> case do
      {:ok, _} ->
        :ok

      {:error, why, acc} ->
        cleanup =
          Enum.map(acc.created, fn id -> safe(fn -> disconnect(child_name, id) end) end) ++
            Enum.map(acc.snapshots, fn {id, old} ->
              safe(fn -> Manager.change_subscription(child_name, id, old, :replace, 30000) end)
            end)

        errors = Enum.reject(cleanup, &(&1 == :ok))
        if errors == [], do: {:error, why}, else: {:error, %{reason: why, cleanup_errors: errors}}
    end
  end

  def initialize(_, _), do: {:error, :servers_must_be_a_list}
  defp initializer_spec(id) when is_binary(id), do: {:ok, id, []}

  defp initializer_spec(%{server: id, subscriptions: uris}) when is_binary(id) and is_list(uris),
    do: {:ok, id, uris}

  defp initializer_spec(%{"server" => id, "subscriptions" => uris})
       when is_binary(id) and is_list(uris), do: {:ok, id, uris}

  defp initializer_spec(_), do: {:error, :invalid_server_spec}

  defp listing(agent, server, method, opts) do
    params = if opts[:cursor], do: %{"cursor" => opts[:cursor]}, else: %{}
    request(agent, server, method, params, opts)
  end

  defp timeout(opts) do
    value =
      if is_list(opts) and Keyword.keyword?(opts),
        do: Keyword.get(opts, :timeout, 30000),
        else: nil

    if is_integer(value) and value > 0,
      do: min(value, 120_000),
      else: raise(ArgumentError, "timeout must be a positive integer")
  end

  defp safe(fun) do
    try do
      fun.()
    rescue
      ArgumentError -> {:error, :invalid_argument}
    catch
      :exit, _ -> {:error, :connection_unavailable}
    end
  end
end

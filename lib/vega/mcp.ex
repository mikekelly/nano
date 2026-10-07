defmodule Vega.MCP do
  @moduledoc """
  MCP client for current 2026-07-28 and legacy 2025-11-25/06-18/03-26.
  Set server config `"protocol": "2026-07-28"` for modern stateless requests
  and POST subscriptions; default legacy mode preserves compatibility.
  Server definitions live in `/app/priv/vega_mcp.json`. See `docs/vega-mcp.md`.

      Vega.MCP.connect("filesystem")
      Vega.MCP.tools("filesystem")
      Vega.MCP.call_tool("filesystem", "read_file", %{"path" => "/tmp/example"})
      Vega.MCP.subscribe("server", "resource://changes", "agent-name")

  Results are `{:ok, value}` or `{:error, reason}`. Oversized values become a
  bounded preview with a JSON spill file; use `page/2`. List APIs return one
  protocol page, including `nextCursor`, rather than invisibly fetching everything.
  Events go through `NanoAgent.notify/2` to names, not ephemeral agent pids.
  """
  @config "/app/priv/vega_mcp.json"
  def config_path, do: Application.get_env(:nano, :vega_mcp_config, @config)

  def servers(path \\ config_path()) do
    with {:ok, text} <- File.read(path), {:ok, value} <- Jason.decode(text) do
      case value do
        %{"mcpServers" => servers} when is_map(servers) -> {:ok, servers}
        _ -> {:error, :invalid_config_file}
      end
    end
  end

  def start do
    case Process.whereis(Vega.MCP.Supervisor) do
      nil ->
        case Vega.MCP.Supervisor.start_link([]) do
          {:ok, pid} ->
            if stable = Process.whereis(:user), do: Process.group_leader(pid, stable)
            Process.unlink(pid)
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          other ->
            other
        end

      pid ->
        {:ok, pid}
    end
  end

  def connect(name, config \\ nil) when is_binary(name) do
    with {:ok, _} <- start(),
         {:ok, config} <- definition(name, config),
         :ok <- validate(config),
         :ok <- Vega.MCP.Config.put(name, config) do
      case Registry.lookup(Vega.MCP.Registry, name) do
        [{pid, _}] ->
          ready(pid)

        [] ->
          case DynamicSupervisor.start_child(
                 Vega.MCP.Connections,
                 {Vega.MCP.Connection, name}
               ) do
            {:ok, pid} -> ready(pid)
            {:error, {:already_started, pid}} -> ready(pid)
            error -> error
          end
      end
    end
  end

  defp validate(config) when is_map(config) do
    stdio =
      is_binary(config["command"]) and is_list(Map.get(config, "args", [])) and
        Enum.all?(Map.get(config, "args", []), &is_binary/1) and
        is_map(Map.get(config, "env", %{})) and
        Enum.all?(Map.get(config, "env", %{}), fn {k, v} -> is_binary(k) and is_binary(v) end)

    url = config["url"]

    http =
      is_binary(url) and URI.parse(url).scheme in ["http", "https"] and
        is_binary(URI.parse(url).host)

    limit = Map.get(config, "result_limit", 16384)
    headers = Map.get(config, "headers", %{})

    headers_valid =
      is_map(headers) and Enum.all?(headers, fn {k, v} -> is_binary(k) and is_binary(v) end)

    if (stdio or http) and is_integer(limit) and limit > 0 and headers_valid and
         Map.get(config, "protocol", "2025-11-25") in [
           "2026-07-28",
           "2025-11-25",
           "2025-06-18",
           "2025-03-26"
         ],
       do: :ok,
       else: {:error, :invalid_server_config}
  end

  defp validate(_), do: {:error, :invalid_server_config}

  defp definition(_name, config) when is_map(config), do: {:ok, config}

  defp definition(name, nil) do
    with {:ok, servers} <- servers() do
      case Map.fetch(servers, name) do
        {:ok, config} -> {:ok, config}
        :error -> {:error, :unknown_server}
      end
    end
  end

  defp definition(_, _), do: {:error, :invalid_server_config}

  defp ready(pid), do: safe_call(pid, :ready, 25_000)

  def disconnect(name) do
    case lookup(name) do
      {:ok, pid} ->
        case DynamicSupervisor.terminate_child(Vega.MCP.Connections, pid) do
          :ok -> await_unregistered(name, pid, 20)
          error -> error
        end

      error ->
        error
    end
  end

  defp await_unregistered(_name, _pid, 0), do: :ok

  defp await_unregistered(name, pid, n) do
    case Registry.lookup(Vega.MCP.Registry, name) do
      [{^pid, _}] ->
        Process.sleep(5)
        await_unregistered(name, pid, n - 1)

      _ ->
        :ok
    end
  end

  def status(name), do: invoke(name, :status)
  def watch(name, agent) when is_binary(agent), do: invoke(name, {:watch, agent}, 25_000)
  def unwatch(name, agent), do: invoke(name, {:unwatch, agent}, 25_000)
  def tools(name, cursor \\ nil), do: list(name, "tools/list", cursor)
  def resources(name, cursor \\ nil), do: list(name, "resources/list", cursor)
  def resource_templates(name, cursor \\ nil), do: list(name, "resources/templates/list", cursor)
  def prompts(name, cursor \\ nil), do: list(name, "prompts/list", cursor)
  defp list(name, method, nil), do: request(name, method, %{})
  defp list(name, method, cursor), do: request(name, method, %{"cursor" => cursor})

  def call_tool(name, tool, arguments \\ %{}, opts \\ []),
    do: request(name, "tools/call", %{"name" => tool, "arguments" => arguments}, opts)

  def read_resource(name, uri), do: request(name, "resources/read", %{"uri" => uri})

  def get_prompt(name, prompt, arguments \\ %{}),
    do: request(name, "prompts/get", %{"name" => prompt, "arguments" => arguments})

  def subscribe(name, uri, agent) when is_binary(agent),
    do: invoke(name, {:subscribe, uri, agent}, 25_000)

  def unsubscribe(name, uri, agent), do: invoke(name, {:unsubscribe, uri, agent}, 25_000)

  def request(name, method, params \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 20_000)

    if is_integer(timeout) and timeout > 0 and timeout <= 300_000 and is_binary(method) and
         is_map(params),
       do: invoke(name, {:request, method, params, timeout}, timeout + 1_000),
       else: {:error, :invalid_request}
  end

  @doc "Start a supervised long RPC; completion reaches the named agent as a request/completed event."
  def request_async(name, method, params, agent, opts \\ []) when is_binary(agent) do
    with {:ok, _} <- start() do
      ref = make_ref()

      case Task.Supervisor.start_child(Vega.MCP.Requests, fn ->
             if stable = Process.whereis(:user), do: Process.group_leader(self(), stable)
             result = request(name, method, params, opts)

             NanoAgent.notify(agent, %{
               mcp: name,
               method: "request/completed",
               request_method: method,
               ref: ref,
               result: result
             })
           end) do
        {:ok, _pid} -> {:ok, ref}
        error -> error
      end
    end
  end

  def call_tool_async(name, tool, arguments, agent, opts \\ []),
    do:
      request_async(name, "tools/call", %{"name" => tool, "arguments" => arguments}, agent, opts)

  defp invoke(name, message, timeout \\ 5_000) do
    with {:ok, pid} <- lookup(name), do: safe_call(pid, message, timeout)
  end

  defp lookup(name) do
    if Process.whereis(Vega.MCP.Registry) do
      case Registry.lookup(Vega.MCP.Registry, name) do
        [{pid, _}] -> {:ok, pid}
        [] -> {:error, :not_connected}
      end
    else
      {:error, :not_connected}
    end
  end

  defp safe_call(pid, msg, timeout) do
    GenServer.call(pid, msg, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:connection_exit, reason}}
  end

  @doc "Read a bounded byte page of a spilled JSON result; default 8 KiB, max 32 KiB."
  def page(path, opts \\ []) do
    offset = max(Keyword.get(opts, :offset, 0), 0)
    limit = Keyword.get(opts, :limit, 8192) |> max(1) |> min(32768)

    with {:ok, f} <- :file.open(String.to_charlist(path), [:read, :binary]) do
      result = :file.pread(f, offset, limit)
      :file.close(f)

      case result do
        {:ok, data} -> {:ok, %{data: data, next_offset: offset + byte_size(data)}}
        :eof -> {:ok, %{data: "", next_offset: nil}}
        error -> error
      end
    end
  end
end

defmodule Vega.MCP.Supervisor do
  @moduledoc "Add `{Vega.MCP.Supervisor, []}` to an application supervision tree; `Vega.MCP.start/0` is lazy fallback."
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_) do
    if stable = Process.whereis(:user), do: Process.group_leader(self(), stable)

    Supervisor.init(
      [
        {Registry, keys: :unique, name: Vega.MCP.Registry},
        Vega.MCP.Config,
        Vega.MCP.State,
        {Task.Supervisor, name: Vega.MCP.Requests},
        {DynamicSupervisor,
         strategy: :one_for_one, name: Vega.MCP.Connections, max_restarts: 100, max_seconds: 10}
      ],
      strategy: :one_for_one
    )
  end
end

defmodule Vega.MCP.State do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def directory, do: Application.get_env(:nano, :vega_mcp_state_dir, "/data/vega-mcp")

  def init(_) do
    File.mkdir_p!(directory())

    state =
      with {:ok, s} <- File.read(Path.join(directory(), "subscriptions.json")),
           {:ok, m} when is_map(m) <- Jason.decode(s),
           do: m

    {:ok, if(is_map(state), do: state, else: %{})}
  end

  def handle_cast(_, s), do: {:noreply, s}
  def handle_info(_, s), do: {:noreply, s}

  def format_status(status),
    do: Vega.MCP.Redact.status(status, %{servers: map_size(status.state)})

  def terminate(reason, _), do: Vega.MCP.Redact.terminate(reason, :state)
  def get(name), do: GenServer.call(__MODULE__, {:get, name})
  def put(name, state), do: GenServer.call(__MODULE__, {:put, name, state})

  def handle_call({:get, name}, _, s),
    do: {:reply, Map.get(s, name, %{"watchers" => [], "resources" => %{}}), s}

  def handle_call({:put, name, value}, _, s) do
    updated = Map.put(s, name, value)
    path = Path.join(directory(), "subscriptions.json")

    result =
      with :ok <- File.write(path <> ".tmp", Jason.encode!(updated)),
           do: File.rename(path <> ".tmp", path)

    {:reply, result, if(result == :ok, do: updated, else: s)}
  end
end

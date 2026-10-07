defmodule Nano.MCP do
  @moduledoc """
  MCP client (protocol 2025-11-25). See `docs/nova-mcp.md` for configuration.

      {:ok, server} = Nano.MCP.connect("files")
      Nano.MCP.tools(server)
      Nano.MCP.call_tool(server, "read_file", %{"path" => "/tmp/example"})
      Nano.MCP.subscribe(server, "file:///tmp/example", "my-agent")

  Events are `{:mcp, server_name, method, params}`. Stable agent names survive
  process restarts; PID subscribers do not. Results exceeding the byte budget
  are spilled to disk, never silently truncated. Connections are supervised.
  """
  @config "/app/config/mcp.json"
  def child_spec(opts), do: Nano.MCP.Supervisor.child_spec(opts)

  def start_link(opts \\ []), do: Nano.MCP.Supervisor.start_link(opts)

  def load_config(path \\ @config) do
    with {:ok, bytes} <- File.read(path), {:ok, config} <- Jason.decode(bytes) do
      case config do
        %{"mcpServers" => servers} when is_map(servers) -> {:ok, servers}
        _ -> {:error, :invalid_config}
      end
    end
  end

  def connect(name, opts \\ []) do
    with :ok <- ensure_started(),
         {:ok, config} <- config(name, opts) do
      spec = {Nano.MCP.Connection, {name, config, opts}}

      case DynamicSupervisor.start_child(Nano.MCP.Connections, spec) do
        {:ok, pid} -> ready(pid, Keyword.get(opts, :timeout, 15_000))
        {:error, {:already_started, pid}} -> ready(pid, Keyword.get(opts, :timeout, 15_000))
        error -> error
      end
    end
  end

  defp config(name, opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, config} when is_map(config) ->
        {:ok, config}

      :error ->
        with {:ok, servers} <- load_config(Keyword.get(opts, :config_path, @config)) do
          case Map.fetch(servers, name) do
            {:ok, config} -> {:ok, config}
            :error -> {:error, :unknown_server}
          end
        end
    end
  end

  defp ensure_started do
    case Process.whereis(Nano.MCP.Supervisor) do
      nil ->
        case Supervisor.start_child(Nano.Supervisor, {Nano.MCP.Supervisor, []}) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, :already_present} -> :ok
          error -> error
        end

      _ ->
        :ok
    end
  end

  def ready(server, timeout \\ 15_000), do: safe_call(server, :ready, timeout)
  def status(server), do: safe_call(server, :status, 5_000)

  def disconnect(server) do
    case GenServer.whereis(resolve(server)) do
      pid when is_pid(pid) -> DynamicSupervisor.terminate_child(Nano.MCP.Connections, pid)
      _ -> {:error, :not_found}
    end
  end

  def watch(server, recipient \\ self()), do: safe_call(server, {:watch, recipient}, 5_000)

  def request(server, method, params \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    meta = Keyword.get(opts, :meta, %{})

    meta =
      if opts[:progress_token],
        do: Map.put(meta, "progressToken", opts[:progress_token]),
        else: meta

    params = if map_size(meta) > 0, do: Map.put(params, "_meta", meta), else: params

    with {:ok, result} <- safe_call(server, {:request, method, params, timeout}, timeout + 1_000) do
      Nano.MCP.Result.bound(result, opts)
    end
  end

  def tools(server, opts \\ []), do: listing(server, "tools/list", opts)
  def resources(server, opts \\ []), do: listing(server, "resources/list", opts)

  def resource_templates(server, opts \\ []),
    do: listing(server, "resources/templates/list", opts)

  def prompts(server, opts \\ []), do: listing(server, "prompts/list", opts)

  defp listing(server, method, opts) do
    params = if opts[:cursor], do: %{"cursor" => opts[:cursor]}, else: %{}
    request(server, method, params, opts)
  end

  def call_tool(server, name, arguments \\ %{}, opts \\ []),
    do: request(server, "tools/call", %{"name" => name, "arguments" => arguments}, opts)

  def read_resource(server, uri, opts \\ []),
    do: request(server, "resources/read", %{"uri" => uri}, opts)

  def get_prompt(server, name, arguments \\ %{}, opts \\ []),
    do: request(server, "prompts/get", %{"name" => name, "arguments" => arguments}, opts)

  def subscribe(server, uri, recipient \\ self()),
    do: safe_call(server, {:subscribe, uri, recipient}, 31_000)

  def unsubscribe(server, uri, recipient \\ self()),
    do: safe_call(server, {:unsubscribe, uri, recipient}, 31_000)

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(name), do: {:via, Registry, {Nano.MCP.Registry, name}}

  defp safe_call(server, message, timeout) do
    GenServer.call(resolve(server), message, timeout)
  catch
    :exit, reason -> {:error, {:connection, reason}}
  end
end

defmodule Nano.MCP.Supervisor do
  @moduledoc false
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Nano.MCP.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Nano.MCP.Connections},
        {Nano.MCP.Bootstrap, opts}
      ],
      strategy: :one_for_all
    )
  end
end

defmodule Nano.MCP.Bootstrap do
  @moduledoc false
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl true
  def init(opts), do: {:ok, opts, {:continue, :load}}
  @impl true
  def handle_continue(:load, opts) do
    path = Keyword.get(opts, :config_path, "/app/config/mcp.json")

    case Nano.MCP.load_config(path) do
      {:ok, servers} ->
        Enum.each(servers, fn {name, config} ->
          DynamicSupervisor.start_child(
            Nano.MCP.Connections,
            {Nano.MCP.Connection, {name, config, opts}}
          )
        end)

      _ ->
        :ok
    end

    {:noreply, opts}
  end
end

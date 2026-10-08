defmodule Seedling.MCP.Supervisor do
  @moduledoc false
  use Supervisor

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case Supervisor.start_link(__MODULE__, [], name: __MODULE__) do
          {:ok, pid} ->
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

  def init(_) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Seedling.MCP.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Seedling.MCP.Connections},
        Seedling.MCP.Manager
      ],
      strategy: :rest_for_one
    )
  end
end

defmodule Seedling.MCP.Manager do
  @moduledoc false
  use GenServer
  alias Seedling.MCP.{Config, Connection}
  import Seedling.MCP, only: [error: 2]
  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    send(self(), :restore)
    {:ok, %{}}
  end

  def handle_info(:restore, s) do
    Path.wildcard("/data/seedling/mcp/*/intent.json")
    |> Enum.each(fn path ->
      with {:ok, raw} <- File.read(path),
           {:ok, intent} <- Jason.decode(raw),
           %{"name" => name, "config_path" => config_path} <- intent do
        start(name, config_path: config_path, state_dir: Path.dirname(Path.dirname(path)))
      end
    end)

    {:noreply, s}
  end

  def handle_call({:connect, name, opts}, _, s) when is_binary(name) do
    {:reply, start(name, opts), s}
  end

  def handle_call({:connect, _, _}, _, s),
    do: {:reply, error(:invalid_server, "Server name must be a string."), s}

  def handle_call({:lookup, key}, _, s), do: {:reply, lookup(key), s}

  def handle_call({:disconnect, %{key: key}}, _, s) do
    result =
      try do
        with {:ok, pid} <- lookup(key), :ok <- GenServer.call(pid, :forget) do
          DynamicSupervisor.terminate_child(Seedling.MCP.Connections, pid)
        end
      catch
        :exit, reason ->
          error(
            :disconnect_failed,
            "Connection died during disconnect: #{inspect(reason)}; retry disconnect/1."
          )
      end

    {:reply, result, s}
  end

  def handle_call({:disconnect, _}, _, s),
    do: {:reply, error(:invalid_connection, "Pass a connection handle."), s}

  defp lookup(key) do
    case Registry.lookup(Seedling.MCP.Registry, key) do
      [{pid, _}] -> {:ok, pid}
      [] -> error(:not_connected, "Connection absent; call connect/2.")
    end
  end

  defp start(name, opts) do
    path = Path.expand(Keyword.get(opts, :config_path, Config.default_path()))
    root = Path.expand(Keyword.get(opts, :state_dir, "/data/seedling/mcp"))

    key =
      :crypto.hash(:sha256, path <> "\0" <> name <> "\0" <> root) |> Base.encode16(case: :lower)

    case lookup(key) do
      {:ok, pid} ->
        {:ok, %{key: key, name: name, pid: pid}}

      _ ->
        with {:ok, config} <- Config.get(path, name),
             {:ok, pid} <-
               DynamicSupervisor.start_child(
                 Seedling.MCP.Connections,
                 {Connection,
                  %{
                    key: key,
                    name: name,
                    config_path: path,
                    config: config,
                    dir: Path.join(root, key),
                    resolver: Keyword.get(opts, :resolver, &NanoAgent.whereis/1)
                  }}
               ) do
          {:ok, %{key: key, name: name, pid: pid}}
        else
          {:error, {:already_started, pid}} -> {:ok, %{key: key, name: name, pid: pid}}
          {:error, %{}} = e -> e
          other -> error(:start_failed, "Could not start connection: #{inspect(other)}")
        end
    end
  end
end

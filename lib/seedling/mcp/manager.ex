defmodule Seedling.MCP.Manager do
  @moduledoc false
  use GenServer
  alias Seedling.MCP.{Config, Client, Result, Supervisor}
  def name(instance), do: {:global, {__MODULE__, instance}}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: name(opts[:instance] || :default))

  @impl true
  def init(opts) do
    dir =
      opts[:state_dir] || Path.join(Application.get_env(:nano, :state_dir, "/data/state"), "mcp")

    File.mkdir_p!(dir)
    file = Path.join(dir, "intent.json")

    intents =
      case File.read(file) do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, %{"connections" => intents}} when is_map(intents) -> intents
            _ -> raise "Invalid MCP intent file #{file}; refusing to overwrite"
          end

        {:error, :enoent} ->
          %{}

        {:error, reason} ->
          raise "Cannot read MCP intent file: #{inspect(reason)}"
      end

    s = %{
      instance: opts[:instance] || :default,
      config: opts[:config_path] || Config.path(),
      file: file,
      dir: dir,
      intents: intents,
      clients: %{},
      pending: %{},
      held: MapSet.new(),
      resolver: opts[:resolver] || (&resolve/1)
    }

    Process.send_after(self(), :flush, 250)
    {:ok, s, {:continue, :restore}}
  end

  @impl true
  def handle_continue(:restore, s) do
    s =
      Enum.reduce(Map.keys(s.intents), s, fn name, s ->
        case ensure_client(s, name) do
          {:ok, _, s} -> s
          {:error, reason} -> event(s, name, %{type: :disconnected, reason: inspect(reason)})
        end
      end)

    {:noreply, s}
  end

  @impl true
  def handle_call(:servers, _, s), do: {:reply, Config.load(s.config), s}

  def handle_call({:client, name}, _, s) do
    case s.clients[name] do
      pid when is_pid(pid) -> {:reply, {:ok, pid}, s}
      _ -> {:reply, {:error, :not_connected}, s}
    end
  end

  def handle_call({:connect, name, agent, defer}, _, s) do
    with {:ok, _} <- server_config(s, name) do
      intent = Map.get(s.intents, name, %{}) |> Map.put_new(agent, [])

      next = %{
        s
        | intents: Map.put(s.intents, name, intent),
          held: if(defer, do: MapSet.put(s.held, agent), else: s.held)
      }

      with :ok <- persist(next), {:ok, pid, next} <- ensure_client(next, name) do
        {:reply, {:ok, pid}, next}
      else
        error -> {:reply, error, s}
      end
    else
      error -> {:reply, error, s}
    end
  end

  def handle_call({:release_events, agent}, _, s) do
    next = %{s | held: MapSet.delete(s.held, agent)}
    {:reply, :ok, flush(next)}
  end

  def handle_call({:intent, name, agent, uri, add}, _, s) do
    case get_in(s.intents, [name, agent]) do
      nil ->
        {:reply, {:error, :connect_agent_first}, s}

      uris ->
        uris = if add, do: Enum.uniq([uri | uris]), else: List.delete(uris, uri)
        next = put_in(s.intents[name][agent], uris)

        case persist(next) do
          :ok ->
            if s.clients[name],
              do: GenServer.cast(s.clients[name], {:subscriptions, all_uris(next, name)})

            {:reply, {:ok, %{durable: true, status: :pending, uri: uri}}, next}

          error ->
            {:reply, error, s}
        end
    end
  end

  def handle_call({:disconnect, name, agent}, _, s) do
    if is_binary(agent) do
      intent = Map.get(s.intents, name, %{}) |> Map.delete(agent)

      intents =
        if map_size(intent) == 0,
          do: Map.delete(s.intents, name),
          else: Map.put(s.intents, name, intent)

      next = %{s | intents: intents}

      case persist(next) do
        :ok ->
          next =
            if map_size(intent) == 0 do
              if pid = s.clients[name],
                do: DynamicSupervisor.terminate_child(Supervisor.connections(s.instance), pid)

              %{next | clients: Map.delete(s.clients, name)}
            else
              if s.clients[name],
                do: GenServer.cast(s.clients[name], {:subscriptions, all_uris(next, name)})

              next
            end

          next =
            if Enum.any?(next.intents, fn {_, agents} -> Map.has_key?(agents, agent) end),
              do: next,
              else: %{
                next
                | held: MapSet.delete(next.held, agent),
                  pending: Map.delete(next.pending, agent)
              }

          {:reply, :ok, next}

        error ->
          {:reply, error, s}
      end
    else
      {:reply, {:error, :stable_agent_required}, s}
    end
  end

  @impl true
  def handle_info({:mcp_client, name, pid, payload}, s) do
    # Child announces its pid after every supervised restart.
    if payload[:type] == :connecting and Map.has_key?(s.intents, name),
      do: GenServer.cast(pid, {:subscriptions, all_uris(s, name)})

    s =
      if Map.has_key?(s.intents, name), do: %{s | clients: Map.put(s.clients, name, pid)}, else: s

    {:noreply, event(s, name, payload)}
  end

  def handle_info(:flush, s) do
    Process.send_after(self(), :flush, 250)
    {:noreply, flush(s)}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp event(s, name, payload) do
    original = payload

    payload =
      case Result.bound(payload, 4096, Path.join(s.dir, "events")) do
        {:ok, bounded} ->
          Map.merge(bounded, Map.take(original, [:type, :method]))
          |> Map.put(:uri, get_in(original, [:params, "uri"]))

        {:error, reason} ->
          %{type: :event_spill_failed, reason: inspect(reason)}
      end

    event = Map.merge(%{mcp: name, at: DateTime.utc_now() |> DateTime.to_iso8601()}, payload)

    Enum.reduce(Map.keys(s.intents[name] || %{}), s, fn agent, s ->
      # Resource updates only go to agents which requested that URI.
      uri = get_in(original, [:params, "uri"])

      eligible =
        original[:method] != "notifications/resources/updated" or uri in s.intents[name][agent]

      if eligible do
        case destination(s, agent) do
          pid when is_pid(pid) ->
            send(pid, event)
            s

          _ ->
            update_in(
              s.pending,
              &Map.update(&1, agent, [event], fn old -> Enum.take(old ++ [event], -100) end)
            )
        end
      else
        s
      end
    end)
  end

  defp flush(s) do
    pending =
      Enum.reduce(s.pending, %{}, fn {agent, events}, acc ->
        case destination(s, agent) do
          pid when is_pid(pid) ->
            Enum.each(events, &send(pid, &1))
            acc

          _ ->
            Map.put(acc, agent, events)
        end
      end)

    %{s | pending: pending}
  end

  defp destination(s, agent) do
    if MapSet.member?(s.held, agent), do: :undefined, else: s.resolver.(agent)
  end

  defp resolve(agent) do
    Nano.Names.whereis_name({:agent, agent})
  rescue
    ArgumentError -> :undefined
  end

  defp persist(s) do
    tmp = s.file <> ".tmp"

    with :ok <- File.write(tmp, Jason.encode!(%{connections: s.intents}), [:binary, :sync]),
         :ok <- File.rename(tmp, s.file),
         do: :ok
  end

  defp all_uris(s, name),
    do: (s.intents[name] || %{}) |> Map.values() |> List.flatten() |> Enum.uniq()

  defp server_config(s, name) do
    with {:ok, servers} <- Config.load(s.config),
         config when is_map(config) <- servers[name],
         {:ok, config} <- Config.resolve(config) do
      {:ok, config}
    else
      nil -> {:error, {:unknown_server, name}}
      error -> error
    end
  end

  defp ensure_client(s, name) do
    case s.clients[name] do
      pid when is_pid(pid) ->
        {:ok, pid, s}

      _ ->
        with {:ok, config} <- server_config(s, name),
             {:ok, pid} <-
               DynamicSupervisor.start_child(
                 Supervisor.connections(s.instance),
                 {Client, %{manager: self(), name: name, config: config, uris: all_uris(s, name)}}
               ) do
          {:ok, pid, %{s | clients: Map.put(s.clients, name, pid)}}
        end
    end
  end
end

defmodule Nano.MCP.Manager do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def connect(agent, server), do: GenServer.call(__MODULE__, {:connect, agent, server})
  def disconnect(agent, server), do: GenServer.call(__MODULE__, {:disconnect, agent, server})
  def session(agent, server), do: GenServer.call(__MODULE__, {:session, agent, server})
  def uris(agent, server), do: GenServer.call(__MODULE__, {:uris, agent, server})

  def save_uris(agent, server, uris),
    do: GenServer.call(__MODULE__, {:save_uris, agent, server, uris})

  def event(agent, server, method, params),
    do: GenServer.cast(__MODULE__, {:event, agent, server, method, params})

  def change_subscription(a, b, uri, action, timeout),
    do:
      GenServer.call(
        __MODULE__,
        {:change_subscription, a, b, uri, action, timeout},
        timeout + 1000
      )

  def list, do: GenServer.call(__MODULE__, :list)
  defp path, do: Path.join(Application.fetch_env!(:nano, :state_dir), "mcp.json")
  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :redacted) |> Map.put(:message, :redacted)

  @impl true
  def init(_) do
    persisted =
      with {:ok, bytes} <- File.read(path()), {:ok, value} <- Jason.decode(bytes), do: value

    rows =
      case persisted do
        %{"connections" => rows} when is_list(rows) -> rows
        _ -> []
      end

    queues =
      case persisted do
        %{"queues" => q} when is_map(q) -> restore_queues(q)
        _ -> %{}
      end

    desired =
      Enum.reduce(rows, %{}, fn
        %{"agent" => a, "server" => b, "uris" => uris}, acc
        when is_binary(a) and is_binary(b) and is_list(uris) ->
          Map.put(acc, {a, b}, uris)

        _, acc ->
          acc
      end)

    send(self(), :restore)
    Process.send_after(self(), :flush, 1000)
    {:ok, %{desired: desired, sessions: %{}, refs: %{}, queues: queues, mutations: %{}}}
  end

  @impl true
  def handle_call(:list, _, s) do
    rows =
      Enum.map(s.desired, fn {{agent, server}, uris} ->
        %{
          agent: agent,
          server: server,
          subscriptions: uris,
          running: Map.has_key?(s.sessions, {agent, server})
        }
      end)

    {:reply, {:ok, Nano.MCP.Page.bound(rows)}, s}
  end

  def handle_call({:connect, a, b}, _, s) do
    key = {a, b}

    case Map.get(s.sessions, key) do
      pid when is_pid(pid) ->
        {:reply, {:ok, pid, false}, s}

      nil ->
        with :ok <- valid_agent(a),
             {:ok, _} <- Nano.MCP.Config.fetch(b),
             {:ok, pid} <- start(key, Map.get(s.desired, key, [])) do
          s = attach(s, key, pid)
          s = %{s | desired: Map.put_new(s.desired, key, [])}

          case persist(s) do
            :ok ->
              {:reply, {:ok, pid, true}, s}

            _ ->
              DynamicSupervisor.terminate_child(Nano.MCP.SessionSupervisor, pid)
              {:reply, {:error, :state_write_failed}, remove(s, key)}
          end
        else
          error -> {:reply, error, s}
        end
    end
  end

  def handle_call({:disconnect, a, b}, _, s) do
    key = {a, b}
    old = s
    candidate = %{s | desired: Map.delete(s.desired, key), sessions: Map.delete(s.sessions, key)}

    case persist(candidate) do
      :ok ->
        s = remove(s, key)

        if old.sessions[key],
          do: DynamicSupervisor.terminate_child(Nano.MCP.SessionSupervisor, old.sessions[key])

        {:reply, :ok, s}

      _ ->
        {:reply, {:error, :state_write_failed}, old}
    end
  end

  def handle_call({:session, a, b}, _, s) do
    result =
      case s.sessions[{a, b}] do
        nil -> {:error, :not_connected}
        pid -> {:ok, pid}
      end

    {:reply, result, s}
  end

  def handle_call({:uris, a, b}, _, s) do
    result =
      case Map.fetch(s.desired, {a, b}) do
        {:ok, uris} -> {:ok, uris}
        :error -> {:error, :not_connected}
      end

    {:reply, result, s}
  end

  def handle_call({:change_subscription, a, b, uri, action, timeout}, from, s) do
    key = {a, b}

    cond do
      not Map.has_key?(s.sessions, key) ->
        {:reply, {:error, :not_connected}, s}

      Enum.any?(s.mutations, fn {_, m} -> m.key == key end) ->
        {:reply, {:error, :subscription_busy}, s}

      true ->
        old = s.desired[key]

        uris =
          case action do
            :add -> Enum.uniq(old ++ [uri])
            :remove -> List.delete(old, uri)
            :replace -> uri
          end

        if length(uris) > 256 do
          {:reply, {:error, :too_many_subscriptions}, s}
        else
          pid = s.sessions[key]

          task =
            Task.Supervisor.async_nolink(Nano.EvalSupervisor, fn ->
              try do
                Nano.MCP.Connection.subscriptions(pid, uris, timeout)
              catch
                :exit, _ -> {:error, :connection_unavailable}
              end
            end)

          m = %{key: key, uris: uris, old: old, from: from, pid: pid, worker: task.pid}
          {:noreply, %{s | mutations: Map.put(s.mutations, task.ref, m)}}
        end
    end
  end

  def handle_call({:save_uris, a, b, uris}, _, s) do
    if Map.has_key?(s.desired, {a, b}) do
      next = %{s | desired: Map.put(s.desired, {a, b}, uris)}

      case persist(next) do
        :ok -> {:reply, :ok, next}
        _ -> {:reply, {:error, :state_write_failed}, s}
      end
    else
      {:reply, {:error, :not_connected}, s}
    end
  end

  @impl true
  def handle_cast({:event, agent, server, method, params}, s) do
    payload = %{mcp: method, server: server, payload: Nano.MCP.Page.bound(params)}

    if present?(agent) do
      NanoAgent.notify(agent, payload)
      {:noreply, s}
    else
      # At most 64 bounded messages per absent name; report any dropped messages
      # when it returns. Events are not a transactional exactly-once event bus.
      queue = Map.get(s.queues, agent, %{"events" => [], "dropped" => 0})
      events = queue["events"] ++ [payload]
      excess = max(length(events) - 64, 0)
      queue = %{"events" => Enum.drop(events, excess), "dropped" => queue["dropped"] + excess}
      s = %{s | queues: Map.put(s.queues, agent, queue)}
      persist(s)
      {:noreply, s}
    end
  end

  @impl true
  def handle_info(:restore, s) do
    s =
      Enum.reduce(s.desired, s, fn {key, uris}, acc ->
        case start(key, uris) do
          {:ok, pid} ->
            attach(acc, key, pid)

          _ ->
            Process.send_after(self(), {:restart, key}, 1000)
            acc
        end
      end)

    {:noreply, s}
  end

  def handle_info({ref, result}, s) when is_reference(ref) do
    case Map.pop(s.mutations, ref) do
      {nil, _} ->
        {:noreply, s}

      {m, mutations} ->
        Process.demonitor(ref, [:flush])
        s = %{s | mutations: mutations}

        if result == :ok and s.sessions[m.key] == m.pid and Map.has_key?(s.desired, m.key) do
          next = %{s | desired: Map.put(s.desired, m.key, m.uris)}

          case persist(next) do
            :ok ->
              GenServer.reply(m.from, :ok)
              {:noreply, next}

            _ ->
              # Reconnect from last durable intent, rather than claim an ephemeral subscription.
              if s.sessions[m.key], do: Process.exit(s.sessions[m.key], :kill)
              GenServer.reply(m.from, {:error, :state_write_failed})
              {:noreply, s}
          end
        else
          GenServer.reply(m.from, if(result == :ok, do: {:error, :not_connected}, else: result))
          {:noreply, s}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{mutations: mutations} = s)
      when is_map_key(mutations, ref) do
    {m, rest} = Map.pop(mutations, ref)
    GenServer.reply(m.from, {:error, :subscription_worker_failed})
    {:noreply, %{s | mutations: rest}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Map.pop(s.refs, ref) do
      {nil, _} ->
        {:noreply, s}

      {key, refs} ->
        s = %{s | refs: refs, sessions: Map.delete(s.sessions, key)}
        if Map.has_key?(s.desired, key), do: Process.send_after(self(), {:restart, key}, 500)
        {:noreply, s}
    end
  end

  def handle_info({:restart, key}, s) do
    if Map.has_key?(s.desired, key) and not Map.has_key?(s.sessions, key) do
      case start(key, s.desired[key]) do
        {:ok, pid} ->
          {:noreply, attach(s, key, pid)}

        _ ->
          Process.send_after(self(), {:restart, key}, 1000)
          {:noreply, s}
      end
    else
      {:noreply, s}
    end
  end

  def handle_info(:flush, s) do
    queues =
      Enum.reduce(s.queues, %{}, fn {agent, queue}, acc ->
        if present?(agent) do
          if queue["dropped"] > 0,
            do: NanoAgent.notify(agent, %{mcp: "events_dropped", count: queue["dropped"]})

          Enum.each(queue["events"], &NanoAgent.notify(agent, &1))
          acc
        else
          Map.put(acc, agent, queue)
        end
      end)

    next = %{s | queues: queues}
    if queues != s.queues, do: persist(next)
    Process.send_after(self(), :flush, 1000)
    {:noreply, next}
  end

  def handle_info(_, s), do: {:noreply, s}

  @bound_keys [
    :data,
    :cut,
    :text,
    :id,
    :bytes,
    :raw_path,
    :display_wrapped,
    :next_offset,
    :continuation,
    :error
  ]
  defp restore_queues(queues) do
    Map.new(queues, fn {agent, queue} ->
      events =
        case queue do
          %{"events" => events} when is_list(events) -> events
          _ -> []
        end

      events =
        Enum.flat_map(events, fn
          %{"mcp" => method, "server" => server, "payload" => payload} when is_map(payload) ->
            bound =
              Map.new(
                for key <- @bound_keys,
                    Map.has_key?(payload, Atom.to_string(key)),
                    do: {key, payload[Atom.to_string(key)]}
              )

            [%{mcp: method, server: server, payload: bound}]

          _ ->
            []
        end)
        |> Enum.take(-64)

      dropped =
        case queue do
          %{"dropped" => n} when is_integer(n) and n >= 0 -> n
          _ -> 0
        end

      {agent, %{"events" => events, "dropped" => dropped}}
    end)
  end

  defp valid_agent(a)
       when is_binary(a) do
    if Regex.match?(~r/\A[a-zA-Z0-9_.-]{1,128}\z/, a),
      do: :ok,
      else: {:error, :invalid_agent_name}
  end

  defp valid_agent(_), do: {:error, :stable_agent_name_required}
  defp present?(a), do: Nano.Names.whereis_name({:agent, a}) != :undefined

  defp start({a, b}, uris),
    do:
      DynamicSupervisor.start_child(
        Nano.MCP.SessionSupervisor,
        {Nano.MCP.Connection, [agent: a, server: b, uris: uris]}
      )

  defp attach(s, key, pid),
    do: %{
      s
      | sessions: Map.put(s.sessions, key, pid),
        refs: Map.put(s.refs, Process.monitor(pid), key)
    }

  defp remove(s, key) do
    refs =
      Enum.reduce(s.refs, s.refs, fn {ref, k}, acc ->
        if k == key,
          do:
            (
              Process.demonitor(ref, [:flush])
              Map.delete(acc, ref)
            ),
          else: acc
      end)

    mutations =
      Enum.reduce(s.mutations, s.mutations, fn {ref, m}, acc ->
        if m.key == key do
          Process.demonitor(ref, [:flush])
          Process.exit(m.worker, :kill)
          GenServer.reply(m.from, {:error, :connection_lost})
          Map.delete(acc, ref)
        else
          acc
        end
      end)

    %{
      s
      | desired: Map.delete(s.desired, key),
        sessions: Map.delete(s.sessions, key),
        refs: refs,
        mutations: mutations
    }
  end

  defp persist(s) do
    rows =
      Enum.map(s.desired, fn {{a, b}, uris} -> %{"agent" => a, "server" => b, "uris" => uris} end)

    bytes = Jason.encode!(%{"connections" => rows, "queues" => s.queues})
    File.mkdir_p(Path.dirname(path()))
    tmp = path() <> ".tmp"
    with :ok <- File.write(tmp, bytes), :ok <- File.rename(tmp, path()), do: :ok
  end
end

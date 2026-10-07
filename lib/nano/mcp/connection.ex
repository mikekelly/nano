defmodule Nano.MCP.Connection do
  @moduledoc false
  use GenServer
  alias Nano.MCP.Transport
  @version "2025-11-25"
  @versions [@version, "2025-06-18", "2025-03-26", "2024-11-05"]

  def start_link({name, _, _} = args),
    do: GenServer.start_link(__MODULE__, args, name: {:via, Registry, {Nano.MCP.Registry, name}})

  @impl true
  def init({name, config, opts}) do
    Process.flag(:trap_exit, true)
    dir = Keyword.get(opts, :state_dir, "/data/mcp")

    path =
      Path.join(dir, Base.url_encode64(:crypto.hash(:sha256, name), padding: false) <> ".json")

    subscriptions =
      case File.read(path) do
        {:ok, bytes} ->
          case Jason.decode(bytes) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    state = %{
      name: name,
      config: config,
      path: path,
      subscriptions: subscriptions,
      subscription_queue: %{},
      watchers: [],
      transport: nil,
      ready: false,
      waiters: [],
      pending: %{},
      next_id: 0,
      buffer: "",
      streams: %{},
      session: nil,
      version: @version,
      capabilities: %{},
      server_info: nil,
      generation: 0,
      attempts: 0,
      listener: nil
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:ready, from, state), do: handle_call({:ready, :caller}, from, state)

  def handle_call({:ready, recipient}, from, %{ready: true} = state) do
    {:reply, {:ok, self()}, add_watcher(state, recipient, from)}
  end

  def handle_call({:ready, recipient}, from, state) do
    {:noreply, %{add_watcher(state, recipient, from) | waiters: [from | state.waiters]}}
  end

  def handle_call(:status, _from, state),
    do:
      {:reply, {:ok, Map.take(state, [:ready, :name, :version, :capabilities, :server_info])},
       state}

  def handle_call({:watch, target}, _from, state) when is_pid(target) or is_binary(target),
    do: {:reply, :ok, %{state | watchers: Enum.uniq([canonical_target(target) | state.watchers])}}

  def handle_call({:request, method, params, timeout}, from, %{ready: true} = state) do
    emit(state, "client/request", %{"method" => method}, [canonical_target(elem(from, 0))])
    {:noreply, rpc(state, method, params, {:call, from}, timeout)}
  end

  def handle_call({:request, _, _, _}, _from, state), do: {:reply, {:error, :not_ready}, state}

  def handle_call({operation, uri, target}, from, state)
      when operation in [:subscribe, :unsubscribe] do
    if subscription_active?(state, uri) or Map.get(state.subscription_queue, uri, []) != [] do
      queue =
        Map.update(
          state.subscription_queue,
          uri,
          [{operation, target, from}],
          &(&1 ++ [{operation, target, from}])
        )

      {:noreply, %{state | subscription_queue: queue}}
    else
      subscription_call({operation, uri, target}, from, state)
    end
  end

  defp subscription_call({operation, uri, target}, from, state) do
    target = canonical_target(target)

    cond do
      not state.ready ->
        {:reply, {:error, :not_ready}, state}

      not (is_binary(target) or is_pid(target)) ->
        {:reply, {:error, :invalid_recipient}, state}

      get_in(state.capabilities, ["resources", "subscribe"]) != true ->
        {:reply, {:error, :unsupported_subscription}, state}

      true ->
        recipients = Map.get(state.subscriptions, uri, [])

        if operation == :unsubscribe and length(recipients -- [target]) > 0 do
          next = %{
            state
            | subscriptions: Map.put(state.subscriptions, uri, recipients -- [target])
          }

          case persist(next) do
            :ok -> {:reply, :ok, next}
            error -> {:reply, error, state}
          end
        else
          method =
            if operation == :subscribe, do: "resources/subscribe", else: "resources/unsubscribe"

          {:noreply, rpc(state, method, %{"uri" => uri}, {operation, from, uri, target}, 30_000)}
        end
    end
  end

  @impl true
  def handle_info({:subscription_next, uri}, state) do
    if subscription_active?(state, uri) do
      {:noreply, state}
    else
      case Map.get(state.subscription_queue, uri, []) do
        [] ->
          {:noreply, state}

        [{operation, target, from} | rest] ->
          state = %{state | subscription_queue: Map.put(state.subscription_queue, uri, rest)}

          case subscription_call({operation, uri, target}, from, state) do
            {:reply, result, next} ->
              GenServer.reply(from, result)
              send(self(), {:subscription_next, uri})
              {:noreply, next}

            {:noreply, next} ->
              {:noreply, next}
          end
      end
    end
  end

  def handle_info(:connect, state) do
    state = %{
      state
      | generation: state.generation + 1,
        buffer: "",
        streams: %{},
        session: nil,
        listener: nil
    }

    case Transport.open(state.config, self(), state.generation) do
      {:ok, transport} ->
        state = %{state | transport: transport}

        params = %{
          "protocolVersion" => @version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "nano", "version" => "0.1.0"}
        }

        {:noreply, rpc(state, "initialize", params, :initialize, 15_000)}

      {:error, reason} ->
        {:noreply, failed(state, reason)}
    end
  end

  def handle_info({port, {:data, data}}, %{transport: {:stdio, port}} = state) do
    buffer = state.buffer <> data

    if byte_size(buffer) > 16_777_216 do
      {:noreply, failed(state, :frame_too_large)}
    else
      lines = String.split(buffer, "\n")
      {complete, [rest]} = Enum.split(lines, -1)

      state =
        Enum.reduce(complete, %{state | buffer: rest}, fn line, acc ->
          case Jason.decode(line) do
            {:ok, message} when is_map(message) ->
              incoming(acc, message)

            _ ->
              emit(acc, "client/protocol_error", %{"reason" => "invalid JSON on stdout"})
              acc
          end
        end)

      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{transport: {:stdio, port}} = state),
    do: {:noreply, failed(state, {:exit_status, status})}

  def handle_info({:EXIT, port, reason}, %{transport: {:stdio, port}} = state),
    do: {:noreply, failed(state, reason)}

  def handle_info({:timeout, id, generation}, %{generation: generation} = state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {%{kind: :initialize}, pending} ->
        {:noreply, failed(%{state | pending: pending}, :initialize_timeout)}

      {entry, pending} ->
        reply(entry.kind, {:error, :timeout})
        advance_subscription(entry.kind)
        notify(state, "notifications/cancelled", %{"requestId" => id, "reason" => "timeout"})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(
        {:http_chunk, gen, worker, method, id, status, headers, data},
        %{generation: gen} = state
      ) do
    session = List.first(Map.get(headers, "mcp-session-id", [])) || state.session
    state = %{state | session: session}

    if status in 200..299 do
      type = List.first(Map.get(headers, "content-type", [])) || ""
      buffer = Map.get(state.streams, worker, "") <> data

      cond do
        byte_size(buffer) > 16_777_216 ->
          {:noreply, failed(state, :frame_too_large)}

        String.starts_with?(type, "text/event-stream") ->
          {messages, rest} = Transport.sse(buffer)
          state = %{state | streams: Map.put(state.streams, worker, rest)}
          {:noreply, Enum.reduce(messages, state, &incoming(&2, &1))}

        true ->
          {:noreply, %{state | streams: Map.put(state.streams, worker, buffer)}}
      end
    else
      _ = {method, id}
      {:noreply, state}
    end
  end

  def handle_info({:http_done, gen, worker, method, id, result}, %{generation: gen} = state) do
    {buffer, streams} = Map.pop(state.streams, worker, "")
    state = %{state | streams: streams}

    state =
      case Jason.decode(buffer) do
        {:ok, message} when is_map(message) -> incoming(state, message)
        _ -> state
      end

    case result do
      {:ok, %{status: status, headers: headers}} when status in 200..299 ->
        session = List.first(Map.get(headers, "mcp-session-id", [])) || state.session
        state = %{state | session: session}
        if method == :get and state.ready, do: Process.send_after(self(), {:listen, gen}, 500)
        {:noreply, state}

      {:ok, %{status: status}} when method == :get and status in [405, 404] ->
        if status == 404 and state.session,
          do: {:noreply, failed(state, :session_expired)},
          else: {:noreply, state}

      {:ok, %{status: 404}} ->
        {:noreply, failed(state, :session_expired)}

      {:ok, %{status: status}} when method == :get ->
        emit(state, "client/event_stream_error", %{"status" => status})
        Process.send_after(self(), {:listen, gen}, 1_000)
        {:noreply, state}

      {:ok, %{status: status}} ->
        {:noreply, fail_request(state, id, {:http_status, status})}

      {:error, _reason} when method == :get ->
        emit(state, "client/event_stream_error", %{"reason" => "transport error"})
        Process.send_after(self(), {:listen, gen}, 1_000)
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, failed(state, :http_transport_error)}
    end
  end

  def handle_info({:listen, gen}, %{generation: gen, ready: true, transport: :http} = state) do
    listener = Transport.listen(state.config, state.session, state.version, self(), gen)
    {:noreply, %{state | listener: listener}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp rpc(state, method, params, kind, timeout) do
    id = state.next_id + 1
    timer = Process.send_after(self(), {:timeout, id, state.generation}, timeout)

    state = %{
      state
      | next_id: id,
        pending: Map.put(state.pending, id, %{kind: kind, timer: timer, method: method})
    }

    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    case Transport.post(
           state.transport,
           message,
           state.config,
           state.session,
           state.version,
           self(),
           state.generation
         ) do
      :ok -> state
      {:error, reason} -> failed(state, reason)
    end
  end

  defp notify(state, method, params) do
    Transport.post(
      state.transport,
      %{"jsonrpc" => "2.0", "method" => method, "params" => params},
      state.config,
      state.session,
      state.version,
      self(),
      state.generation
    )
  end

  defp incoming(state, %{"id" => id, "method" => "ping"}) do
    Transport.post(
      state.transport,
      %{"jsonrpc" => "2.0", "id" => id, "result" => %{}},
      state.config,
      state.session,
      state.version,
      self(),
      state.generation
    )

    state
  end

  defp incoming(state, %{"id" => id, "method" => method}) do
    # No roots/sampling/elicitation capability advertised: explicitly reject requests.
    Transport.post(
      state.transport,
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32601, "message" => "Client method not supported: " <> method}
      },
      state.config,
      state.session,
      state.version,
      self(),
      state.generation
    )

    state
  end

  defp incoming(state, %{"id" => id} = message) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {entry, pending} ->
        Process.cancel_timer(entry.timer)
        state = %{state | pending: pending}

        result =
          if Map.has_key?(message, "error") do
            case Nano.MCP.Result.bound(message["error"]) do
              {:ok, error} -> {:error, {:rpc, error}}
              {:error, reason} -> {:error, {:rpc_error_spill_failed, reason}}
            end
          else
            {:ok, message["result"]}
          end

        state = completed(state, entry.kind, result)
        advance_subscription(entry.kind)
        state
    end
  end

  defp incoming(state, %{"method" => method} = message) do
    params = Map.get(message, "params", %{})

    recipients =
      if method == "notifications/resources/updated",
        do: Map.get(state.subscriptions, params["uri"], []),
        else: []

    emit(state, method, params, recipients)
    state
  end

  defp incoming(state, _), do: state

  defp completed(state, :initialize, {:ok, %{"protocolVersion" => version} = result})
       when version in @versions do
    state = %{
      state
      | version: version,
        capabilities: Map.get(result, "capabilities", %{}),
        server_info: result["serverInfo"],
        ready: true,
        attempts: 0
    }

    notify(state, "notifications/initialized", %{})
    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, self()}))
    emit(state, "client/connected", %{"protocolVersion" => version})
    if state.transport == :http, do: send(self(), {:listen, state.generation})
    state = %{state | waiters: []}

    Enum.reduce(state.subscriptions, state, fn {uri, _}, acc ->
      rpc(acc, "resources/subscribe", %{"uri" => uri}, {:restore, uri}, 30_000)
    end)
  end

  defp completed(state, :initialize, error), do: failed(state, {:initialize, error})

  defp completed(state, {:call, from}, result) do
    GenServer.reply(from, result)

    emit(state, "client/result", %{"ok" => match?({:ok, _}, result)}, [
      canonical_target(elem(from, 0))
    ])

    state
  end

  defp completed(state, {operation, from, uri, target}, {:ok, _})
       when operation in [:subscribe, :unsubscribe] do
    recipients = Map.get(state.subscriptions, uri, [])

    subscriptions =
      if operation == :subscribe,
        do: Map.put(state.subscriptions, uri, Enum.uniq([target | recipients])),
        else:
          if(recipients -- [target] == [],
            do: Map.delete(state.subscriptions, uri),
            else: Map.put(state.subscriptions, uri, recipients -- [target])
          )

    next = %{state | subscriptions: subscriptions}

    case persist(next) do
      :ok ->
        GenServer.reply(from, :ok)
        next

      error ->
        GenServer.reply(from, error)
        state
    end
  end

  defp completed(state, {:restore, uri}, {:error, reason}) do
    emit(
      state,
      "client/subscription_error",
      %{"uri" => uri, "reason" => inspect(reason)},
      Map.get(state.subscriptions, uri, [])
    )

    state
  end

  defp completed(state, {:restore, _}, _), do: state

  defp completed(state, kind, error),
    do:
      (
        reply(kind, error)
        state
      )

  defp reply({:call, from}, result), do: GenServer.reply(from, result)

  defp reply({operation, from, _, _}, result) when operation in [:subscribe, :unsubscribe],
    do: GenServer.reply(from, result)

  defp reply(_, _), do: :ok

  defp fail_request(state, id, reason) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {%{kind: :initialize}, _} ->
        failed(state, reason)

      {entry, pending} ->
        Process.cancel_timer(entry.timer)
        state = completed(%{state | pending: pending}, entry.kind, {:error, reason})
        advance_subscription(entry.kind)
        state
    end
  end

  defp failed(state, reason) do
    Transport.close(state.transport)
    if is_pid(state.listener), do: Process.exit(state.listener, :kill)

    Enum.each(state.pending, fn {_, entry} ->
      Process.cancel_timer(entry.timer)
      reply(entry.kind, {:error, {:disconnected, reason}})
    end)

    Enum.each(state.waiters, &GenServer.reply(&1, {:error, {:disconnected, reason}}))

    Enum.each(state.subscription_queue, fn {_, entries} ->
      Enum.each(entries, fn {_, _, from} ->
        GenServer.reply(from, {:error, {:disconnected, reason}})
      end)
    end)

    emit(
      state,
      "client/disconnected",
      %{"reason" => inspect(reason)},
      Enum.flat_map(state.subscriptions, &elem(&1, 1))
    )

    delay = min(30_000, 250 * Integer.pow(2, min(state.attempts, 7)))
    Process.send_after(self(), :connect, delay)

    %{
      state
      | ready: false,
        transport: nil,
        pending: %{},
        subscription_queue: %{},
        waiters: [],
        attempts: state.attempts + 1,
        generation: state.generation + 1
    }
  end

  defp emit(state, method, params, extra \\ []) do
    Enum.uniq(state.watchers ++ extra)
    |> Enum.each(fn target ->
      pid = if is_pid(target), do: target, else: NanoAgent.whereis(target)

      if is_pid(pid) do
        bounded =
          case Nano.MCP.Result.bound(params) do
            {:ok, result} -> result
            {:error, reason} -> %{error: :event_spill_failed, reason: inspect(reason)}
          end

        send(pid, {:mcp, state.name, method, bounded})
      end
    end)
  end

  defp subscription_active?(state, uri) do
    Enum.any?(state.pending, fn {_, entry} ->
      case entry.kind do
        {operation, _, ^uri, _} when operation in [:subscribe, :unsubscribe] -> true
        {:restore, ^uri} -> true
        _ -> false
      end
    end)
  end

  defp advance_subscription({operation, _, uri, _}) when operation in [:subscribe, :unsubscribe],
    do: send(self(), {:subscription_next, uri})

  defp advance_subscription({:restore, uri}), do: send(self(), {:subscription_next, uri})
  defp advance_subscription(_), do: :ok

  defp add_watcher(state, false, _from), do: state
  defp add_watcher(state, :caller, from), do: add_watcher(state, elem(from, 0), from)

  defp add_watcher(state, recipient, _from) do
    %{state | watchers: Enum.uniq([canonical_target(recipient) | state.watchers])}
  end

  defp canonical_target(pid) when is_pid(pid) do
    # Harness eval runs in a Task; $callers contains its owning agent.
    callers =
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> Keyword.get(dictionary, :"$callers", [])
        _ -> []
      end

    Enum.find_value([pid | callers], pid, fn candidate ->
      case Enum.find(Registry.keys(Nano.Registry, candidate), &match?({:agent, _}, &1)) do
        {:agent, name} -> name
        _ -> nil
      end
    end)
  end

  defp canonical_target(name), do: name

  defp persist(state) do
    subscriptions =
      Map.new(state.subscriptions, fn {uri, targets} ->
        {uri, Enum.filter(targets, &is_binary/1)}
      end)
      |> Map.reject(fn {_, targets} -> targets == [] end)

    temp = state.path <> "." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(state.path)),
         :ok <- File.write(temp, Jason.encode!(subscriptions), [:exclusive]),
         :ok <- File.chmod(temp, 0o600),
         :ok <- File.rename(temp, state.path),
         do: :ok
  end

  @impl true
  def terminate(_, state) do
    Transport.close(state.transport)
    if is_pid(state.listener), do: Process.exit(state.listener, :kill)
    :ok
  end
end

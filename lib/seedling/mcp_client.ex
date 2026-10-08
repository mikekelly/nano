defmodule Seedling.MCP.Client do
  use GenServer

  @moduledoc "Standalone stdio MCP connection. Options: server, server_name, state_dir, resolver, reconnect_ms."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def init(opts) do
    name = Keyword.fetch!(opts, :server_name)
    dir = Keyword.get(opts, :state_dir, "/data/mcp")
    file = Path.join(dir, Base.url_encode64(name, padding: false) <> ".json")
    subs = with {:ok, text} <- File.read(file), {:ok, map} <- Jason.decode(text), do: map

    s = %{
      server: Keyword.fetch!(opts, :server),
      name: name,
      file: file,
      subs: if(is_map(subs), do: subs, else: %{}),
      watchers: [],
      resolver: Keyword.get(opts, :resolver, &NanoAgent.whereis/1),
      port: nil,
      buffer: "",
      next: 1,
      pending: %{},
      ready: false,
      info: nil,
      delay: Keyword.get(opts, :reconnect_ms, 1000)
    }

    send(self(), :connect)
    {:ok, s}
  end

  def handle_call(:status, _, s), do: {:reply, Map.take(s, [:ready, :info, :name]), s}

  def handle_call({:watch, agent}, _, s),
    do: {:reply, :ok, %{s | watchers: Enum.uniq([agent | s.watchers])}}

  def handle_call({:request, method, params, timeout}, from, s) do
    if s.ready,
      do: {:noreply, rpc(s, method, params, from, timeout)},
      else: {:reply, {:error, :disconnected}, s}
  end

  def handle_call({:subscription, action, uri, agent}, from, s) when is_binary(agent) do
    if s.ready do
      method = if action == :add, do: "resources/subscribe", else: "resources/unsubscribe"
      # Only unsubscribe upstream when the last local listener leaves.
      others = Map.get(s.subs, uri, []) -- [agent]

      if action == :remove and others != [] do
        s = save(%{s | subs: Map.put(s.subs, uri, others)})
        {:reply, :ok, s}
      else
        {:noreply,
         rpc(s, method, %{"uri" => uri}, {:subscription, from, action, uri, agent}, 30_000)}
      end
    else
      {:reply, {:error, :disconnected}, s}
    end
  end

  def handle_info(:connect, %{server: %{"url" => _}} = s) do
    {:ok, transport} = Seedling.MCP.HTTP.start(self(), s.server)
    Process.monitor(transport)
    s = %{s | port: transport, buffer: ""}

    {:noreply,
     rpc(
       s,
       "initialize",
       %{
         "protocolVersion" => "2025-11-25",
         "capabilities" => %{},
         "clientInfo" => %{"name" => "seedling", "version" => "0.1.0"}
       },
       :initialize,
       30_000
     )}
  end

  def handle_info(:connect, s) do
    try do
      executable = System.find_executable(s.server["command"]) || raise "command not found"

      env =
        Enum.map(s.server["env"] || %{}, fn {k, v} ->
          {String.to_charlist(k), String.to_charlist(v)}
        end)

      opts = [:binary, :exit_status, :use_stdio, {:args, s.server["args"] || []}, {:env, env}]
      opts = if s.server["cwd"], do: [{:cd, s.server["cwd"]} | opts], else: opts
      port = Port.open({:spawn_executable, executable}, opts)
      s = %{s | port: port, buffer: ""}

      {:noreply,
       rpc(
         s,
         "initialize",
         %{
           "protocolVersion" => "2025-11-25",
           "capabilities" => %{},
           "clientInfo" => %{"name" => "seedling", "version" => "0.1.0"}
         },
         :initialize,
         30_000
       )}
    rescue
      e -> {:noreply, down(s, Exception.message(e))}
    end
  end

  def handle_info({port, {:data, bytes}}, %{port: port} = s) do
    parts = String.split(s.buffer <> bytes, "\n")
    {lines, [rest]} = Enum.split(parts, -1)

    s =
      Enum.reduce(lines, %{s | buffer: rest}, fn line, acc ->
        case Jason.decode(line) do
          {:ok, msg} ->
            message(acc, msg)

          _ ->
            emit(acc, "invalid_json", %{"sample" => String.slice(line, 0, 200)})
            acc
        end
      end)

    if byte_size(s.buffer) > 16_000_000,
      do: {:noreply, down(s, :frame_too_large)},
      else: {:noreply, s}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = s),
    do: {:noreply, down(s, {:exit, status})}

  def handle_info({:timeout, id}, s) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        {:noreply, s}

      {{target, _}, pending} ->
        reply(target, {:error, :timeout})
        s = %{s | pending: pending}

        if target == :initialize,
          do: {:noreply, down(s, :initialize_timeout)},
          else: {:noreply, s}
    end
  end

  def handle_info({:DOWN, _, :process, pid, reason}, %{port: pid} = s),
    do: {:noreply, down(%{s | port: nil}, {:http_transport, reason})}

  def handle_info(_, s), do: {:noreply, s}
  def terminate(_, s), do: close(s.port)

  defp rpc(s, method, params, target, timeout) do
    id = s.next
    wire(s, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    timer = Process.send_after(self(), {:timeout, id}, timeout)
    %{s | next: id + 1, pending: Map.put(s.pending, id, {target, timer})}
  end

  defp wire(%{port: pid}, msg) when is_pid(pid),
    do: Seedling.MCP.HTTP.command(pid, Jason.encode!(msg))

  defp wire(s, msg), do: Port.command(s.port, Jason.encode!(msg) <> "\n")

  defp message(s, %{"id" => id, "method" => _}) do
    wire(s, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "Client method not supported"}
    })

    s
  end

  defp message(s, %{"id" => id} = msg) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        s

      {{target, timer}, pending} ->
        Process.cancel_timer(timer)
        s = %{s | pending: pending}

        result =
          if Map.has_key?(msg, "error"), do: {:error, msg["error"]}, else: {:ok, msg["result"]}

        complete(s, target, result)
    end
  end

  defp message(s, %{"method" => method} = msg) do
    emit(s, method, msg["params"] || %{})
    s
  end

  defp message(s, _), do: s

  defp complete(s, :initialize, {:ok, info}) do
    wire(s, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    s = %{s | ready: true, info: info}
    emit(s, "connected", info)

    Enum.reduce(Map.keys(s.subs), s, fn uri, acc ->
      rpc(acc, "resources/subscribe", %{"uri" => uri}, :replay, 30_000)
    end)
  end

  defp complete(s, :initialize, error), do: down(s, error)

  defp complete(s, :replay, result) do
    if match?({:error, _}, result), do: emit(s, "subscription_error", %{result: result})
    s
  end

  defp complete(s, {:subscription, from, action, uri, agent}, {:ok, _}) do
    subs =
      if action == :add,
        do: Map.put(s.subs, uri, Enum.uniq([agent | Map.get(s.subs, uri, [])])),
        else: Map.delete(s.subs, uri)

    s = save(%{s | subs: subs})
    GenServer.reply(from, :ok)
    s
  end

  defp complete(s, target, result),
    do:
      (
        reply(target, result)
        s
      )

  defp reply(:initialize, _), do: :ok
  defp reply(:replay, _), do: :ok
  defp reply({:subscription, from, _, _, _}, result), do: GenServer.reply(from, result)
  defp reply(from, result), do: GenServer.reply(from, result)

  defp emit(s, method, params) do
    agents =
      Enum.uniq(
        s.watchers ++
          if(method == "notifications/resources/updated",
            do: Map.get(s.subs, params["uri"], []),
            else: List.flatten(Map.values(s.subs))
          )
      )

    Enum.each(agents, fn agent ->
      case s.resolver.(agent) do
        pid when is_pid(pid) -> send(pid, {:mcp, s.name, method, params})
        _ -> :ok
      end
    end)
  end

  defp down(s, reason) do
    close(s.port)

    Enum.each(s.pending, fn {_, {target, timer}} ->
      Process.cancel_timer(timer)
      reply(target, {:error, {:disconnected, reason}})
    end)

    emit(s, "disconnected", %{reason: reason})
    Process.send_after(self(), :connect, s.delay)
    %{s | ready: false, port: nil, pending: %{}, buffer: ""}
  end

  defp close(nil), do: :ok

  defp close(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end

  defp close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  defp save(s) do
    File.mkdir_p!(Path.dirname(s.file))
    temp = s.file <> ".tmp"
    File.write!(temp, Jason.encode!(s.subs))
    File.rename!(temp, s.file)
    s
  end
end

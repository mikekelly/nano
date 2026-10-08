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
      result_dir: Path.join(dir, "results"),
      result_limit: Keyword.get(opts, :max_result_bytes, 12_000),
      file: file,
      subs: if(is_map(subs), do: Map.get(subs, "subscriptions", subs), else: %{}),
      watchers: if(is_map(subs), do: Map.get(subs, "watchers", []), else: []),
      resolver: Keyword.get(opts, :resolver, &NanoAgent.whereis/1),
      port: nil,
      buffer: "",
      next: 1,
      pending: %{},
      ready: false,
      era: :modern,
      version: "2026-07-28",
      listen: nil,
      info: nil,
      delay: Keyword.get(opts, :reconnect_ms, 1000)
    }

    send(self(), :connect)
    {:ok, s}
  end

  def handle_call(:status, _, s),
    do:
      {:reply,
       Map.take(s, [:ready, :info, :name, :era, :version]) |> Map.update!(:info, &bounded(s, &1)),
       s}

  def handle_call({:watch, agent}, _, s) do
    s = save(%{s | watchers: Enum.uniq([agent | s.watchers])})
    {:reply, :ok, if(s.ready and s.era == :modern, do: listen(s), else: s)}
  end

  def handle_call({:request, method, params, timeout}, from, s) do
    if s.ready,
      do: {:noreply, rpc(s, method, params, {:request, from, method}, timeout)},
      else: {:reply, {:error, :disconnected}, s}
  end

  def handle_call({:subscription, action, uri, agent}, from, %{era: :modern, ready: true} = s)
      when is_binary(agent) do
    agents = Map.get(s.subs, uri, [])
    agents = if action == :add, do: Enum.uniq([agent | agents]), else: agents -- [agent]
    subs = if agents == [], do: Map.delete(s.subs, uri), else: Map.put(s.subs, uri, agents)
    s = save(%{s | subs: subs})
    s = listen(s, from)
    {:noreply, s}
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

    {:noreply, probe(s)}
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

      {:noreply, probe(s)}
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

  def handle_info({port, {:stream_closed, id}}, %{port: port} = s) do
    if s.listen && s.listen.id == id,
      do: {:noreply, down(s, :subscription_stream_closed)},
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

        cond do
          target == :probe -> {:noreply, legacy(s)}
          target == :initialize -> {:noreply, down(s, :initialize_timeout)}
          target == :listen -> {:noreply, down(s, :subscription_ack_timeout)}
          true -> {:noreply, s}
        end
    end
  end

  def handle_info({:DOWN, _, :process, pid, reason}, %{port: pid} = s),
    do: {:noreply, down(%{s | port: nil}, {:http_transport, reason})}

  def handle_info(_, s), do: {:noreply, s}
  def terminate(_, s), do: close(s.port)

  defp rpc(s, method, params, target, timeout) do
    id = s.next

    params =
      if s.era == :modern do
        meta =
          Map.merge(params["_meta"] || %{}, %{
            "io.modelcontextprotocol/protocolVersion" => s.version,
            "io.modelcontextprotocol/clientCapabilities" => %{},
            "io.modelcontextprotocol/clientInfo" => %{"name" => "seedling", "version" => "0.1.0"}
          })

        Map.put(params, "_meta", meta)
      else
        params
      end

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
        if s.listen && s.listen.id == id, do: down(s, :subscription_closed), else: s

      {{target, timer}, pending} ->
        Process.cancel_timer(timer)
        s = %{s | pending: pending}

        result =
          if Map.has_key?(msg, "error"), do: {:error, msg["error"]}, else: {:ok, msg["result"]}

        complete(s, target, result)
    end
  end

  defp message(%{era: :modern} = s, %{
         "method" => "notifications/subscriptions/acknowledged",
         "params" => params
       }) do
    id = get_in(params, ["_meta", "io.modelcontextprotocol/subscriptionId"])

    if s.listen && s.listen.id == id do
      {_entry, pending} = Map.pop(s.pending, id)
      if s.listen.timer, do: Process.cancel_timer(s.listen.timer)
      Enum.each(s.listen.froms, &GenServer.reply(&1, :ok))
      requested = s.listen.filter
      honored = params["notifications"] || %{}

      if requested != honored,
        do: emit(s, "subscription_filter_reduced", %{requested: requested, honored: honored})

      emit(s, "subscription_restored", params)
      %{s | pending: pending, listen: %{s.listen | timer: nil, froms: []}}
    else
      s
    end
  end

  defp message(s, %{"method" => method} = msg) do
    params = msg["params"] || %{}
    id = get_in(params, ["_meta", "io.modelcontextprotocol/subscriptionId"])

    if s.era != :modern or is_nil(id) or (s.listen && s.listen.id == id && is_nil(s.listen.timer)),
      do: emit(s, method, params)

    s
  end

  defp message(s, _), do: s

  defp probe(s),
    do:
      rpc(
        %{s | era: :modern, version: "2026-07-28", listen: nil},
        "server/discover",
        %{},
        :probe,
        2000
      )

  defp legacy(s),
    do:
      rpc(
        %{s | era: :legacy, version: "2025-11-25"},
        "initialize",
        %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "seedling", "version" => "0.1.0"}
        },
        :initialize,
        30_000
      )

  defp complete(s, :probe, {:ok, %{"supportedVersions" => versions} = info}) do
    if "2026-07-28" in versions do
      s = %{s | ready: true, info: info}
      emit(s, "connected", info)

      emit(s, "recovered", %{
        era: "modern",
        subscription_uris: Map.keys(s.subs),
        watcher_names: s.watchers
      })

      if map_size(s.subs) > 0 or s.watchers != [], do: listen(s), else: s
    else
      down(s, {:unsupported_versions, versions})
    end
  end

  defp complete(s, :probe, {:error, %{"code" => code} = error})
       when code in [-32022, -32021, -32020],
       do: down(s, error)

  defp complete(s, :probe, _), do: legacy(s)
  defp complete(s, :listen, error), do: down(s, {:subscription_failed, error})

  defp complete(s, :initialize, {:ok, info}) do
    version = info["protocolVersion"] || "2025-11-25"
    if is_pid(s.port), do: Seedling.MCP.HTTP.version(s.port, version)
    wire(s, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    s = %{s | ready: true, info: info, version: version}
    emit(s, "connected", info)

    emit(s, "recovered", %{
      era: "legacy",
      subscription_uris: Map.keys(s.subs),
      watcher_names: s.watchers
    })

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

  defp complete(
         %{era: :modern, port: port} = s,
         {:request, from, "tools/list"},
         {:ok, %{"tools" => tools} = result}
       )
       when is_pid(port) do
    valid =
      Enum.filter(tools, fn tool ->
        case Seedling.MCP.Headers.bindings(tool) do
          {:ok, _} ->
            true

          {:error, reason} ->
            emit(s, "invalid_tool_schema", %{tool: tool["name"], reason: reason})
            false
        end
      end)

    Seedling.MCP.HTTP.tools(port, valid)
    GenServer.reply(from, {:ok, bounded(s, Map.put(result, "tools", valid))})
    s
  end

  defp complete(s, target, result),
    do:
      (
        reply(
          target,
          case result do
            {kind, value} -> {kind, bounded(s, value)}
          end
        )

        s
      )

  defp reply({:request, from, _}, result), do: GenServer.reply(from, result)
  defp reply(:initialize, _), do: :ok
  defp reply(:probe, _), do: :ok
  defp reply(:listen, _), do: :ok
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

    params = bounded(s, params)

    Enum.each(agents, fn agent ->
      case s.resolver.(agent) do
        pid when is_pid(pid) -> send(pid, {:mcp, s.name, method, params})
        _ -> :ok
      end
    end)
  end

  defp listen(s, from \\ nil) do
    froms = if s.listen, do: s.listen.froms, else: []

    if s.listen do
      if s.listen.timer, do: Process.cancel_timer(s.listen.timer)

      if is_pid(s.port),
        do: Seedling.MCP.HTTP.cancel(s.port, s.listen.id),
        else:
          wire(s, %{
            "jsonrpc" => "2.0",
            "method" => "notifications/cancelled",
            "params" => %{"requestId" => s.listen.id}
          })
    end

    pending = if s.listen, do: Map.delete(s.pending, s.listen.id), else: s.pending
    filter = %{"resourceSubscriptions" => Map.keys(s.subs)}

    filter =
      if s.watchers != [],
        do:
          Map.merge(filter, %{
            "toolsListChanged" => true,
            "promptsListChanged" => true,
            "resourcesListChanged" => true
          }),
        else: filter

    id = s.next

    s =
      rpc(
        %{s | pending: pending},
        "subscriptions/listen",
        %{"notifications" => filter},
        :listen,
        30_000
      )

    {_, timer} = s.pending[id]

    %{
      s
      | listen: %{
          id: id,
          filter: filter,
          timer: timer,
          froms: if(from, do: froms ++ [from], else: froms)
        }
    }
  end

  defp down(s, reason) do
    close(s.port)

    if s.listen,
      do: Enum.each(s.listen.froms, &GenServer.reply(&1, {:error, {:disconnected, reason}}))

    Enum.each(s.pending, fn {_, {target, timer}} ->
      Process.cancel_timer(timer)
      reply(target, {:error, {:disconnected, reason}})
    end)

    emit(s, "disconnected", %{reason: reason})
    Process.send_after(self(), :connect, s.delay)
    %{s | ready: false, port: nil, pending: %{}, buffer: "", listen: nil}
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

  defp bounded(s, value) do
    text =
      case Jason.encode(value) do
        {:ok, text} ->
          text

        {:error, _} ->
          Jason.encode!(%{elixir: inspect(value, limit: :infinity, printable_limit: :infinity)})
      end

    if byte_size(text) <= s.result_limit do
      value
    else
      File.mkdir_p!(s.result_dir)

      path =
        Path.join(
          s.result_dir,
          "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.json"
        )

      File.write!(path, text, [:exclusive])
      File.chmod!(path, 0o600)

      summary = %{
        spilled: true,
        path: path,
        bytes: byte_size(text),
        preview: String.slice(text, 0, 1000),
        usage: "Seedling.MCP.result_page(path, offset: 0, limit: 8000)"
      }

      if is_map(value), do: Map.merge(summary, Map.take(value, ["nextCursor"])), else: summary
    end
  end

  defp save(s) do
    File.mkdir_p!(Path.dirname(s.file))
    temp = s.file <> ".tmp"
    File.write!(temp, Jason.encode!(%{"subscriptions" => s.subs, "watchers" => s.watchers}))
    File.rename!(temp, s.file)
    s
  end
end

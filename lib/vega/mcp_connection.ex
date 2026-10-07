defmodule Vega.MCP.Connection do
  @moduledoc false
  use GenServer
  require Logger
  @versions ["2025-11-25", "2025-06-18", "2025-03-26"]
  @modern "2026-07-28"
  @max_wire 8 * 1024 * 1024
  def start_link({name, config}),
    do:
      GenServer.start_link(__MODULE__, {name, config},
        name: {:via, Registry, {Vega.MCP.Registry, name}}
      )

  def init({name, config}) do
    Process.flag(:trap_exit, true)
    send(self(), :connect)

    {:ok,
     %{
       name: name,
       config: config,
       port: nil,
       buffer: "",
       phase: :connecting,
       version: Map.get(config, "protocol", hd(@versions)),
       info: nil,
       next: 1,
       pending: %{},
       listen: nil,
       schemas: %{},
       waiters: [],
       interests: Vega.MCP.State.get(name),
       session: nil,
       jobs: %{},
       stream: nil,
       stream_cursor: nil,
       stream_retry: 500,
       backoff: 250,
       generation: make_ref()
     }}
  end

  def handle_call(:ready, _from, %{phase: :ready} = s), do: {:reply, {:ok, bound(s.info, s)}, s}
  def handle_call(:ready, from, s), do: {:noreply, %{s | waiters: [from | s.waiters]}}

  def handle_call(:status, _, s),
    do:
      {:reply,
       {:ok,
        %{
          phase: s.phase,
          server: bound(s.info, s),
          protocol: s.version,
          pending: map_size(s.pending)
        }}, s}

  def handle_call({op, agent}, from, %{version: @modern, phase: :ready} = s)
      when op in [:watch, :unwatch] do
    if s.listen && not s.listen.acked do
      {:reply, {:error, :subscription_busy}, s}
    else
      watchers =
        if op == :watch,
          do: Enum.uniq([agent | s.interests["watchers"]]),
          else: List.delete(s.interests["watchers"], agent)

      case Vega.MCP.State.put(s.name, Map.put(s.interests, "watchers", watchers)) do
        :ok ->
          s =
            modern_listen(
              %{s | interests: Map.put(s.interests, "watchers", watchers)},
              {from, :watch}
            )

          if s.listen, do: {:noreply, s}, else: {:reply, :ok, s}

        error ->
          {:reply, error, s}
      end
    end
  end

  def handle_call({op, agent}, _, s) when op in [:watch, :unwatch] do
    watchers =
      if op == :watch,
        do: Enum.uniq([agent | s.interests["watchers"]]),
        else: List.delete(s.interests["watchers"], agent)

    interests = Map.put(s.interests, "watchers", watchers)
    persist_reply(interests, s)
  end

  def handle_call({:request, _, _, _}, _, %{pending: pending} = s) when map_size(pending) >= 128,
    do: {:reply, {:error, :busy}, s}

  def handle_call({op, uri, agent}, from, %{phase: :ready, version: @modern} = s)
      when op in [:subscribe, :unsubscribe] do
    cond do
      s.listen && not s.listen.acked ->
        {:reply, {:error, :subscription_busy}, s}

      op == :subscribe and get_in(s.info, ["capabilities", "resources", "subscribe"]) != true ->
        {:reply, {:error, :subscription_not_supported}, s}

      true ->
        agents = Map.get(s.interests["resources"], uri, [])

        agents =
          if op == :subscribe, do: Enum.uniq([agent | agents]), else: List.delete(agents, agent)

        resources =
          if agents == [],
            do: Map.delete(s.interests["resources"], uri),
            else: Map.put(s.interests["resources"], uri, agents)

        interests = Map.put(s.interests, "resources", resources)

        case Vega.MCP.State.put(s.name, interests) do
          :ok ->
            s =
              modern_listen(
                %{s | interests: interests},
                if(op == :subscribe, do: {from, uri}, else: nil)
              )

            if op == :subscribe, do: {:noreply, s}, else: {:reply, :ok, s}

          error ->
            {:reply, error, s}
        end
    end
  end

  def handle_call({op, uri, _agent} = call, from, %{phase: :ready} = s)
      when op in [:subscribe, :unsubscribe] do
    busy =
      Enum.any?(s.pending, fn
        {_, {{:interest, _, _, pending_uri, _}, _}} -> pending_uri == uri
        _ -> false
      end)

    if busy,
      do: {:reply, {:error, :subscription_busy}, s},
      else: handle_subscription(call, from, s)
  end

  def handle_call(
        {:request, "tools/call", params, timeout},
        from,
        %{phase: :ready, version: @modern, config: %{"url" => _}} = s
      ) do
    if Map.has_key?(s.schemas, params["name"]) do
      {:noreply, modern_tool(s, params, from, timeout)}
    else
      deadline = System.monotonic_time(:millisecond) + timeout
      {:noreply, rpc(s, "tools/list", %{}, {:prepare_tool, from, params, deadline, 32}, timeout)}
    end
  end

  def handle_call({:request, method, params, timeout}, from, %{phase: :ready} = s),
    do: {:noreply, rpc(s, method, params, {:call, from, method}, timeout)}

  def handle_call(_, _, s), do: {:reply, {:error, :not_ready}, s}

  defp handle_subscription({:subscribe, uri, agent}, from, %{phase: :ready} = s) do
    if get_in(s.info, ["capabilities", "resources", "subscribe"]) == true do
      agents = Map.get(s.interests["resources"], uri, [])
      interests = put_in(s.interests, ["resources", uri], Enum.uniq([agent | agents]))

      if agents == [],
        do:
          {:noreply,
           rpc(
             s,
             "resources/subscribe",
             %{"uri" => uri},
             {:interest, from, :subscribe, uri, agent},
             20_000
           )},
        else: persist_reply(interests, s)
    else
      {:reply, {:error, :subscription_not_supported}, s}
    end
  end

  defp handle_subscription({:unsubscribe, uri, agent}, from, %{phase: :ready} = s) do
    agents = Map.get(s.interests["resources"], uri, []) |> List.delete(agent)

    resources =
      if agents == [],
        do: Map.delete(s.interests["resources"], uri),
        else: Map.put(s.interests["resources"], uri, agents)

    interests = Map.put(s.interests, "resources", resources)

    if agents == [],
      do:
        {:noreply,
         rpc(
           s,
           "resources/unsubscribe",
           %{"uri" => uri},
           {:interest, from, :unsubscribe, uri, agent},
           20_000
         )},
      else: persist_reply(interests, s)
  end

  defp persist_reply(interests, s) do
    case Vega.MCP.State.put(s.name, interests) do
      :ok -> {:reply, :ok, %{s | interests: interests}}
      error -> {:reply, error, s}
    end
  end

  def handle_info(:connect, s) do
    generation = make_ref()

    s = %{
      s
      | generation: generation,
        session: nil,
        stream_cursor: nil,
        version: Map.get(s.config, "protocol", hd(@versions)),
        phase: :initializing,
        buffer: ""
    }

    case open(s) do
      {:ok, %{version: @modern} = s} ->
        {:noreply, rpc(s, "server/discover", %{}, :discover, 15_000)}

      {:ok, s} ->
        {:noreply,
         rpc(
           s,
           "initialize",
           %{
             "protocolVersion" => s.version,
             "capabilities" => %{},
             "clientInfo" => %{"name" => "vega", "version" => "1.0"}
           },
           :initialize,
           15_000
         )}

      {:error, reason} ->
        {:noreply, down(s, reason)}
    end
  end

  def handle_info({port, {:data, chunk}}, %{port: port} = s) when is_port(port) do
    buffer = s.buffer <> chunk

    if byte_size(buffer) > @max_wire do
      {:noreply, down(s, :wire_limit)}
    else
      parts = String.split(buffer, "\n")
      {tail, lines} = List.pop_at(parts, -1)
      s = Enum.reduce(lines, %{s | buffer: tail}, fn line, acc -> decode(line, acc) end)
      {:noreply, s}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = s),
    do: {:noreply, down(s, {:server_exit, code})}

  def handle_info({:EXIT, port, reason}, %{port: port} = s) when is_port(port),
    do: {:noreply, down(s, {:port_exit, reason})}

  def handle_info({:wire, gen, msg}, %{generation: gen} = s), do: {:noreply, incoming(msg, s)}

  def handle_info({:http_headers, gen, session}, %{generation: gen} = s) when is_binary(session),
    do: {:noreply, %{s | session: session}}

  def handle_info({:http_done, gen, pid, kind, result}, %{generation: gen} = s) do
    current_job = Map.has_key?(s.jobs, pid)
    s = %{s | jobs: Map.delete(s.jobs, pid)}

    case {kind, result} do
      {_, _} when not current_job ->
        {:noreply, s}

      {:listen, result} ->
        {:noreply, listen_failed(s, result)}

      {_, {:error, reason}} ->
        {:noreply, down(s, reason)}

      {:get, :unsupported} ->
        {:noreply, %{s | stream: nil}}

      {:get, :ok} ->
        Process.send_after(self(), {:stream, gen}, s.stream_retry)
        {:noreply, %{s | stream: nil}}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:stream, gen}, %{generation: gen, phase: :ready, stream: nil} = s),
    do: {:noreply, http(s, :get, nil)}

  def handle_info({:sse_state, gen, id, retry}, %{generation: gen} = s) do
    {:noreply, %{s | stream_cursor: id || s.stream_cursor, stream_retry: retry || s.stream_retry}}
  end

  def handle_info(
        {:modern_listen, gen},
        %{generation: gen, phase: :ready, version: @modern, listen: nil} = s
      ),
      do: {:noreply, modern_listen(s, nil)}

  def handle_info({:listen_timeout, id}, %{listen: %{id: id, acked: false}} = s),
    do: {:noreply, listen_failed(s, :ack_timeout)}

  def handle_info({:timeout, id}, s) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        {:noreply, s}

      {{action, _timer}, pending} ->
        s = %{s | pending: pending}

        if action in [:initialize, :discover] do
          {:noreply, down(s, :initialize_timeout)}
        else
          reply(action, {:error, :timeout})

          s = cancel_request(s, id)

          {:noreply, s}
        end
    end
  end

  def handle_info({:EXIT, pid, reason}, s) when is_pid(pid) do
    if Map.has_key?(s.jobs, pid),
      do: {:noreply, down(s, {:http_worker_exit, reason})},
      else: {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp open(%{config: %{"command" => command} = config} = s) do
    executable = System.find_executable(command) || if(File.regular?(command), do: command)

    if executable do
      env =
        Enum.map(Map.get(config, "env", %{}), fn {k, v} ->
          {String.to_charlist(k), String.to_charlist(v)}
        end)

      opts = [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: Map.get(config, "args", []),
        env: env
      ]

      opts = if config["cwd"], do: opts ++ [cd: config["cwd"]], else: opts
      {:ok, %{s | port: Port.open({:spawn_executable, executable}, opts)}}
    else
      {:error, :executable_not_found}
    end
  rescue
    e -> {:error, {:spawn_failed, Exception.message(e)}}
  end

  defp open(%{config: %{"url" => url}} = s) when is_binary(url), do: {:ok, s}
  defp open(_), do: {:error, :invalid_transport_config}

  defp rpc(s, method, params, action, timeout) do
    params = if s.version == @modern, do: Vega.MCP.Protocol.metadata(params), else: params
    id = s.next
    timer = Process.send_after(self(), {:timeout, id}, timeout)
    s = %{s | next: id + 1, pending: Map.put(s.pending, id, {action, timer})}
    transmit(s, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  end

  defp transmit(%{port: port} = s, msg) when is_port(port) do
    Port.command(port, Jason.encode!(msg) <> "\n")
    s
  rescue
    _ -> down(s, :write_failed)
  end

  defp transmit(%{config: %{"url" => _}} = s, msg), do: http(s, :post, msg)
  defp transmit(s, _), do: s

  defp http(s, kind, msg) do
    owner = self()
    gen = s.generation

    config =
      s.config |> Map.put("_last_event_id", s.stream_cursor) |> Map.put("_schemas", s.schemas)

    session = s.session
    version = s.version

    pid =
      spawn_link(fn ->
        result =
          Vega.MCP.HTTP.run(
            owner,
            gen,
            config,
            session,
            version,
            if(kind == :listen, do: :post, else: kind),
            msg
          )

        send(owner, {:http_done, gen, self(), kind, result})
      end)

    %{
      s
      | jobs: Map.put(s.jobs, pid, {kind, if(msg, do: msg["id"], else: nil)}),
        stream: if(kind == :get, do: pid, else: s.stream)
    }
  end

  defp decode("", s), do: s

  defp decode(line, s) do
    case Jason.decode(line) do
      {:ok, msg} when is_map(msg) -> incoming(msg, s)
      _ -> down(s, :invalid_json_rpc)
    end
  end

  defp incoming(%{"jsonrpc" => "2.0"} = msg, s), do: message(msg, s)
  defp incoming(_, s), do: down(s, :invalid_json_rpc)

  defp message(%{"method" => _method, "id" => _id}, %{version: @modern} = s),
    do: down(s, :server_request_forbidden)

  defp message(%{"method" => method, "id" => id}, s) when is_binary(method) do
    result =
      if method == "ping",
        do: %{"result" => %{}},
        else: %{"error" => %{"code" => -32601, "message" => "Client capability not supported"}}

    transmit(s, Map.merge(%{"jsonrpc" => "2.0", "id" => id}, result))
  end

  defp message(%{"method" => method} = msg, %{version: @modern} = s) when is_binary(method),
    do: modern_notification(method, Map.get(msg, "params", %{}), s)

  defp message(%{"method" => method} = msg, s) when is_binary(method) do
    params = Map.get(msg, "params", %{})

    recipients =
      if method == "notifications/resources/updated",
        do: Map.get(s.interests["resources"], params["uri"], []),
        else: []

    emit(s, method, params, recipients)
    s
  end

  defp message(%{"id" => id} = msg, %{version: @modern, listen: %{id: id}} = s) do
    listen_failed(s, if(msg["error"], do: msg["error"], else: :graceful_close))
  end

  defp message(%{"id" => id} = msg, s) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        s

      {{action, timer}, pending} ->
        Process.cancel_timer(timer)
        s = %{s | pending: pending}

        result =
          if Map.has_key?(msg, "error"),
            do: {:error, msg["error"]},
            else: {:ok, Map.get(msg, "result", %{})}

        complete(action, result, s)
    end
  end

  defp message(_, s), do: s

  defp complete(:discover, {:ok, %{"supportedVersions" => versions} = info}, s) do
    if @modern in versions do
      info =
        info
        |> Map.put("protocolVersion", @modern)
        |> Map.put("serverInfo", get_in(info, ["_meta", "io.modelcontextprotocol/serverInfo"]))

      s = %{s | info: info, phase: :ready, backoff: 250}
      Enum.each(s.waiters, &GenServer.reply(&1, {:ok, bound(info, s)}))
      emit(s, "connection/ready", %{"protocolVersion" => @modern})
      modern_listen(%{s | waiters: []}, nil)
    else
      down(s, {:unsupported_protocol, versions})
    end
  end

  defp complete(
         {:prepare_tool, from, params, deadline, pages},
         {:ok, %{"tools" => tools} = result},
         s
       ) do
    {_result, s} = cache_tools(tools, result, s)
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        GenServer.reply(from, {:error, :timeout})
        s

      Map.has_key?(s.schemas, params["name"]) ->
        modern_tool(s, params, from, remaining)

      result["nextCursor"] && pages > 1 ->
        rpc(
          s,
          "tools/list",
          %{"cursor" => result["nextCursor"]},
          {:prepare_tool, from, params, deadline, pages - 1},
          remaining
        )

      true ->
        GenServer.reply(from, {:error, :unknown_tool})
        s
    end
  end

  defp complete({:prepare_tool, from, _, _, _}, result, s),
    do:
      (
        GenServer.reply(from, bound_result(result, s))
        s
      )

  defp complete(:discover, result, s), do: down(s, {:discovery_failed, bound_result(result, s)})

  defp complete(
         {:call, from, "tools/list"},
         {:ok, %{"tools" => tools} = result},
         %{version: @modern, config: %{"url" => _}} = s
       ) do
    {result, s} = cache_tools(tools, result, s)
    GenServer.reply(from, bound_result({:ok, result}, s))
    s
  end

  defp complete(:initialize, {:ok, %{"protocolVersion" => version} = info}, s)
       when version in @versions do
    s = %{s | version: version, info: info, phase: :ready, backoff: 250}
    s = transmit(s, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    Enum.each(s.waiters, &GenServer.reply(&1, {:ok, bound(info, s)}))
    emit(s, "connection/ready", %{"protocolVersion" => version})
    s = %{s | waiters: []}

    s =
      Enum.reduce(s.interests["resources"], s, fn {uri, _}, acc ->
        rpc(acc, "resources/subscribe", %{"uri" => uri}, {:restore, uri}, 20_000)
      end)

    if s.config["url"], do: http(s, :get, nil), else: s
  end

  defp complete(:initialize, result, s),
    do: down(s, {:initialize_failed, bound_result(result, s)})

  defp complete({:interest, from, op, uri, agent}, {:ok, _}, s) do
    agents = Map.get(s.interests["resources"], uri, [])

    agents =
      if op == :subscribe, do: Enum.uniq([agent | agents]), else: List.delete(agents, agent)

    resources =
      if agents == [],
        do: Map.delete(s.interests["resources"], uri),
        else: Map.put(s.interests["resources"], uri, agents)

    interests = Map.put(s.interests, "resources", resources)

    case Vega.MCP.State.put(s.name, interests) do
      :ok ->
        GenServer.reply(from, :ok)
        %{s | interests: interests}

      error ->
        GenServer.reply(from, error)
        s
    end
  end

  defp complete({:restore, uri}, {:error, error}, s) do
    emit(
      s,
      "subscription/failed",
      %{"uri" => uri, "error" => error},
      Map.get(s.interests["resources"], uri, [])
    )

    s
  end

  defp complete(action, result, s),
    do:
      (
        reply(action, bound_result(result, s))
        s
      )

  defp reply({:prepare_tool, from, _, _, _}, result), do: GenServer.reply(from, result)
  defp reply({:call, from, _}, result), do: GenServer.reply(from, result)
  defp reply({:interest, from, _, _, _}, result), do: GenServer.reply(from, result)
  defp reply(_, _), do: :ok

  defp down(%{phase: :disconnected} = s, _), do: s

  defp down(s, reason) do
    close(s)

    if s.listen && s.listen.from,
      do: GenServer.reply(elem(s.listen.from, 0), {:error, {:disconnected, reason}})

    if s.listen, do: Process.cancel_timer(s.listen.timer)

    Enum.each(s.pending, fn {_, {action, timer}} ->
      Process.cancel_timer(timer)
      reply(action, {:error, {:disconnected, reason}})
    end)

    Enum.each(s.waiters, &GenServer.reply(&1, {:error, {:disconnected, reason}}))
    emit(s, "connection/dead", %{"reason" => inspect(reason)})
    Process.send_after(self(), :connect, s.backoff)

    %{
      s
      | port: nil,
        phase: :disconnected,
        listen: nil,
        pending: %{},
        waiters: [],
        jobs: %{},
        stream: nil,
        generation: make_ref(),
        backoff: min(s.backoff * 2, 30_000)
    }
  end

  defp close(s) do
    if is_port(s.port),
      do:
        (try do
           Port.close(s.port)
         rescue
           _ -> :ok
         end)

    Enum.each(s.jobs, fn {pid, _} -> Process.exit(pid, :kill) end)
  end

  def terminate(_, s), do: close(s)

  defp emit(s, method, params, extra \\ []) do
    recipients =
      Enum.uniq(
        s.interests["watchers"] ++
          extra ++
          if(String.starts_with?(method, "connection/"),
            do: Enum.flat_map(s.interests["resources"], fn {_, agents} -> agents end),
            else: []
          )
      )

    event = %{mcp: s.name, method: method, params: bound(params, s)}
    Enum.each(recipients, &NanoAgent.notify(&1, event))
  end

  defp cache_tools(tools, result, s) do
    {valid, schemas} =
      Enum.reduce(tools, {[], s.schemas}, fn tool, {valid, schemas} ->
        case Vega.MCP.Protocol.annotations(tool["inputSchema"] || %{}) do
          {:ok, annotations} ->
            {[tool | valid], Map.put(schemas, tool["name"], annotations)}

          {:error, reason} ->
            Logger.warning(
              "MCP excluded invalid x-mcp-header schema for tool #{inspect(tool["name"])}: #{inspect(reason)}"
            )

            emit(s, "tool/rejected", %{"name" => tool["name"], "reason" => inspect(reason)})
            {valid, Map.put(schemas, tool["name"], :invalid)}
        end
      end)

    {Map.put(result, "tools", Enum.reverse(valid)), %{s | schemas: schemas}}
  end

  defp modern_tool(s, params, from, timeout) do
    if s.schemas[params["name"]] == :invalid do
      GenServer.reply(from, {:error, :invalid_tool_definition})
      s
    else
      try do
        Vega.MCP.Protocol.headers(%{"method" => "tools/call", "params" => params}, s.schemas)
        rpc(s, "tools/call", params, {:call, from, "tools/call"}, timeout)
      rescue
        _error ->
          GenServer.reply(from, {:error, :invalid_header_argument})
          s
      end
    end
  end

  defp modern_listen(s, from) do
    s = stop_listen(s)
    filter = %{"resourceSubscriptions" => Map.keys(s.interests["resources"])}

    filter =
      if s.interests["watchers"] != [],
        do:
          Map.merge(filter, %{
            "toolsListChanged" => true,
            "resourcesListChanged" => true,
            "promptsListChanged" => true
          }),
        else: filter

    if filter == %{"resourceSubscriptions" => []} do
      s
    else
      id = s.next
      timer = Process.send_after(self(), {:listen_timeout, id}, 15_000)

      s = %{
        s
        | next: id + 1,
          listen: %{id: id, filter: filter, acked: false, timer: timer, from: from}
      }

      msg = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "subscriptions/listen",
        "params" => Vega.MCP.Protocol.metadata(%{"notifications" => filter})
      }

      if s.config["url"], do: http(s, :listen, msg), else: transmit(s, msg)
    end
  end

  defp stop_listen(%{listen: nil} = s), do: s

  defp stop_listen(s) do
    Process.cancel_timer(s.listen.timer)
    s = cancel_request(s, s.listen.id)
    %{s | listen: nil}
  end

  defp cancel_request(%{config: %{"url" => _}} = s, id) do
    s =
      if s.version == @modern,
        do: s,
        else:
          transmit(s, %{
            "jsonrpc" => "2.0",
            "method" => "notifications/cancelled",
            "params" => %{"requestId" => id, "reason" => "cancelled"}
          })

    jobs =
      Enum.reduce(s.jobs, s.jobs, fn
        {pid, {_, ^id}}, acc ->
          Process.exit(pid, :kill)
          Map.delete(acc, pid)

        _, acc ->
          acc
      end)

    %{s | jobs: jobs}
  end

  defp cancel_request(s, id),
    do:
      transmit(s, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => id, "reason" => "cancelled"}
      })

  defp listen_failed(%{listen: nil} = s, _), do: s

  defp listen_failed(s, reason) do
    if s.listen.from,
      do: GenServer.reply(elem(s.listen.from, 0), {:error, {:subscription_failed, reason}})

    emit(
      s,
      "subscription/failed",
      %{"reason" => inspect(reason)},
      Enum.flat_map(s.interests["resources"], fn {_, agents} -> agents end)
    )

    s = stop_listen(s)
    Process.send_after(self(), {:modern_listen, s.generation}, 500)
    s
  end

  defp modern_notification(
         "notifications/subscriptions/acknowledged",
         params,
         %{listen: listen} = s
       )
       when is_map(listen) do
    if get_in(params, ["_meta", "io.modelcontextprotocol/subscriptionId"]) == listen.id do
      filter = Map.get(params, "notifications", %{})
      Process.cancel_timer(listen.timer)
      requested = Map.get(listen.filter, "resourceSubscriptions", [])
      actual = Map.get(filter, "resourceSubscriptions", [])
      missing = requested -- actual

      Enum.each(missing, fn uri ->
        emit(
          s,
          "subscription/failed",
          %{"uri" => uri, "reason" => "not acknowledged"},
          Map.get(s.interests["resources"], uri, [])
        )
      end)

      if listen.from do
        {from, uri} = listen.from

        GenServer.reply(
          from,
          if(uri == :watch or uri in actual,
            do: :ok,
            else: {:error, :subscription_not_acknowledged}
          )
        )
      end

      %{s | listen: %{listen | acked: true, filter: filter, from: nil}}
    else
      s
    end
  end

  defp modern_notification(method, params, s)
       when method in [
              "notifications/subscriptions/acknowledged",
              "notifications/resources/updated",
              "notifications/tools/list_changed",
              "notifications/resources/list_changed",
              "notifications/prompts/list_changed"
            ] do
    id = get_in(params, ["_meta", "io.modelcontextprotocol/subscriptionId"])

    if s.listen && s.listen.acked && id == s.listen.id do
      filter = s.listen.filter

      allowed =
        case method do
          "notifications/resources/updated" ->
            params["uri"] in Map.get(filter, "resourceSubscriptions", [])

          "notifications/tools/list_changed" ->
            filter["toolsListChanged"] == true

          "notifications/resources/list_changed" ->
            filter["resourcesListChanged"] == true

          "notifications/prompts/list_changed" ->
            filter["promptsListChanged"] == true

          _ ->
            false
        end

      if allowed do
        extra =
          if method == "notifications/resources/updated",
            do: Map.get(s.interests["resources"], params["uri"], []),
            else: []

        emit(s, method, params, extra)
        if method == "notifications/tools/list_changed", do: %{s | schemas: %{}}, else: s
      else
        s
      end
    else
      s
    end
  end

  defp modern_notification(method, params, s) do
    # Request-scoped progress/logs carry no subscription identity and go to watchers.
    if is_nil(get_in(params, ["_meta", "io.modelcontextprotocol/subscriptionId"])),
      do: emit(s, method, params)

    s
  end

  defp bound_result({tag, result}, s), do: {tag, bound(result, s)}

  defp bound(value, s) do
    encoded = Jason.encode!(value)
    limit = (s.config["result_limit"] || 16_384) |> max(256) |> min(32_768)

    if byte_size(encoded) <= limit do
      value
    else
      dir = Path.join(Vega.MCP.State.directory(), "results")

      path =
        Path.join(
          dir,
          "#{System.unique_integer([:positive, :monotonic])}-#{:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)}.json"
        )

      result = with :ok <- File.mkdir_p(dir), do: File.write(path, encoded)

      case result do
        :ok ->
          %{
            truncated: true,
            bytes: byte_size(encoded),
            preview: binary_part(encoded, 0, min(limit, 4096)),
            spill: path
          }

        {:error, reason} ->
          %{truncated: true, bytes: byte_size(encoded), spill_error: inspect(reason)}
      end
    end
  end
end

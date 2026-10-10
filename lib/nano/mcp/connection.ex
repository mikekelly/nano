defmodule Nano.MCP.Connection do
  @moduledoc false
  use GenServer
  @modern "2026-07-28"
  @legacy ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{id: make_ref(), start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  def request(pid, method, params, timeout),
    do: GenServer.call(pid, {:request, method, params, timeout}, timeout + 1000)

  def await(pid, timeout), do: GenServer.call(pid, {:await, timeout}, timeout + 1000)
  def catalog(pid), do: GenServer.call(pid, :catalog)

  def subscriptions(pid, uris, timeout),
    do: GenServer.call(pid, {:subscriptions, uris, timeout}, timeout + 1000)

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :redacted) |> Map.put(:message, :redacted)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    s = %{
      agent: opts[:agent],
      server: opts[:server],
      uris: opts[:uris] || [],
      transport: nil,
      module: nil,
      phase: :offline,
      version: @modern,
      capabilities: %{},
      catalog: %{},
      tool_schemas: %{},
      pending: %{},
      next: 1,
      waiters: %{},
      retry: 250,
      stream: nil,
      acknowledged: false,
      generation: 0,
      active_uris: MapSet.new(),
      restore_backoff: %{},
      listen_backoff: 250,
      restore_timeout: 10000
    }

    send(self(), :connect)
    {:ok, s}
  end

  @impl true
  def handle_call({:await, _timeout}, _from, %{phase: :ready} = s), do: {:reply, :ok, s}

  def handle_call({:await, timeout}, from, s) do
    ref = make_ref()
    Process.send_after(self(), {:await_timeout, ref}, timeout)
    {:noreply, %{s | waiters: Map.put(s.waiters, ref, from)}}
  end

  def handle_call(:catalog, _from, s),
    do:
      {:reply,
       {:ok,
        Nano.MCP.Page.bound(%{
          status: s.phase,
          protocol: s.version,
          capabilities: s.capabilities,
          catalog: s.catalog,
          subscriptions: %{desired: s.uris, active: MapSet.to_list(s.active_uris)}
        })}, s}

  def handle_call({:request, method, params, timeout}, from, %{phase: :ready} = s) do
    cond do
      not is_map(Map.get(params, "_meta", %{})) ->
        {:reply, {:error, :invalid_request_metadata}, s}

      map_size(s.pending) >= 128 ->
        {:reply, {:error, :too_many_requests}, s}

      not request_fits?(params) ->
        {:reply, {:error, :request_too_large_or_invalid}, s}

      true ->
        case request_headers(s, method, params) do
          {:ok, headers} ->
            {:noreply,
             rpc(
               s,
               method,
               params,
               {:caller, from, method, not Map.has_key?(params, "cursor")},
               timeout,
               headers
             )}

          error ->
            {:reply, error, s}
        end
    end
  end

  def handle_call({:request, _, _, _}, _, s), do: {:reply, {:error, :not_connected}, s}

  def handle_call({:subscriptions, uris, timeout}, from, %{phase: :ready} = s) do
    if Enum.any?(s.pending, fn {_, p} ->
         match?({:subscription, _, _}, p.kind) or match?({:legacy_subscriptions, _, _, _}, p.kind) or
           match?({:restore, _}, p.kind)
       end) do
      {:reply, {:error, :subscription_busy}, s}
    else
      if capability(s, "resources", "subscribe") != true and uris != [] do
        {:reply, {:error, :subscriptions_unsupported}, s}
      else
        if s.version == @modern do
          s = cancel_stream(s)
          {:noreply, listen(%{s | uris: uris}, {:subscription, from, s.uris}, timeout)}
        else
          added = uris -- MapSet.to_list(s.active_uris)
          removed = s.uris -- uris

          operations =
            Enum.map(added, &{"resources/subscribe", &1}) ++
              Enum.map(removed, &{"resources/unsubscribe", &1})

          case operations do
            [] ->
              {:reply, :ok, s}

            [op | rest] ->
              {:noreply,
               legacy_subscribe(s, op, {:legacy_subscriptions, from, rest, uris}, timeout)}
          end
        end
      end
    end
  end

  def handle_call({:subscriptions, _, _}, _, s), do: {:reply, {:error, :not_connected}, s}
  @impl true
  def handle_info(:connect, s) do
    case Nano.MCP.Config.fetch(s.server) do
      {:ok, config} ->
        mod = if config["transport"] == "stdio", do: Nano.MCP.Stdio, else: Nano.MCP.HTTP

        case mod.start_link(self(), Map.put(config, "protocol_version", @modern)) do
          {:ok, pid} ->
            s = %{
              s
              | transport: pid,
                module: mod,
                phase: :discovering,
                version: @modern,
                stream: nil,
                acknowledged: false,
                generation: s.generation + 1,
                active_uris: MapSet.new(),
                restore_backoff: %{},
                listen_backoff: 250,
                restore_timeout: subscription_timeout(config)
            }

            {:noreply, rpc(s, "server/discover", %{}, :discover, 5000)}

          _ ->
            {:noreply, offline(s, :transport_start_failed)}
        end

      _ ->
        {:noreply, offline(s, :configuration_unavailable)}
    end
  end

  def handle_info(
        {:mcp_transport, pid, {:message, %{"jsonrpc" => "2.0"} = message}},
        %{transport: pid} = s
      ) do
    {:noreply, incoming(s, message)}
  end

  def handle_info({:mcp_transport, pid, {:down, _reason}}, %{transport: pid} = s),
    do: {:noreply, offline(s, :transport_down)}

  def handle_info({:EXIT, pid, _}, %{transport: pid} = s),
    do: {:noreply, offline(s, :transport_exit)}

  def handle_info({:timeout, id}, s) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        {:noreply, s}

      {pending, rest} ->
        s = %{s | pending: rest}
        notify(s, "notifications/cancelled", %{"requestId" => id, "reason" => "Request timeout"})
        {:noreply, complete(s, pending.kind, {:error, :timeout})}
    end
  end

  def handle_info({:send_failed, id, reason}, s) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        {:noreply, s}

      {p, rest} ->
        Process.cancel_timer(p.timer)
        {:noreply, complete(%{s | pending: rest}, p.kind, {:error, reason})}
    end
  end

  def handle_info({:await_timeout, ref}, s) do
    case Map.pop(s.waiters, ref) do
      {nil, _} ->
        {:noreply, s}

      {from, rest} ->
        GenServer.reply(from, {:error, :connection_timeout})
        {:noreply, %{s | waiters: rest}}
    end
  end

  def handle_info(
        {:relisten, generation},
        %{phase: :ready, version: @modern, stream: nil, generation: generation} = s
      ),
      do: {:noreply, listen(s, :listen, s.restore_timeout)}

  def handle_info({:restore_retry, generation, uri}, %{phase: :ready, generation: generation} = s) do
    pending? =
      Enum.any?(s.pending, fn {_, p} ->
        p.kind == {:restore, uri} or match?({:legacy_subscriptions, _, _, _}, p.kind)
      end)

    if s.version != @modern and uri in s.uris and not MapSet.member?(s.active_uris, uri) and
         not pending? do
      {:noreply,
       legacy_subscribe(s, {"resources/subscribe", uri}, {:restore, uri}, s.restore_timeout)}
    else
      {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s) do
    if s.transport && Process.alive?(s.transport), do: s.module.stop(s.transport)
    :ok
  end

  defp incoming(s, %{"params" => params}) when not is_map(params) do
    event(s, "protocol_error", %{"reason" => "params must be an object"})
    s
  end

  defp incoming(s, %{"method" => "ping", "id" => id}) do
    transmit(s, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
    s
  end

  defp incoming(s, %{"method" => method, "id" => id}) do
    transmit(s, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "Client capability not supported"}
    })

    event(s, "server_request_rejected", %{"method" => method})
    s
  end

  defp incoming(s, %{"method" => "notifications/subscriptions/acknowledged", "params" => params}) do
    id = meta_get(params, "io.modelcontextprotocol/subscriptionId")

    if id == s.stream do
      {pending, rest} = Map.pop(s.pending, id)
      if pending, do: Process.cancel_timer(pending.timer)
      s = %{s | pending: rest, acknowledged: true}
      event(s, "notifications/subscriptions/acknowledged", params)

      honored =
        case Map.get(params, "notifications") do
          %{"resourceSubscriptions" => uris} when is_list(uris) -> uris
          _ -> []
        end

      case pending && pending.kind do
        {:subscription, from, old} ->
          if Enum.all?(s.uris, &(&1 in honored)) do
            GenServer.reply(from, :ok)
            %{s | active_uris: MapSet.new(s.uris), listen_backoff: 250}
          else
            GenServer.reply(from, {:error, :subscription_not_honored})
            s = cancel_stream(s)
            Process.send_after(self(), {:relisten, s.generation}, 250)
            %{s | uris: old}
          end

        :listen ->
          missing = s.uris -- honored

          if missing == [],
            do: %{s | active_uris: MapSet.new(s.uris), listen_backoff: 250},
            else: listen_failed(s, "not_honored", missing)

        _ ->
          s
      end
    else
      s
    end
  end

  defp incoming(s, %{"method" => method} = msg) do
    params = Map.get(msg, "params", %{})
    sid = meta_get(params, "io.modelcontextprotocol/subscriptionId")

    subscription_event? =
      method in [
        "notifications/resources/updated",
        "notifications/tools/list_changed",
        "notifications/resources/list_changed",
        "notifications/prompts/list_changed"
      ]

    if s.version != @modern or not subscription_event? or (sid == s.stream and s.acknowledged) do
      event(s, method, params)

      case method do
        "notifications/tools/list_changed" ->
          refresh(s, "tools")

        "notifications/resources/list_changed" ->
          s
          |> refresh("resources")
          |> rpc("resources/templates/list", %{}, {:catalog, "resourceTemplates"}, 10000)

        "notifications/prompts/list_changed" ->
          refresh(s, "prompts")

        _ ->
          s
      end
    else
      s
    end
  end

  defp incoming(s, %{"id" => id} = message) do
    case Map.pop(s.pending, id) do
      {nil, _} when id == s.stream ->
        event(s, "subscription_closed", %{})
        listen_failed(s, "stream_closed", s.uris)

      {nil, _} ->
        s

      {pending, rest} ->
        Process.cancel_timer(pending.timer)

        result =
          if Map.has_key?(message, "error"),
            do: {:error, message["error"]},
            else: {:ok, message["result"]}

        complete(%{s | pending: rest}, pending.kind, result)
    end
  end

  defp incoming(s, _), do: s

  defp complete(
         s,
         :discover,
         {:ok, %{"supportedVersions" => versions, "capabilities" => caps} = result}
       )
       when is_list(versions) and is_map(caps) do
    if @modern in versions do
      ready(%{s | capabilities: Map.get(result, "capabilities", %{}), version: @modern})
    else
      fail_initialization(s, :unsupported_protocol_version)
    end
  end

  defp complete(s, :discover, {:error, %{"code" => code}})
       when code in [-32022, -32020, -32021] do
    # -32022 is modern version negotiation; the other recognized modern errors
    # do not establish that a legacy initialize handshake is appropriate.
    fail_initialization(s, :modern_discovery_rejected)
  end

  defp complete(s, :discover, {:ok, _}), do: fail_initialization(s, :invalid_discovery_response)

  defp complete(s, :discover, _) do
    set_protocol(s, hd(@legacy))

    rpc(
      %{s | phase: :initializing, version: hd(@legacy)},
      "initialize",
      %{"protocolVersion" => hd(@legacy), "capabilities" => %{}, "clientInfo" => client_info()},
      :initialize,
      10000
    )
  end

  defp complete(
         s,
         :initialize,
         {:ok, %{"protocolVersion" => version, "capabilities" => caps} = result}
       )
       when version in @legacy and is_map(caps) do
    set_protocol(s, version)
    s = %{s | version: version, capabilities: Map.get(result, "capabilities", %{})}
    notify(s, "notifications/initialized", %{})
    ready(s)
  end

  defp complete(s, :initialize, _), do: fail_initialization(s, :initialization_failed)

  defp complete(s, {:caller, from, method, first?}, {:ok, result}) do
    {s, result} =
      if method == "tools/list", do: accept_tools(s, result, first?), else: {s, result}

    bounded = Nano.MCP.Page.bound(result)
    GenServer.reply(from, {:ok, bounded})
    s
  end

  defp complete(s, {:caller, from, _, _}, {:error, reason}) do
    GenServer.reply(from, {:error, Nano.MCP.Page.bound(reason)})
    s
  end

  defp complete(s, {:catalog, "tools"}, {:ok, result}) do
    {s, result} = accept_tools(s, result, true)
    %{s | catalog: Map.put(s.catalog, "tools", result)}
  end

  defp complete(s, {:catalog, kind}, {:ok, result}),
    do: %{s | catalog: Map.put(s.catalog, kind, result)}

  defp complete(s, {:catalog, kind}, {:error, _}) do
    event(s, "catalog_error", %{"kind" => kind})
    s
  end

  defp complete(s, {:legacy_subscriptions, from, [], uris}, {:ok, _}) do
    GenServer.reply(from, :ok)
    %{s | uris: uris, active_uris: MapSet.new(uris), restore_backoff: %{}}
  end

  defp complete(s, {:legacy_subscriptions, from, [op | rest], uris}, {:ok, _}),
    do: legacy_subscribe(s, op, {:legacy_subscriptions, from, rest, uris}, 10000)

  defp complete(s, {:legacy_subscriptions, from, _, _}, {:error, _}) do
    GenServer.reply(from, {:error, :subscription_failed})
    offline(s, :subscription_failed)
  end

  defp complete(s, {:subscription, from, old}, _) do
    GenServer.reply(from, {:error, :subscription_failed})
    s = cancel_stream(s)
    Process.send_after(self(), {:relisten, s.generation}, 250)
    %{s | uris: old}
  end

  defp complete(s, {:restore, uri}, {:ok, _}) do
    if uri in s.uris do
      event(s, "subscription_restored", %{"uri" => uri})

      %{
        s
        | active_uris: MapSet.put(s.active_uris, uri),
          restore_backoff: Map.delete(s.restore_backoff, uri)
      }
    else
      s
    end
  end

  defp complete(s, {:restore, uri}, {:error, reason}) do
    if uri in s.uris do
      delay = Map.get(s.restore_backoff, uri, 250)

      event(s, "subscription_restore_failed", %{
        "uri" => uri,
        "reason" => failure_reason(reason),
        "retryMs" => delay
      })

      Process.send_after(self(), {:restore_retry, s.generation, uri}, delay)

      %{
        s
        | active_uris: MapSet.delete(s.active_uris, uri),
          restore_backoff: Map.put(s.restore_backoff, uri, min(delay * 2, 30000))
      }
    else
      s
    end
  end

  defp complete(s, :listen, result) do
    reason =
      case result do
        {:error, reason} -> failure_reason(reason)
        _ -> "closed_before_ack"
      end

    listen_failed(s, reason, s.uris)
  end

  defp complete(s, _, _), do: s

  defp ready(s) do
    Enum.each(s.waiters, fn {_, from} -> GenServer.reply(from, :ok) end)
    s = %{s | phase: :ready, waiters: %{}, retry: 250}
    event(s, "connected", %{"protocolVersion" => s.version})
    s = Enum.reduce(["tools", "resources", "prompts"], s, &refresh(&2, &1))

    s =
      if Map.has_key?(s.capabilities, "resources"),
        do: rpc(s, "resources/templates/list", %{}, {:catalog, "resourceTemplates"}, 10000),
        else: s

    if s.version == @modern do
      listen(s, :listen, s.restore_timeout)
    else
      Enum.reduce(s.uris, s, fn uri, acc ->
        legacy_subscribe(acc, {"resources/subscribe", uri}, {:restore, uri}, s.restore_timeout)
      end)
    end
  end

  defp subscription_timeout(config) do
    case Map.get(config, "subscription_timeout_ms", 10000) do
      n when is_integer(n) and n > 0 -> min(n, 120_000)
      _ -> 10000
    end
  end

  defp failure_reason(:timeout), do: "timeout"
  defp failure_reason(_), do: "server_error"

  defp listen_failed(s, reason, missing) do
    delay = s.listen_backoff

    event(s, "subscription_restore_failed", %{
      "uris" => missing,
      "reason" => reason,
      "retryMs" => delay
    })

    s = cancel_stream(s)
    Process.send_after(self(), {:relisten, s.generation}, delay)
    %{s | active_uris: MapSet.new(), listen_backoff: min(delay * 2, 30000)}
  end

  defp refresh(s, kind) do
    if Map.has_key?(s.capabilities, kind),
      do: rpc(s, kind <> "/list", %{}, {:catalog, kind}, 10000),
      else: s
  end

  defp listen(s, kind, timeout) do
    filters = %{"resourceSubscriptions" => s.uris}

    filters =
      Enum.reduce(
        [
          {"tools", "toolsListChanged"},
          {"resources", "resourcesListChanged"},
          {"prompts", "promptsListChanged"}
        ],
        filters,
        fn {cap, key}, acc ->
          if capability(s, cap, "listChanged") == true,
            do: Map.put(acc, key, true),
            else: acc
        end
      )

    id = s.next
    s = rpc(s, "subscriptions/listen", %{"notifications" => filters}, kind, timeout)
    %{s | stream: id, acknowledged: false}
  end

  defp cancel_stream(%{stream: nil} = s), do: s

  defp cancel_stream(s) do
    notify(s, "notifications/cancelled", %{
      "requestId" => s.stream,
      "reason" => "Subscription filter changed"
    })

    case Map.get(s.pending, s.stream) do
      nil ->
        :ok

      p ->
        Process.cancel_timer(p.timer)

        case p.kind do
          {:subscription, from, _} -> GenServer.reply(from, {:error, :subscription_superseded})
          _ -> :ok
        end
    end

    %{
      s
      | stream: nil,
        acknowledged: false,
        active_uris: MapSet.new(),
        pending: Map.delete(s.pending, s.stream)
    }
  end

  defp legacy_subscribe(s, {method, uri}, kind, timeout),
    do: rpc(s, method, %{"uri" => uri}, kind, timeout)

  defp capability(s, cap, field) do
    case s.capabilities[cap] do
      value when is_map(value) -> Map.get(value, field)
      _ -> nil
    end
  end

  defp meta_get(params, key) do
    case Map.get(params, "_meta") do
      value when is_map(value) -> Map.get(value, key)
      _ -> nil
    end
  end

  defp accept_tools(
         %{module: Nano.MCP.HTTP, version: @modern} = s,
         %{"tools" => tools} = result,
         first?
       )
       when is_list(tools) do
    valid =
      Enum.filter(tools, fn
        %{"name" => name, "inputSchema" => schema} when is_binary(name) ->
          match?({:ok, _}, Nano.MCP.ToolHeaders.extract(schema, %{}))

        _ ->
          false
      end)

    if length(valid) != length(tools),
      do: event(s, "tools_rejected", %{"count" => length(tools) - length(valid)})

    page_schemas =
      Map.new(Enum.take(valid, 10000), fn tool -> {tool["name"], tool["inputSchema"]} end)

    schemas = Map.merge(if(first?, do: %{}, else: s.tool_schemas), page_schemas)

    schemas =
      if map_size(schemas) > 10000 or byte_size(Jason.encode!(schemas)) > 4 * 1024 * 1024,
        do: page_schemas,
        else: schemas

    {%{s | tool_schemas: schemas}, Map.put(result, "tools", valid)}
  end

  defp accept_tools(s, result, _), do: {s, result}

  defp request_headers(%{module: Nano.MCP.HTTP, version: @modern} = s, "tools/call", params) do
    case Map.fetch(s.tool_schemas, params["name"]) do
      {:ok, schema} -> Nano.MCP.ToolHeaders.extract(schema, Map.get(params, "arguments", %{}))
      :error -> {:error, :tool_not_discovered_or_rejected}
    end
  end

  defp request_headers(_, _, _), do: {:ok, %{}}

  defp request_fits?(params) do
    case Jason.encode(params) do
      {:ok, bytes} -> byte_size(bytes) <= 4 * 1024 * 1024 - 2048
      _ -> false
    end
  end

  defp client_info, do: %{"name" => "nano", "version" => "0.1.0"}

  defp params(s, params) do
    if s.version == @modern do
      meta =
        Map.merge(Map.get(params, "_meta", %{}), %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientInfo" => client_info(),
          "io.modelcontextprotocol/clientCapabilities" => %{}
        })

      Map.put(params, "_meta", meta)
    else
      params
    end
  end

  defp rpc(s, method, p, kind, timeout, headers \\ %{}) do
    id = s.next
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params(s, p)}
    timer = Process.send_after(self(), {:timeout, id}, timeout)
    transmit(s, message, headers)
    %{s | next: id + 1, pending: Map.put(s.pending, id, %{kind: kind, timer: timer})}
  end

  defp notify(s, method, p),
    do: transmit(s, %{"jsonrpc" => "2.0", "method" => method, "params" => p})

  defp transmit(s, message, headers \\ %{}) do
    try do
      result =
        if s.module == Nano.MCP.HTTP,
          do: s.module.send_message(s.transport, message, headers),
          else: s.module.send_message(s.transport, message)

      case result do
        {:error, reason} -> send(self(), {:send_failed, message["id"], reason})
        _ -> :ok
      end
    catch
      :exit, _ -> send(self(), {:mcp_transport, s.transport, {:down, :send_failed}})
    end
  end

  defp set_protocol(%{module: Nano.MCP.HTTP} = s, version),
    do: Nano.MCP.HTTP.set_protocol(s.transport, version)

  defp set_protocol(_, _), do: :ok

  defp fail_initialization(s, reason) do
    Enum.each(s.waiters, fn {_, from} -> GenServer.reply(from, {:error, reason}) end)
    offline(%{s | waiters: %{}}, reason)
  end

  defp offline(s, reason) do
    if s.transport && Process.alive?(s.transport) do
      try do
        s.module.stop(s.transport)
      catch
        :exit, _ -> :ok
      end
    end

    Enum.each(s.pending, fn {_, p} ->
      Process.cancel_timer(p.timer)

      case p.kind do
        {:caller, from, _, _} -> GenServer.reply(from, {:error, :connection_lost})
        {:subscription, from, _} -> GenServer.reply(from, {:error, :connection_lost})
        {:legacy_subscriptions, from, _, _} -> GenServer.reply(from, {:error, :connection_lost})
        _ -> :ok
      end
    end)

    event(s, "disconnected", %{"reason" => to_string(reason), "retryMs" => s.retry})
    Process.send_after(self(), :connect, s.retry)

    %{
      s
      | transport: nil,
        phase: :offline,
        active_uris: MapSet.new(),
        pending: %{},
        stream: nil,
        acknowledged: false,
        retry: min(s.retry * 2, 30000)
    }
  end

  defp event(s, method, params), do: Nano.MCP.Manager.event(s.agent, s.server, method, params)
end

defmodule MCP.Connection do
  @moduledoc false
  use GenServer
  @modern "2026-07-28"
  @legacy ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

  def start(config, owner, name, uris),
    do: GenServer.start(__MODULE__, {config, owner, name, uris})

  def request(pid, method, params, timeout),
    do: GenServer.call(pid, {:request, method, params, timeout}, timeout + 1000)

  def status(pid), do: GenServer.call(pid, :status)
  def subscriptions(pid, uris), do: GenServer.cast(pid, {:subscriptions, uris})

  def init({config, owner, name, uris}) do
    Process.monitor(owner)
    send(self(), :connect)

    {:ok,
     %{
       config: config,
       owner: owner,
       name: name,
       uris: uris,
       subscribed: [],
       transport: nil,
       monitor: nil,
       module: if(config["transport"] == "http", do: MCP.HTTP, else: MCP.Stdio),
       ready: false,
       info: nil,
       version: config["protocol_version"] || @modern,
       pending: %{},
       id: 0,
       retry: 250,
       reconnect_timer: nil,
       stream: nil
     }}
  end

  def handle_call(:status, _, s),
    do: {:reply, %{ready: s.ready, info: s.info, protocol_version: s.version}, s}

  def handle_call({:request, _, _, _}, _, %{ready: false} = s),
    do: {:reply, {:error, :not_ready}, s}

  def handle_call({:request, method, params, timeout}, from, s) do
    if map_size(s.pending) >= 128 do
      {:reply, {:error, :too_many_pending_requests}, s}
    else
      {:noreply, issue(s, method, params, {:caller, from}, timeout)}
    end
  end

  def handle_cast({:subscriptions, uris}, s) do
    s = %{s | uris: uris}
    {:noreply, if(s.ready, do: subscribe(s), else: s)}
  end

  def handle_info(:connect, s) do
    s = %{s | reconnect_timer: nil}

    case s.module.start(s.config, self()) do
      {:ok, pid} ->
        s = %{s | transport: pid, monitor: Process.monitor(pid)}

        if modern?(s) do
          {:noreply, issue(s, "server/discover", %{}, :discover, timeout(s))}
        else
          {:noreply, initialize(s)}
        end

      {:error, reason} ->
        {:noreply, disconnect(s, reason)}
    end
  end

  def handle_info(
        {:mcp_transport, pid, {:message, %{"jsonrpc" => "2.0"} = message}},
        %{transport: pid} = s
      ) do
    {:noreply, incoming(message, s)}
  end

  def handle_info({:mcp_transport, pid, {:message, _}}, %{transport: pid} = s),
    do: {:noreply, disconnect(s, :invalid_jsonrpc)}

  def handle_info({:mcp_transport, pid, {:down, reason}}, %{transport: pid} = s),
    do: {:noreply, disconnect(s, reason)}

  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = s), do: {:stop, :normal, s}

  def handle_info({:DOWN, ref, :process, _, reason}, %{monitor: ref} = s),
    do: {:noreply, disconnect(s, reason)}

  def handle_info({:timeout, id}, s) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        {:noreply, s}

      {p, rest} ->
        s = %{s | pending: rest}
        notify(s, "notifications/cancelled", %{"requestId" => id, "reason" => "Client timeout"})
        {:noreply, finish(p.kind, {:error, :timeout}, s)}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  def terminate(_, s), do: close(s)

  defp initialize(s) do
    issue(
      s,
      "initialize",
      %{
        "protocolVersion" => s.version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "nano-mcp", "version" => "1.0.0"}
      },
      :initialize,
      timeout(s)
    )
  end

  defp issue(s, method, params, kind, timeout) do
    id = s.id + 1

    params =
      if modern?(s),
        do: Map.update(params, "_meta", metadata(s), &Map.merge(&1, metadata(s))),
        else: params

    s.module.send_message(s.transport, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })

    timer = Process.send_after(self(), {:timeout, id}, timeout)
    %{s | id: id, pending: Map.put(s.pending, id, %{kind: kind, timer: timer})}
  end

  defp incoming(%{"method" => method, "id" => id}, s) do
    # Modern servers must not send requests; legacy clients explicitly decline unadvertised features.
    if not modern?(s) do
      reply =
        if method == "ping",
          do: %{"result" => %{}},
          else: %{"error" => %{"code" => -32601, "message" => "Client capability not supported"}}

      s.module.send_message(s.transport, Map.merge(reply, %{"jsonrpc" => "2.0", "id" => id}))
      s
    else
      disconnect(s, :unexpected_server_request)
    end
  end

  defp incoming(%{"method" => method} = message, s) do
    params = message["params"] || %{}
    sub_id = get_in(params, ["_meta", "io.modelcontextprotocol/subscriptionId"])

    cond do
      method == "notifications/subscriptions/acknowledged" and sub_id == s.stream ->
        {p, rest} = Map.pop(s.pending, sub_id)
        if p, do: Process.cancel_timer(p.timer)
        event(s, method, params)
        %{s | pending: rest}

      modern?(s) and String.starts_with?(method, "notifications/resources/") and
          sub_id != s.stream ->
        s

      modern?(s) and String.ends_with?(method, "/list_changed") and sub_id != s.stream ->
        s

      true ->
        event(s, method, params)
        s
    end
  end

  defp incoming(%{"id" => id} = message, s) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        if id == s.stream, do: disconnect(s, :subscription_stream_closed), else: s

      {p, rest} ->
        Process.cancel_timer(p.timer)

        result =
          cond do
            Map.has_key?(message, "error") ->
              {:error, {:rpc, message["error"]}}

            is_map(message["result"]) ->
              case message["result"]["resultType"] do
                type when type in [nil, "complete"] -> {:ok, message["result"]}
                "input_required" -> {:error, {:input_required, message["result"]}}
                other -> {:error, {:unknown_result_type, other}}
              end

            true ->
              {:error, :invalid_response}
          end

        finish(p.kind, result, %{s | pending: rest})
    end
  end

  defp incoming(_, s), do: disconnect(s, :invalid_message)

  defp finish({:caller, from}, result, s) do
    GenServer.reply(from, result)
    s
  end

  defp finish(:discover, {:ok, info}, s) do
    if @modern in (info["supportedVersions"] || []) do
      ready(s, info)
    else
      disconnect(s, {:unsupported_versions, info["supportedVersions"]})
    end
  end

  defp finish(:discover, {:error, {:rpc, %{"code" => -32022} = error}}, s),
    do: disconnect(s, {:unsupported_version, error})

  defp finish(:discover, {:error, _} = error, s) do
    if s.config["protocol_version"] in [nil, "auto"] and s.config["transport"] == "stdio" do
      event(s, "client/legacy_fallback", %{reason: inspect(error)})
      initialize(%{s | version: hd(@legacy)})
    else
      disconnect(s, error)
    end
  end

  defp finish(:initialize, {:ok, info}, s) do
    if info["protocolVersion"] in @legacy do
      s = %{s | version: info["protocolVersion"]}
      notify(s, "notifications/initialized", %{})
      ready(s, info)
    else
      disconnect(s, {:unsupported_version, info["protocolVersion"]})
    end
  end

  defp finish(:initialize, error, s), do: disconnect(s, error)
  defp finish(:stream, result, s), do: disconnect(s, {:subscription_failed, result})

  defp finish({:subscribe, uri}, result, s) do
    event(s, "client/subscription", %{uri: uri, result: result})
    s
  end

  defp finish(:unsubscribe, _, s), do: s

  defp ready(s, info) do
    event(s, "client/connected", %{
      protocol_version: s.version,
      capabilities: info["capabilities"] || %{}
    })

    subscribe(%{s | ready: true, info: info, retry: 250})
  end

  defp subscribe(s) do
    if modern?(s) do
      s = cancel_stream(s)

      filters = %{
        "toolsListChanged" => true,
        "promptsListChanged" => true,
        "resourcesListChanged" => true,
        "resourceSubscriptions" => s.uris
      }

      s = issue(s, "subscriptions/listen", %{"notifications" => filters}, :stream, timeout(s))
      %{s | stream: s.id, subscribed: s.uris}
    else
      supported = get_in(s.info, ["capabilities", "resources", "subscribe"]) == true

      s =
        Enum.reduce(s.subscribed -- s.uris, s, fn uri, s ->
          issue(s, "resources/unsubscribe", %{"uri" => uri}, :unsubscribe, timeout(s))
        end)

      s =
        Enum.reduce(s.uris -- s.subscribed, s, fn uri, s ->
          if supported do
            issue(s, "resources/subscribe", %{"uri" => uri}, {:subscribe, uri}, timeout(s))
          else
            event(s, "client/subscription", %{uri: uri, result: {:error, :not_supported}})
            s
          end
        end)

      %{s | subscribed: s.uris}
    end
  end

  defp cancel_stream(%{stream: nil} = s), do: s

  defp cancel_stream(s) do
    notify(s, "notifications/cancelled", %{
      "requestId" => s.stream,
      "reason" => "Subscription filter changed"
    })

    {p, pending} = Map.pop(s.pending, s.stream)
    if p, do: Process.cancel_timer(p.timer)
    %{s | stream: nil, pending: pending}
  end

  defp disconnect(s, reason) do
    close(s)

    for {_id, p} <- s.pending do
      Process.cancel_timer(p.timer)

      case p.kind do
        {:caller, from} -> GenServer.reply(from, {:error, {:disconnected, reason}})
        _ -> :ok
      end
    end

    event(s, "client/disconnected", %{reason: inspect(reason, limit: 20), retry_ms: s.retry})
    timer = s.reconnect_timer || Process.send_after(self(), :connect, s.retry)

    %{
      s
      | ready: false,
        info: nil,
        pending: %{},
        transport: nil,
        monitor: nil,
        stream: nil,
        subscribed: [],
        reconnect_timer: timer,
        retry: min(s.retry * 2, 30_000)
    }
  end

  defp close(s) do
    if s.monitor, do: Process.demonitor(s.monitor, [:flush])

    if s.transport && Process.alive?(s.transport) do
      try do
        s.module.close(s.transport)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp notify(s, method, params),
    do:
      s.module.send_message(s.transport, %{
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params
      })

  defp event(s, method, params), do: send(s.owner, {:mcp_event, s.name, method, params})
  defp modern?(s), do: s.version in [@modern, "auto"]
  defp timeout(s), do: s.config["timeout_ms"] || 15_000

  defp metadata(s),
    do: %{
      "io.modelcontextprotocol/protocolVersion" =>
        if(s.version == "auto", do: @modern, else: s.version),
      "io.modelcontextprotocol/clientInfo" => %{"name" => "nano-mcp", "version" => "1.0.0"},
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }
end

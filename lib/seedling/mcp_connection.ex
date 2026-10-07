defmodule Seedling.MCP.Connection do
  @moduledoc false
  use GenServer
  @modern "2026-07-28"
  @legacy ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  def start_link(name, config, manager),
    do: GenServer.start_link(__MODULE__, {name, config, manager})

  def await(pid, timeout), do: GenServer.call(pid, {:await, timeout}, timeout + 1000)

  def request(pid, method, params, timeout),
    do: GenServer.call(pid, {:request, method, params, timeout}, timeout + 1000)

  def subscriptions(pid, uris), do: GenServer.cast(pid, {:subscriptions, uris})

  def init({name, config, manager}) do
    Process.flag(:trap_exit, true)

    s = %{
      name: name,
      config: config,
      manager: manager,
      transport: nil,
      module: nil,
      status: :connecting,
      pending: %{},
      next: 1,
      version: @modern,
      info: %{},
      waiters: [],
      subscriptions: [],
      active: [],
      stream: nil,
      retry: 1000
    }

    send(self(), :connect)
    {:ok, s}
  end

  def handle_call({:await, _timeout}, _from, %{status: :ready} = s),
    do: {:reply, {:ok, s.info}, s}

  def handle_call({:await, timeout}, from, s) do
    Process.send_after(self(), {:await_timeout, from}, timeout)
    {:noreply, %{s | waiters: [from | s.waiters]}}
  end

  def handle_call({:request, "__info", _, _}, _, s),
    do:
      {:reply,
       {:ok,
        Map.merge(s.info, %{"status" => to_string(s.status), "protocolVersion" => s.version})}, s}

  def handle_call({:request, method, params, timeout}, from, %{status: :ready} = s) do
    {:noreply, issue(s, method, params, {:caller, from}, timeout)}
  end

  def handle_call({:request, _, _, _}, _, s), do: {:reply, {:error, :not_ready}, s}

  def handle_cast({:subscriptions, uris}, s) do
    {:noreply, reconcile(%{s | subscriptions: Enum.sort(uris)})}
  end

  def handle_info(:connect, s) do
    module = if s.config["url"], do: Seedling.MCP.HTTP, else: Seedling.MCP.Stdio

    case module.start_link(s.config, self()) do
      {:ok, pid} ->
        s = %{s | transport: pid, module: module, version: @modern, status: :discovering}
        {:noreply, issue(s, "server/discover", %{}, :discover, 3000)}

      {:error, reason} ->
        {:noreply, down(s, reason)}
    end
  end

  def handle_info({:mcp_message, pid, %{"id" => id} = message}, %{transport: pid} = s) do
    if Map.has_key?(message, "method") do
      handle_server_request(message, s)
      {:noreply, s}
    else
      case Map.pop(s.pending, id) do
        {nil, _} ->
          if id == s.stream, do: event(s, "subscription/closed", message)
          {:noreply, s}

        {{tag, timer, method}, pending} ->
          Process.cancel_timer(timer)

          result =
            if Map.has_key?(message, "error"),
              do: {:error, message["error"]},
              else: {:ok, Map.get(message, "result", %{})}

          {:noreply, completed(%{s | pending: pending}, tag, inventory_result(s, method, result))}
      end
    end
  end

  def handle_info({:mcp_message, pid, %{"method" => method} = m}, %{transport: pid} = s) do
    params = Map.get(m, "params", %{})
    event(s, method, params)
    {:noreply, s}
  end

  def handle_info({:mcp_transport_down, pid, reason}, %{transport: pid} = s),
    do: {:noreply, down(s, reason)}

  def handle_info({:mcp_transport_warning, pid, reason}, %{transport: pid} = s) do
    event(s, "connection/warning", %{reason: inspect(reason)})
    {:noreply, s}
  end

  def handle_info({:EXIT, pid, reason}, %{transport: pid} = s), do: {:noreply, down(s, reason)}

  def handle_info({:timeout, id}, s) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        {:noreply, s}

      {{tag, _, _}, pending} ->
        notify(s, "notifications/cancelled", %{"requestId" => id, "reason" => "client timeout"})
        {:noreply, completed(%{s | pending: pending}, tag, {:error, :timeout})}
    end
  end

  def handle_info({:await_timeout, from}, s) do
    if from in s.waiters, do: GenServer.reply(from, {:error, :connection_timeout})
    {:noreply, %{s | waiters: List.delete(s.waiters, from)}}
  end

  def handle_info({:EXIT, pid, reason}, %{manager: pid} = s), do: {:stop, reason, s}
  def handle_info(_, s), do: {:noreply, s}

  defp inventory_result(
         %{module: Seedling.MCP.HTTP} = s,
         "tools/list",
         {:ok, %{"tools" => tools} = data}
       ) do
    validated = Seedling.MCP.HTTP.register_tools(s.transport, tools)
    {:ok, Map.put(data, "tools", validated)}
  end

  defp inventory_result(_, _, result), do: result

  defp completed(s, {:caller, from}, result) do
    GenServer.reply(from, result)
    s
  end

  defp completed(s, :discover, {:ok, %{"supportedVersions" => versions} = info}) do
    if @modern in versions,
      do: ready(%{s | info: info, version: @modern}),
      else: down(s, {:unsupported_versions, versions})
  end

  defp completed(s, :discover, {:error, %{"code" => -32022, "data" => data}}) do
    # Modern server: never accidentally initialize an unsupported modern era.
    down(s, {:unsupported_versions, data})
  end

  defp completed(s, :discover, _) do
    s = %{s | version: hd(@legacy), status: :initializing}
    s.module.set_version(s.transport, s.version)

    issue(
      s,
      "initialize",
      %{
        "protocolVersion" => s.version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "seedling", "version" => "1.0.0"}
      },
      :initialize,
      10000
    )
  end

  defp completed(s, :initialize, {:ok, %{"protocolVersion" => v} = info}) when v in @legacy do
    s = %{s | version: v, info: info}
    s.module.set_version(s.transport, v)
    notify(s, "notifications/initialized", %{})
    ready(s)
  end

  defp completed(s, :initialize, result), do: down(s, {:initialization_failed, result})

  defp completed(s, {:subscription, uri, op}, result) do
    event(s, "subscription/result", %{
      "uri" => uri,
      "operation" => op,
      "result" => inspect(result)
    })

    s
  end

  defp ready(s) do
    Enum.each(s.waiters, &GenServer.reply(&1, {:ok, s.info}))
    send(s.manager, {:mcp_ready, s.name})
    reconcile(%{s | status: :ready, waiters: [], retry: 1000})
  end

  defp issue(s, method, params, tag, timeout) do
    id = s.next

    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => metadata(s, params)
    }

    case transmit(s, message) do
      :ok ->
        timer = Process.send_after(self(), {:timeout, id}, timeout)
        %{s | next: id + 1, pending: Map.put(s.pending, id, {tag, timer, method})}

      {:error, reason} ->
        completed(s, tag, {:error, reason})
    end
  end

  defp metadata(%{version: @modern}, params) do
    meta =
      Map.merge(Map.get(params, "_meta", %{}), %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientInfo" => %{"name" => "seedling", "version" => "1.0.0"},
        "io.modelcontextprotocol/clientCapabilities" => %{}
      })

    Map.put(params, "_meta", meta)
  end

  defp metadata(_, params), do: params

  defp notify(s, method, params),
    do: transmit(s, %{"jsonrpc" => "2.0", "method" => method, "params" => params})

  defp transmit(%{transport: nil}, _), do: {:error, :disconnected}

  defp transmit(s, m) do
    s.module.send_message(s.transport, m)
  catch
    :exit, reason -> {:error, reason}
  end

  defp reconcile(%{status: :ready, version: @modern} = s) do
    if s.active == s.subscriptions and s.stream != nil do
      s
    else
      if s.stream, do: notify(s, "notifications/cancelled", %{"requestId" => s.stream})
      id = s.next

      params = %{
        "notifications" => %{
          "toolsListChanged" => true,
          "promptsListChanged" => true,
          "resourcesListChanged" => true,
          "resourceSubscriptions" => s.subscriptions
        }
      }

      transmit(s, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "subscriptions/listen",
        "params" => metadata(s, params)
      })

      %{s | stream: id, next: id + 1, active: s.subscriptions}
    end
  end

  defp reconcile(%{status: :ready} = s) do
    added = s.subscriptions -- s.active
    removed = s.active -- s.subscriptions

    s =
      Enum.reduce(added, s, fn uri, acc ->
        issue(
          acc,
          "resources/subscribe",
          %{"uri" => uri},
          {:subscription, uri, "subscribe"},
          10000
        )
      end)

    s =
      Enum.reduce(removed, s, fn uri, acc ->
        issue(
          acc,
          "resources/unsubscribe",
          %{"uri" => uri},
          {:subscription, uri, "unsubscribe"},
          10000
        )
      end)

    %{s | active: s.subscriptions}
  end

  defp reconcile(s), do: s

  defp handle_server_request(%{"id" => id, "method" => "ping"}, s),
    do: transmit(s, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})

  defp handle_server_request(%{"id" => id, "method" => method}, s) do
    event(s, "server/request_rejected", %{"method" => method})

    transmit(s, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "Client capability not supported"}
    })
  end

  defp down(s, reason) do
    event(s, "connection/down", %{reason: inspect(reason), retry_ms: s.retry})

    Enum.each(s.pending, fn {_, {tag, timer, _}} ->
      Process.cancel_timer(timer)

      case tag do
        {:caller, from} -> GenServer.reply(from, {:error, {:disconnected, reason}})
        _ -> :ok
      end
    end)

    if s.transport && Process.alive?(s.transport) do
      try do
        s.module.close(s.transport)
      catch
        :exit, _ -> :ok
      end
    end

    Process.send_after(self(), :connect, s.retry)

    %{
      s
      | transport: nil,
        pending: %{},
        status: :disconnected,
        active: [],
        stream: nil,
        retry: min(s.retry * 2, 30000)
    }
  end

  defp event(s, method, params), do: send(s.manager, {:mcp_event, s.name, method, params})

  def terminate(_, s) do
    if s.transport && Process.alive?(s.transport), do: s.module.close(s.transport)
    :ok
  end
end

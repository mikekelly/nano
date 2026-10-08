defmodule Seedling.MCP.Client do
  @moduledoc false
  use GenServer
  alias Seedling.MCP.{Config, HTTP, Schema, OSProcess}
  @modern "2026-07-28"
  @legacy ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  @max_wire 8_388_608
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    s =
      Map.merge(opts, %{
        port: nil,
        buffer: "",
        pending: %{},
        workers: %{},
        counter: 0,
        status: :connecting,
        era: :modern,
        version: @modern,
        info: %{},
        session: nil,
        waiters: [],
        backoff: 100,
        subscribed: [],
        listen: nil,
        listener_ack: false,
        last_event_id: nil,
        retry: 500,
        tools: %{}
      })

    {:ok, s, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, s), do: {:noreply, open(s)}
  @impl true
  def handle_call(:await, from, s) do
    if s.status == :ready,
      do: {:reply, {:ok, info(s)}, s},
      else: {:noreply, %{s | waiters: [from | s.waiters]}}
  end

  def handle_call(:status, _, s), do: {:reply, {:ok, info(s)}, s}

  def handle_call({:request, method, params, timeout}, from, s) do
    if s.status == :ready and map_size(s.pending) < 128 do
      validation =
        if method == "tools/call" and s.era == :modern and is_nil(s.port) and
             s.tools[params["name"]],
           do: Schema.headers(s.tools[params["name"]], params["arguments"] || %{}),
           else: {:ok, %{}}

      case validation do
        {:ok, _} ->
          emit(s, %{type: :request, method: method, target: params["name"] || params["uri"]})
          {:noreply, rpc(s, method, params, {:external, from, method}, timeout)}

        error ->
          {:reply, error, s}
      end
    else
      {:reply,
       {:error, if(s.status == :ready, do: :too_many_requests, else: {:not_ready, s.status})}, s}
    end
  end

  @impl true
  def handle_cast({:subscriptions, uris}, s) do
    s = %{s | uris: uris}
    {:noreply, if(s.status == :ready, do: restore_subscriptions(s), else: s)}
  end

  @impl true
  def handle_info(:reconnect, s), do: {:noreply, open(s)}

  def handle_info(:listen_again, s) do
    {:noreply, if(s.status == :ready and s.listen == nil, do: start_listen(s), else: s)}
  end

  def handle_info({port, {:data, chunk}}, %{port: port} = s) do
    buffer = s.buffer <> chunk

    if byte_size(buffer) > @max_wire do
      {:noreply, disconnected(s, :wire_limit)}
    else
      lines = String.split(buffer, "\n")
      s = %{s | buffer: List.last(lines)}
      {:noreply, Enum.reduce(Enum.drop(lines, -1), s, &decode(&2, &1))}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = s),
    do: {:noreply, disconnected(s, {:exit_status, status})}

  def handle_info({:EXIT, port, reason}, %{port: port} = s) when is_port(port),
    do: {:noreply, disconnected(s, reason)}

  def handle_info({:http_headers, token, status, headers}, s) do
    case s.workers[token] do
      nil ->
        {:noreply, s}

      worker ->
        s =
          if headers["mcp-session-id"], do: %{s | session: hd(headers["mcp-session-id"])}, else: s

        worker =
          Map.merge(worker, %{
            status: status,
            sse:
              String.starts_with?(
                List.first(headers["content-type"] || [""]),
                "text/event-stream"
              )
          })

        s = put_in(s.workers[token], worker)

        if status == 404 and s.era == :legacy and s.session != nil do
          {:noreply, disconnected(s, :session_expired)}
        else
          {:noreply, s}
        end
    end
  end

  def handle_info({:http_data, token, chunk}, s) do
    case s.workers[token] do
      nil ->
        {:noreply, s}

      worker ->
        buffer = worker.buffer <> chunk

        if byte_size(buffer) > @max_wire do
          {:noreply, disconnected(s, :wire_limit)}
        else
          if worker.sse do
            # SSE line endings may straddle chunks. Split on blank lines, not data chunks.
            blocks = Regex.split(~r/\r?\n\r?\n/, buffer)
            s = put_in(s.workers[token].buffer, List.last(blocks))

            {:noreply,
             Enum.reduce(Enum.drop(blocks, -1), s, fn block, s -> sse(s, token, block) end)}
          else
            {:noreply, put_in(s.workers[token].buffer, buffer)}
          end
        end
    end
  end

  def handle_info({:http_done, token, result}, s) do
    case s.workers[token] do
      nil ->
        {:noreply, s}

      worker ->
        s = %{s | workers: Map.delete(s.workers, token)}
        s = if not worker.sse and worker.buffer != "", do: decode(s, worker.buffer), else: s

        cond do
          token == :initialized ->
            {:noreply,
             if(worker.status == 202,
               do: ready(s, s.info),
               else: disconnected(s, :initialized_rejected)
             )}

          token == :get ->
            if worker.status != 405 and s.status == :ready,
              do: Process.send_after(self(), :listen_again, s.retry)

            {:noreply, %{s | listen: nil}}

          token == s.listen ->
            emit(s, %{type: :subscription_closed, reason: inspect(result)})
            Process.send_after(self(), :listen_again, s.retry)
            {:noreply, %{s | listen: nil, listener_ack: false}}

          Map.has_key?(s.pending, token) ->
            if s.pending[token].kind == :discover and worker.status in [400, 404, 405] do
              {:noreply, fallback(remove_pending(s, token))}
            else
              {:noreply, fail_request(s, token, {:transport, worker.status, result})}
            end

          result != :ok ->
            emit(s, %{type: :transport_error, reason: inspect(result)})
            {:noreply, s}

          true ->
            {:noreply, s}
        end
    end
  end

  def handle_info({:timeout, id}, s) do
    if Map.has_key?(s.pending, id) do
      kind = s.pending[id].kind
      s = cancel(s, id)

      cond do
        kind == :discover -> {:noreply, fallback(remove_pending(s, id))}
        kind == :initialize -> {:noreply, disconnected(s, :initialization_timeout)}
        true -> {:noreply, fail_request(s, id, :timeout)}
      end
    else
      {:noreply, s}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, s) do
    case Enum.find(s.workers, fn {_, worker} -> worker.ref == ref end) do
      {token, _} when reason != :normal ->
        handle_info({:http_done, token, {:error, inspect(reason)}}, s)

      _ ->
        {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}
  @impl true
  def terminate(_, s), do: close(s)

  defp open(s) do
    emit(s, %{type: :connecting})

    s = %{
      s
      | status: :connecting,
        era: :modern,
        version: @modern,
        session: nil,
        buffer: "",
        subscribed: [],
        listen: nil,
        listener_ack: false
    }

    try do
      {:ok, env} = Config.secrets(s.config["env"])
      {:ok, _} = Config.secrets(s.config["headers"])

      s =
        if s.config["transport"] == "stdio" do
          port_opts = [
            :binary,
            :exit_status,
            :use_stdio,
            :hide,
            {:args, s.config["args"] || []},
            {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}
          ]

          port_opts =
            if s.config["cwd"], do: [{:cd, s.config["cwd"]} | port_opts], else: port_opts

          port = Port.open({:spawn_executable, s.config["command"]}, port_opts)

          case OSProcess.watch(port, self()) do
            {:ok, _watchdog} ->
              %{s | port: port}

            {:error, reason} ->
              Port.close(port)
              raise "Cannot supervise stdio OS identity: #{inspect(reason)}"
          end
        else
          s
        end

      if s.config["protocol"] == "legacy",
        do: fallback(s),
        else: rpc(s, "server/discover", %{}, :discover, s.config["probe_timeout_ms"] || 1500)
    rescue
      error -> disconnected(s, Exception.message(error))
    end
  end

  defp fallback(s) do
    s = %{s | era: :legacy, version: hd(@legacy)}

    rpc(
      s,
      "initialize",
      %{
        "protocolVersion" => hd(@legacy),
        "capabilities" => %{},
        "clientInfo" => %{"name" => "seedling", "version" => "0.1.0"}
      },
      :initialize,
      10_000
    )
  end

  defp ready(s, result) do
    s = %{s | status: :ready, info: result, backoff: 100}
    Enum.each(s.waiters, &GenServer.reply(&1, {:ok, info(s)}))

    emit(s, %{
      type: :connected,
      protocol: s.version,
      era: s.era,
      capabilities: result["capabilities"] || %{}
    })

    restore_subscriptions(%{s | waiters: []})
  end

  defp restore_subscriptions(%{era: :modern} = s) do
    s = if s.listen, do: cancel(s, s.listen) |> remove_pending(s.listen), else: s
    start_listen(%{s | listen: nil, listener_ack: false})
  end

  defp restore_subscriptions(s) do
    s =
      Enum.reduce(s.subscribed -- s.uris, s, fn uri, s ->
        rpc(s, "resources/unsubscribe", %{"uri" => uri}, {:unsubscribe, uri}, 10_000)
      end)

    s =
      Enum.reduce(s.uris -- s.subscribed, s, fn uri, s ->
        rpc(s, "resources/subscribe", %{"uri" => uri}, {:subscribe, uri}, 10_000)
      end)

    if s.config["transport"] != "stdio" and s.listen == nil, do: start_listen(s), else: s
  end

  defp start_listen(%{era: :modern} = s) do
    caps = s.info["capabilities"] || %{}

    notifications = %{
      "resourceSubscriptions" => s.uris,
      "toolsListChanged" => !!get_in(caps, ["tools", "listChanged"]),
      "resourcesListChanged" => !!get_in(caps, ["resources", "listChanged"]),
      "promptsListChanged" => !!get_in(caps, ["prompts", "listChanged"])
    }

    s = rpc(s, "subscriptions/listen", %{"notifications" => notifications}, :listen, :infinity)
    %{s | listen: s.counter}
  end

  defp start_listen(s) do
    headers = headers(s, nil) |> Map.put("accept", "text/event-stream")

    headers =
      if s.last_event_id, do: Map.put(headers, "last-event-id", s.last_event_id), else: headers

    {pid, ref} = HTTP.start(self(), :get, s.config, :get, nil, headers)
    %{s | listen: :get, workers: Map.put(s.workers, :get, worker(pid, ref))}
  end

  defp rpc(s, method, params, kind, timeout) do
    id = s.counter + 1
    timer = if timeout != :infinity, do: Process.send_after(self(), {:timeout, id}, timeout)
    pending = %{kind: kind, timer: timer, method: method}

    params =
      if s.era == :modern do
        meta =
          Map.merge(params["_meta"] || %{}, %{
            "io.modelcontextprotocol/protocolVersion" => s.version,
            "io.modelcontextprotocol/clientInfo" => %{"name" => "seedling", "version" => "0.1.0"},
            "io.modelcontextprotocol/clientCapabilities" => %{}
          })

        Map.put(params, "_meta", meta)
      else
        params
      end

    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    s = %{s | counter: id, pending: Map.put(s.pending, id, pending)}
    transmit(s, id, message)
  end

  defp transmit(%{port: port} = s, _, message) when is_port(port) do
    Port.command(port, Jason.encode!(message) <> "\n")
    s
  end

  defp transmit(s, token, message) do
    {pid, ref} =
      HTTP.start(self(), token, s.config, :post, Jason.encode!(message), headers(s, message))

    %{s | workers: Map.put(s.workers, token, worker(pid, ref))}
  end

  defp headers(s, message) do
    {:ok, configured} = Config.secrets(s.config["headers"])

    headers =
      Map.merge(configured, %{
        "accept" => "application/json, text/event-stream",
        "content-type" => "application/json",
        "mcp-protocol-version" => s.version
      })

    headers = if s.session, do: Map.put(headers, "mcp-session-id", s.session), else: headers

    if s.era == :modern and message do
      headers = Map.put(headers, "mcp-method", message["method"])
      value = get_in(message, ["params", "name"]) || get_in(message, ["params", "uri"])

      headers =
        if value, do: Map.put(headers, "mcp-name", HTTP.header_value(value)), else: headers

      if message["method"] == "tools/call" and s.tools[value] do
        {:ok, parameter_headers} =
          Schema.headers(s.tools[value], get_in(message, ["params", "arguments"]) || %{})

        Map.merge(headers, parameter_headers)
      else
        headers
      end
    else
      headers
    end
  end

  defp worker(pid, ref), do: %{pid: pid, ref: ref, buffer: "", sse: false, status: nil}

  defp cache_tools(s, "tools/list", %{"result" => %{"tools" => tools} = result} = message)
       when is_list(tools) do
    if s.era == :modern and is_nil(s.port) do
      {valid, cache} =
        Enum.reduce(tools, {[], s.tools}, fn tool, {valid, cache} ->
          case Schema.annotations(tool["inputSchema"] || %{}) do
            {:ok, _} ->
              {[tool | valid], Map.put(cache, tool["name"], tool["inputSchema"] || %{})}

            {:error, reason} ->
              emit(s, %{type: :protocol_warning, tool: tool["name"], reason: reason})
              {valid, cache}
          end
        end)

      {%{s | tools: cache},
       Map.put(message, "result", Map.put(result, "tools", Enum.reverse(valid)))}
    else
      {s, message}
    end
  end

  defp cache_tools(s, _, message), do: {s, message}
  defp decode(s, ""), do: s

  defp decode(s, text) do
    case Jason.decode(text) do
      {:ok, %{"jsonrpc" => "2.0"} = message} ->
        dispatch(s, message)

      _ ->
        emit(s, %{type: :protocol_error, reason: :invalid_json_rpc})
        s
    end
  end

  defp dispatch(%{era: :legacy} = s, %{"method" => "ping", "id" => id}) do
    transmit(s, make_ref(), %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
  end

  defp dispatch(s, %{"method" => method, "id" => id}) do
    # We advertise no sampling/roots/elicitation capabilities. Legacy requests fail explicitly.
    if s.era == :legacy do
      transmit(s, make_ref(), %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32601, "message" => "Client capability not supported"}
      })
    else
      emit(s, %{type: :protocol_error, reason: :unexpected_server_request, method: method})
      s
    end
  end

  defp dispatch(s, %{"method" => method} = message) do
    params = message["params"] || %{}
    subscription = get_in(params, ["_meta", "io.modelcontextprotocol/subscriptionId"])

    cond do
      s.era == :modern and subscription != nil and subscription != s.listen ->
        s

      method == "notifications/subscriptions/acknowledged" ->
        emit(s, %{type: :subscriptions, method: method, params: params, status: :acknowledged})
        %{s | listener_ack: true}

      s.era == :modern and subscription != nil and not s.listener_ack ->
        emit(s, %{type: :protocol_error, reason: :notification_before_ack})
        s

      true ->
        emit(s, %{type: :notification, method: method, params: params})
        s
    end
  end

  defp dispatch(s, %{"id" => id} = message) do
    case s.pending[id] do
      nil ->
        s

      %{kind: :discover} ->
        s = remove_pending(s, id)

        cond do
          message["result"] && @modern in (message["result"]["supportedVersions"] || []) ->
            ready(s, message["result"])

          get_in(message, ["error", "code"]) in [-32020, -32021, -32022] ->
            disconnected(s, {:unsupported_protocol, message["error"]})

          message["error"] ->
            fallback(s)

          true ->
            disconnected(s, :invalid_discovery)
        end

      %{kind: :initialize} ->
        s = remove_pending(s, id)
        result = message["result"]

        if result && result["protocolVersion"] in @legacy do
          s = %{s | version: result["protocolVersion"]}
          message = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

          if s.port do
            ready(transmit(s, :initialized, message), result)
          else
            transmit(%{s | info: result}, :initialized, message)
          end
        else
          disconnected(s, {:initialization_failed, message["error"] || result})
        end

      %{kind: :listen} ->
        s = remove_pending(s, id)
        emit(s, %{type: :subscription_closed, error: message["error"]})
        unless message["error"], do: Process.send_after(self(), :listen_again, s.retry)
        %{s | listen: nil, listener_ack: false}

      %{kind: {:subscribe, uri}} ->
        s = remove_pending(s, id)

        emit(s, %{
          type: :subscriptions,
          uri: uri,
          status: if(message["error"], do: :failed, else: :active),
          error: message["error"]
        })

        if message["error"], do: s, else: %{s | subscribed: Enum.uniq([uri | s.subscribed])}

      %{kind: {:unsubscribe, uri}} ->
        s = remove_pending(s, id)
        if message["error"], do: s, else: %{s | subscribed: List.delete(s.subscribed, uri)}

      %{kind: {:external, from, method}} ->
        s = remove_pending(s, id)
        {s, message} = cache_tools(s, method, message)

        result =
          if message["error"], do: {:error, message["error"]}, else: {:ok, message["result"]}

        GenServer.reply(from, result)

        emit(s, %{
          type: :response,
          method: method,
          status: if(message["error"], do: :error, else: :ok),
          bytes: byte_size(Jason.encode!(message["error"] || message["result"]))
        })

        s
    end
  end

  defp dispatch(s, _), do: s

  defp sse(s, token, block) do
    lines = String.split(block, ~r/\r?\n/)

    s =
      Enum.reduce(lines, s, fn line, s ->
        cond do
          String.starts_with?(line, "id:") and token == :get ->
            %{s | last_event_id: String.trim_leading(String.slice(line, 3..-1//1))}

          String.starts_with?(line, "retry:") ->
            case Integer.parse(String.trim(String.slice(line, 6..-1//1))) do
              {ms, ""} when ms >= 0 -> %{s | retry: min(ms, 60_000)}
              _ -> s
            end

          true ->
            s
        end
      end)

    data =
      for line <- lines,
          String.starts_with?(line, "data:"),
          do: String.replace_prefix(String.slice(line, 5..-1//1), " ", "")

    if data == [] or data == [""], do: s, else: decode(s, Enum.join(data, "\n"))
  end

  defp remove_pending(s, id) do
    if s.pending[id] && s.pending[id].timer, do: Process.cancel_timer(s.pending[id].timer)

    s =
      if s.workers[id] && s.workers[id].sse do
        Process.exit(s.workers[id].pid, :kill)
        %{s | workers: Map.delete(s.workers, id)}
      else
        s
      end

    %{s | pending: Map.delete(s.pending, id)}
  end

  defp fail_request(s, id, reason) do
    case s.pending[id] do
      %{kind: {:external, from, method}} ->
        GenServer.reply(from, {:error, reason})
        emit(s, %{type: :response, method: method, status: :error, reason: inspect(reason)})
        remove_pending(s, id)

      %{kind: kind} when kind in [:initialize, :discover] ->
        disconnected(s, reason)

      _ ->
        emit(s, %{type: :subscription_error, reason: inspect(reason)})
        remove_pending(s, id)
    end
  end

  defp cancel(s, id) do
    if s.port do
      transmit(s, make_ref(), %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => id}
      })
    else
      if s.workers[id], do: Process.exit(s.workers[id].pid, :kill)
      %{s | workers: Map.delete(s.workers, id)}
    end
  end

  defp disconnected(s, reason) do
    close(s)

    Enum.each(s.pending, fn {_, pending} ->
      if pending.timer, do: Process.cancel_timer(pending.timer)

      case pending.kind do
        {:external, from, _} -> GenServer.reply(from, {:error, {:disconnected, reason}})
        _ -> :ok
      end
    end)

    Enum.each(s.waiters, &GenServer.reply(&1, {:error, {:disconnected, reason}}))
    emit(s, %{type: :disconnected, reason: inspect(reason), reconnect_in_ms: s.backoff})
    Process.send_after(self(), :reconnect, s.backoff)

    %{
      s
      | port: nil,
        pending: %{},
        workers: %{},
        waiters: [],
        status: :disconnected,
        backoff: min(s.backoff * 2, 30_000),
        listen: nil
    }
  end

  defp close(s) do
    if s.port do
      try do
        Port.close(s.port)
      catch
        :error, _ -> :ok
      end
    end

    Enum.each(s.workers, fn {_, w} -> Process.exit(w.pid, :kill) end)
  end

  defp info(s),
    do: %{
      server: s.name,
      status: s.status,
      protocol: s.version,
      era: s.era,
      capabilities: s.info["capabilities"] || %{},
      subscriptions: s.uris
    }

  defp emit(s, payload), do: send(s.manager, {:mcp_client, s.name, self(), payload})
end

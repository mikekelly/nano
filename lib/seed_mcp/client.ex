defmodule SeedMCP.Client do
  @moduledoc false
  use GenServer
  @version "2025-11-25"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    name = Keyword.get(opts, :server_name, "server")
    dir = Keyword.get(opts, :state_dir, "/data/seed_mcp")
    key = Keyword.get(opts, :subscription_key, if(is_binary(owner), do: owner))

    path =
      if key,
        do:
          Path.join(
            dir,
            Base.url_encode64(:crypto.hash(:sha256, key <> "\0" <> name), padding: false) <>
              ".json"
          )

    subs =
      with true <- not is_nil(path),
           {:ok, b} <- File.read(path),
           {:ok, list} when is_list(list) <- Jason.decode(b),
           do: list

    s = %{
      owner: owner,
      name: name,
      server: Keyword.fetch!(opts, :server),
      dir: dir,
      path: path,
      subs: if(is_list(subs), do: subs, else: []),
      pending: %{},
      next: 1,
      phase: :disconnected,
      port: nil,
      buffer: "",
      session: nil,
      workers: %{},
      epoch: 0,
      retry: 500,
      frame: Keyword.get(opts, :frame_bytes, 2_000_000),
      cap: Keyword.get(opts, :result_bytes, 12_000),
      info: nil,
      protocol:
        Keyword.get(
          opts,
          :protocol,
          Keyword.fetch!(opts, :server)["protocolVersion"] || "2026-07-28"
        )
    }

    send(self(), :connect)
    {:ok, s}
  end

  def handle_call(:status, _, s),
    do: {:reply, %{phase: s.phase, server: s.info, subscriptions: s.subs}, s}

  def handle_call({:cancel_subscription, id}, _, s), do: {:reply, :ok, cancel(s, id)}

  def handle_call({:owner, owner}, _, s), do: {:reply, :ok, %{s | owner: owner}}

  def handle_call({:request, method, params, timeout}, from, %{phase: :ready} = s) do
    cond do
      not is_binary(method) or not is_map(params) or not is_integer(timeout) or timeout <= 0 ->
        {:reply, {:error, "Expected binary method, map params and positive timeout"}, s}

      byte_size(Jason.encode!(params)) > s.frame ->
        {:reply, {:error, "Request exceeds frame_bytes"}, s}

      map_size(s.pending) >= 100 ->
        {:reply, {:error, "Too many pending MCP requests (100)"}, s}

      true ->
        cond do
          s.protocol == "2026-07-28" and method == "subscriptions/listen" ->
            {:noreply, issue(s, method, params, {:filter, from}, timeout)}

          s.protocol == "2026-07-28" and method == "resources/subscribe" ->
            {:noreply,
             issue(
               s,
               "subscriptions/listen",
               %{"notifications" => %{"resourceSubscriptions" => [params["uri"]]}},
               {:subscribe, from, params["uri"]},
               timeout
             )}

          s.protocol == "2026-07-28" and method == "resources/unsubscribe" ->
            uri = params["uri"]

            s =
              Enum.reduce(s.pending, s, fn {id, entry}, acc ->
                if get_in(entry.params, ["notifications", "resourceSubscriptions"]) == [uri],
                  do: cancel(acc, id),
                  else: acc
              end)

            s = subscription(s, %{method: method, params: params})
            {:reply, {:ok, %{}}, s}

          true ->
            {:noreply, issue(s, method, params, from, timeout)}
        end
    end
  end

  def handle_call({:request, _, _, _}, _, s),
    do: {:reply, {:error, "MCP is not ready; inspect SeedMCP.status/1"}, s}

  def handle_info(:connect, s) do
    s = %{s | epoch: s.epoch + 1, phase: :initializing, session: nil, buffer: ""}

    try do
      s =
        if command = s.server["command"] do
          executable = System.find_executable(command) || command
          args = Enum.map(s.server["args"] || [], &String.to_charlist/1)

          env =
            Enum.map(s.server["env"] || %{}, fn {k, v} ->
              {String.to_charlist(k), String.to_charlist(v)}
            end)

          options = [:binary, :exit_status, :use_stdio, :hide, {:args, args}, {:env, env}]

          options =
            if s.server["cwd"],
              do: [{:cd, String.to_charlist(s.server["cwd"])} | options],
              else: options

          %{s | port: Port.open({:spawn_executable, String.to_charlist(executable)}, options)}
        else
          if not is_binary(s.server["url"]), do: raise("Config requires command or url")
          s
        end

      if s.protocol == "2026-07-28" do
        {:noreply, issue(s, "server/discover", %{}, :discover, 30_000)}
      else
        {:noreply,
         issue(
           s,
           "initialize",
           %{
             "protocolVersion" => @version,
             "capabilities" => %{},
             "clientInfo" => %{"name" => "SeedMCP", "version" => "1"}
           },
           :initialize,
           30_000
         )}
      end
    rescue
      e -> {:noreply, disconnect(s, Exception.message(e))}
    end
  end

  def handle_info({port, {:data, data}}, %{port: port} = s) do
    buffer = s.buffer <> data

    if byte_size(buffer) > s.frame do
      {:noreply, disconnect(s, "stdio frame exceeds frame_bytes")}
    else
      parts = String.split(buffer, "\n")
      {lines, [rest]} = Enum.split(parts, -1)
      s = Enum.reduce(lines, %{s | buffer: rest}, &decode(&2, &1))
      {:noreply, s}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = s),
    do: {:noreply, disconnect(s, "stdio exited #{code}")}

  def handle_info({:EXIT, port, reason}, %{port: port} = s),
    do: {:noreply, disconnect(s, inspect(reason))}

  def handle_info({:http, epoch, ref, result}, %{epoch: epoch} = s) do
    worker = s.workers[ref]
    s = %{s | workers: Map.delete(s.workers, ref)}

    case result do
      {:ok, :get_disabled} ->
        {:noreply, s}

      {:ok, _} when worker.method == :get ->
        {:noreply, disconnect(s, "HTTP notification stream closed")}

      {:ok, _} when worker.rpc == "subscriptions/listen" ->
        {:noreply, disconnect(s, "HTTP subscription stream closed")}

      {:ok, session} ->
        {:noreply, %{s | session: session || s.session}}

      {:error, reason} ->
        {:noreply, disconnect(s, reason)}
    end
  end

  def handle_info({:wire, epoch, message}, %{epoch: epoch} = s),
    do: {:noreply, receive_message(s, message)}

  def handle_info({:session, epoch, session}, %{epoch: epoch} = s),
    do: {:noreply, %{s | session: session}}

  def handle_info({:timeout, id}, s) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        {:noreply, s}

      {entry, _} ->
        reply(entry.from, {:error, "MCP request timed out"})

        if entry.from in [:initialize, :discover] do
          {:noreply, disconnect(s, "discovery/initialize timed out")}
        else
          {:noreply, cancel(s, id)}
        end
    end
  end

  def handle_info({:EXIT, pid, reason}, s) when reason != :normal do
    if Enum.any?(s.workers, fn {_, w} -> w.pid == pid end),
      do: {:noreply, disconnect(s, "HTTP worker exited")},
      else: {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}
  def terminate(_, s), do: cleanup(s)

  defp issue(s, method, params, from, timeout) do
    params =
      if s.protocol == "2026-07-28",
        do:
          Map.put(params, "_meta", %{
            "io.modelcontextprotocol/protocolVersion" => s.protocol,
            "io.modelcontextprotocol/clientInfo" => %{"name" => "SeedMCP", "version" => "1"},
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }),
        else: params

    id = s.next
    timer = Process.send_after(self(), {:timeout, id}, timeout)
    entry = %{from: from, method: method, params: params, timer: timer}
    event(s, :request, %{id: id, method: method})

    transmit(%{s | next: id + 1, pending: Map.put(s.pending, id, entry)}, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  defp transmit(%{port: port} = s, message) when is_port(port) do
    try do
      Port.command(port, Jason.encode!(message) <> "\n")
      s
    rescue
      e -> disconnect(s, Exception.message(e))
    end
  end

  defp transmit(s, message), do: http(s, :post, message)

  defp http(s, method, message) do
    parent = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        result =
          SeedMCP.HTTP.run(s.server, method, message, s.session, s.frame, fn
            {:message, m} -> send(parent, {:wire, s.epoch, m})
            {:session, session} -> send(parent, {:session, s.epoch, session})
          end)

        send(parent, {:http, s.epoch, ref, result})
      end)

    %{
      s
      | workers:
          Map.put(s.workers, ref, %{
            pid: pid,
            id: if(message, do: message["id"]),
            method: method,
            rpc: if(message, do: message["method"])
          })
    }
  end

  defp decode(s, ""), do: s

  defp decode(s, bytes) do
    case Jason.decode(bytes) do
      {:ok, m} when is_map(m) -> receive_message(s, m)
      _ -> disconnect(s, "Invalid JSON-RPC frame")
    end
  end

  defp receive_message(%{protocol: "2026-07-28"} = s, %{"method" => _, "id" => _}),
    do: disconnect(s, "Modern servers must not send requests")

  defp receive_message(s, %{"method" => method, "id" => id}) when is_binary(method) do
    transmit(s, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32601,
        "message" => "Client capability not supported: #{String.slice(method, 0, 100)}"
      }
    })
  end

  defp receive_message(
         s,
         %{"method" => "notifications/subscriptions/acknowledged", "params" => params} = m
       ) do
    id = get_in(params, ["_meta", "io.modelcontextprotocol/subscriptionId"])

    case s.pending[id] do
      %{from: {:subscribe, from, uri}} = entry ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        accepted = uri in (get_in(params, ["notifications", "resourceSubscriptions"]) || [])

        reply(
          from,
          if(accepted,
            do: {:ok, params},
            else: {:error, "Server did not acknowledge resource subscription"}
          )
        )

        s =
          if accepted,
            do: subscription(s, %{method: "resources/subscribe", params: %{"uri" => uri}}),
            else: s

        s = %{s | pending: Map.put(s.pending, id, %{entry | from: :listen, timer: nil})}
        event(s, :notification, %{method: m["method"], params: bounded(s, params)})
        s

      %{from: {:filter, from}} = entry ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        reply(from, {:ok, bounded(s, params)})
        event(s, :notification, %{method: m["method"], params: bounded(s, params)})
        %{s | pending: Map.put(s.pending, id, %{entry | from: :listen, timer: nil})}

      _ ->
        s
    end
  end

  defp receive_message(s, %{"method" => method} = m) when is_binary(method) do
    event(s, :notification, %{
      method: String.slice(method, 0, 200),
      params: bounded(s, m["params"] || %{})
    })

    s
  end

  defp receive_message(s, %{"id" => id} = m) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        s

      {entry, pending} ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        s = %{s | pending: pending}

        result =
          if Map.has_key?(m, "error"),
            do: {:error, bounded(s, m["error"])},
            else: {:ok, bounded(s, m["result"])}

        s =
          if entry.method == "tools/list" and is_list(get_in(m, ["result", "tools"])) do
            schemas =
              Enum.reduce(
                Enum.take(m["result"]["tools"], 1000),
                s.server["_toolSchemas"] || %{},
                fn tool, acc -> Map.put(acc, tool["name"], tool["inputSchema"]) end
              )

            %{s | server: Map.put(s.server, "_toolSchemas", schemas)}
          else
            s
          end

        event(s, :response, %{id: id, method: entry.method, result: result})

        cond do
          entry.from == :discover ->
            if is_map(m["result"]) and s.protocol in (m["result"]["supportedVersions"] || []) do
              s = %{s | phase: :ready, info: bounded(s, m["result"]), retry: 500}
              event(s, :connected, %{protocol: s.protocol})

              Enum.reduce(s.subs, s, fn uri, acc ->
                issue(
                  acc,
                  "subscriptions/listen",
                  %{"notifications" => %{"resourceSubscriptions" => [uri]}},
                  {:subscribe, :restore, uri},
                  30_000
                )
              end)
            else
              disconnect(
                s,
                "Server does not support #{s.protocol}; configure protocolVersion 2025-11-25 for legacy servers"
              )
            end

          entry.from == :listen ->
            disconnect(s, "Subscription closed by server")

          entry.from == :initialize ->
            case m do
              %{"result" => %{"protocolVersion" => @version} = info} ->
                s =
                  transmit(%{s | info: bounded(s, info), phase: :ready, retry: 500}, %{
                    "jsonrpc" => "2.0",
                    "method" => "notifications/initialized"
                  })

                event(s, :connected, %{protocol: @version})
                s = if s.port, do: s, else: http(s, :get, nil)

                Enum.reduce(s.subs, s, fn uri, acc ->
                  issue(acc, "resources/subscribe", %{"uri" => uri}, :restore, 30_000)
                end)

              _ ->
                disconnect(s, "Server did not negotiate #{@version}")
            end

          true ->
            s = if match?({:ok, _}, result), do: subscription(s, entry), else: s
            reply(entry.from, result)
            s
        end
    end
  end

  defp receive_message(s, _), do: disconnect(s, "Invalid JSON-RPC message")

  defp subscription(s, %{method: method, params: %{"uri" => uri}})
       when method in ["resources/subscribe", "resources/unsubscribe"] do
    subs =
      if method == "resources/subscribe",
        do: Enum.uniq([uri | s.subs]),
        else: List.delete(s.subs, uri)

    s = %{s | subs: subs}

    if s.path do
      temp = s.path <> ".15682.tmp"

      with :ok <- File.mkdir_p(s.dir),
           :ok <- File.write(temp, Jason.encode!(subs)),
           :ok <- File.rename(temp, s.path) do
        :ok
      else
        error -> event(s, :persistence_error, %{error: inspect(error)})
      end
    end

    s
  end

  defp subscription(s, _), do: s

  defp bounded(s, value) do
    bytes = Jason.encode!(value)

    if byte_size(bytes) <= s.cap do
      value
    else
      path =
        Path.join(
          s.dir,
          "result-#{System.unique_integer([:positive, :monotonic])}-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}.json"
        )

      with :ok <- File.mkdir_p(s.dir), :ok <- File.write(path, bytes) do
        %{
          truncated: true,
          bytes: byte_size(bytes),
          path: path,
          read_with: "SeedMCP.page(path, offset: 0)"
        }
      else
        _ -> %{truncated: true, bytes: byte_size(bytes), error: "Cannot write result spill"}
      end
    end
  end

  defp event(s, type, detail) do
    pid = if is_binary(s.owner), do: NanoAgent.whereis(s.owner), else: s.owner
    if is_pid(pid), do: send(pid, Map.merge(detail, %{mcp: s.name, event: type}))
  end

  defp reply({:filter, from}, result), do: reply(from, result)
  defp reply({:subscribe, from, _}, result), do: reply(from, result)
  defp reply(from, result) when is_tuple(from), do: GenServer.reply(from, result)
  defp reply(_, _), do: :ok

  defp cancel(s, id) do
    if entry = s.pending[id] do
      if entry.timer, do: Process.cancel_timer(entry.timer)
      reply(entry.from, {:error, "MCP request cancelled"})
    end

    if s.port do
      s =
        transmit(s, %{
          "jsonrpc" => "2.0",
          "method" => "notifications/cancelled",
          "params" => %{"requestId" => id, "reason" => "unsubscribe"}
        })

      %{s | pending: Map.delete(s.pending, id)}
    else
      workers =
        Enum.reduce(s.workers, s.workers, fn {ref, worker}, acc ->
          if worker.id == id do
            Process.exit(worker.pid, :kill)
            Map.delete(acc, ref)
          else
            acc
          end
        end)

      %{s | pending: Map.delete(s.pending, id), workers: workers}
    end
  end

  defp cleanup(s) do
    if s.port && Port.info(s.port), do: Port.close(s.port)
    Enum.each(s.workers, fn {_, worker} -> Process.exit(worker.pid, :kill) end)
    :ok
  end

  defp disconnect(s, reason) do
    cleanup(s)

    Enum.each(s.pending, fn {_, entry} ->
      if entry.timer, do: Process.cancel_timer(entry.timer)
      reply(entry.from, {:error, String.slice(inspect(reason), 0, 500)})
    end)

    event(s, :disconnected, %{
      reason: String.slice(inspect(reason), 0, 500),
      reconnect_ms: s.retry
    })

    if s.phase != :disconnected, do: Process.send_after(self(), :connect, s.retry)

    %{
      s
      | phase: :disconnected,
        port: nil,
        workers: %{},
        pending: %{},
        retry: min(s.retry * 2, 30_000),
        epoch: s.epoch + 1
    }
  end
end

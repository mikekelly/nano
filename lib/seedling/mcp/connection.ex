defmodule Seedling.MCP.Connection do
  @moduledoc false
  use GenServer
  alias Seedling.MCP.{Bounds, Headers, Transport}
  import Seedling.MCP, only: [error: 2]
  @modern "2026-07-28"
  @legacy ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  def start_link(opts),
    do:
      GenServer.start_link(__MODULE__, opts,
        name: {:via, Registry, {Seedling.MCP.Registry, opts.key}}
      )

  def init(opts) do
    Process.flag(:trap_exit, true)
    File.mkdir_p!(opts.dir)

    s =
      Map.merge(opts, %{
        status: :connecting,
        version: @modern,
        info: %{},
        last_error: nil,
        port: nil,
        os_pid: nil,
        guardian: nil,
        stderr_path: nil,
        buffer: "",
        epoch: 0,
        seq: 0,
        pending: %{},
        workers: %{},
        session: nil,
        listening: nil,
        last_event_id: nil,
        retry: 100,
        watchers: MapSet.new(),
        subs: %{},
        queue: %{},
        tools: %{},
        http_status: %{},
        forgotten: false
      })
      |> load_intents()

    persist(s)
    send(self(), :open)
    Process.send_after(self(), :deliver, 200)
    {:ok, s}
  end

  def handle_call(:status, _, s) do
    {:reply,
     {:ok,
      Map.take(s, [:status, :version, :last_error, :stderr_path, :os_pid])
      |> Map.put(:info, Bounds.wrap(s.info, s.dir, max_bytes: 4000))
      |> Map.put(
        :subscriptions,
        Bounds.wrap(%{"subscriptions" => Map.keys(s.subs)}, s.dir, max_bytes: 4000, max_items: 20)
      )
      |> Map.put(:subscription_count, map_size(s.subs))}, s}
  end

  def handle_call(:forget, _, s) do
    if s.config["transport"] == "http" and not is_nil(s.session) and s.version != @modern do
      Transport.delete_session(s.config, s.session, s.version)
    end

    File.rm(Path.join(s.dir, "intent.json"))

    {:reply, :ok, %{s | forgotten: true}}
  end

  def handle_call({:intent, action, uri, target}, _, s) do
    if valid_target?(target) and
         (action in [:watch, :unwatch] or (is_binary(uri) and byte_size(uri) <= 8192)) do
      {watchers, subs} =
        case action do
          :watch ->
            {MapSet.put(s.watchers, target), s.subs}

          :unwatch ->
            {MapSet.delete(s.watchers, target), s.subs}

          :subscribe ->
            {s.watchers, Map.update(s.subs, uri, MapSet.new([target]), &MapSet.put(&1, target))}

          :unsubscribe ->
            targets = MapSet.delete(Map.get(s.subs, uri, MapSet.new()), target)

            {s.watchers,
             if(MapSet.size(targets) == 0,
               do: Map.delete(s.subs, uri),
               else: Map.put(s.subs, uri, targets)
             )}
        end

      next = %{s | watchers: watchers, subs: subs}

      case persist(next) do
        :ok ->
          send(self(), {:refresh, s.subs})
          {:reply, :ok, next}

        {:error, e} ->
          {:reply, {:error, e}, s}
      end
    else
      {:reply,
       error(
         :invalid_target,
         "Target must be pid or {:agent, name}; resource URI must be string."
       ), s}
    end
  end

  def handle_call({:request, method, params, opts}, from, s) do
    cond do
      s.status != :ready ->
        {:reply,
         error(
           :not_ready,
           "Server disconnected/initializing; inspect status/1 and wait for connected event."
         ), s}

      not supported?(s, method) ->
        {:reply,
         error(:unsupported_capability, "Server did not advertise capability for #{method}."), s}

      true ->
        case extra_headers(s, method, params) do
          {:ok, headers} -> {:noreply, send_request(s, method, params, opts, from, nil, headers)}
          e -> {:reply, e, s}
        end
    end
  end

  def handle_info(:open, s) do
    s = %{
      s
      | epoch: s.epoch + 1,
        status: :connecting,
        version: @modern,
        buffer: "",
        session: nil,
        tools: %{},
        last_event_id: nil
    }

    case s.config["transport"] do
      "stdio" ->
        case Transport.open_stdio(s.config, s.dir, self()) do
          {:ok, port, pid, path, guardian} ->
            {:noreply,
             probe(%{s | port: port, os_pid: pid, stderr_path: path, guardian: guardian})}

          {:error, e} ->
            {:noreply, down(s, e)}
        end

      "http" ->
        {:noreply, probe(s)}
    end
  end

  def handle_info({:refresh, old_subs}, s) do
    if s.status == :ready do
      {:noreply, refresh(s, old_subs)}
    else
      {:noreply, s}
    end
  end

  def handle_info({:retry_listen, epoch}, %{epoch: epoch, status: :ready} = s),
    do: {:noreply, refresh(s, %{})}

  def handle_info({:retry_listen, _}, s), do: {:noreply, s}

  def handle_info({port, {:data, data}}, %{port: port} = s) do
    buffer = s.buffer <> data
    cap = s.config["max_message_bytes"] || 8_000_000
    lines = :binary.split(buffer, "\n", [:global])
    tail = List.last(lines)

    result =
      Enum.reduce_while(Enum.drop(lines, -1), %{s | buffer: tail}, fn line, acc ->
        case if(byte_size(line) <= cap, do: Jason.decode(line), else: {:error, :oversize}) do
          {:ok, msg} when is_map(msg) ->
            {:cont, safe_wire(acc, :stdio, msg)}

          _ ->
            {:halt,
             down(acc, %{
               reason: :invalid_frame,
               message:
                 "Malformed or oversized stdio frame; check stderr/config max_message_bytes."
             })}
        end
      end)

    if byte_size(tail) > cap,
      do:
        {:noreply,
         down(result, %{reason: :oversize, message: "Stdio frame exceeds max_message_bytes."})},
      else: {:noreply, result}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = s),
    do:
      {:noreply,
       down(s, %{reason: :server_exit, message: "MCP process exited #{status}; reconnecting."})}

  def handle_info({:EXIT, port, reason}, %{port: port} = s),
    do:
      {:noreply,
       down(s, %{
         reason: :port_exit,
         message: "MCP port closed: #{inspect(reason)}; reconnecting."
       })}

  def handle_info({:wire, epoch, tag, msg}, %{epoch: epoch} = s),
    do: {:noreply, safe_wire(s, tag, msg)}

  def handle_info({:sse_id, epoch, tag, id}, %{epoch: epoch} = s) do
    if tag == :listen, do: {:noreply, %{s | last_event_id: id}}, else: {:noreply, s}
  end

  def handle_info({:http_headers, epoch, tag, status, headers}, %{epoch: epoch} = s) do
    session =
      if tag == :listen or s.version == @modern,
        do: s.session,
        else: List.first(Map.get(headers, "mcp-session-id", [])) || s.session

    s = %{s | session: session, http_status: Map.put(s.http_status, tag, status)}

    if status == 404 and s.version != @modern and s.session do
      {:noreply,
       down(s, %{
         reason: :session_expired,
         message: "HTTP session expired; starting new session and restoring subscriptions."
       })}
    else
      {:noreply, s}
    end
  end

  def handle_info({:http_done, epoch, tag, status, last_id}, %{epoch: epoch} = s) do
    s = drop_worker(s, tag)

    cond do
      tag == :initialized and status == 202 ->
        {:noreply, ready(s, s.info)}

      tag == :initialized ->
        {:noreply,
         down(s, %{
           reason: :initialization_failed,
           message: "Initialized notification rejected: HTTP #{status}"
         })}

      tag == s.listening ->
        if status == 405 and s.version != @modern do
          {:noreply, %{s | listening: nil}}
        else
          Process.send_after(self(), {:retry_listen, s.epoch}, 500)
          s = emit(s, :subscription_closed, %{"status" => status}, all_targets(s))
          {:noreply, %{s | listening: nil, last_event_id: last_id}}
        end

      Map.has_key?(s.pending, tag) ->
        pending = s.pending[tag]

        cond do
          pending.internal == :probe and status in 400..499 ->
            {:noreply, fallback(remove_pending(s, tag))}

          true ->
            {:noreply,
             finish_error(s, tag, %{
               reason: :http_response,
               message: "HTTP #{status} completed without an RPC result."
             })}
        end

      true ->
        {:noreply, s}
    end
  end

  def handle_info({:http_error, epoch, tag, message}, %{epoch: epoch} = s) do
    s = drop_worker(s, tag)

    if tag == s.listening do
      Process.send_after(self(), {:retry_listen, s.epoch}, 500)

      {:noreply,
       emit(%{s | listening: nil}, :subscription_closed, %{"error" => message}, all_targets(s))}
    else
      e = %{reason: :http_error, message: message}

      if s.pending[tag] && is_nil(s.pending[tag].internal),
        do: {:noreply, down(s, e)},
        else: {:noreply, finish_error(s, tag, e)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, s) do
    case Enum.find(s.workers, fn {_tag, {_pid, r}} -> r == ref end) do
      nil ->
        {:noreply, s}

      {tag, _} ->
        s = drop_worker(s, tag)

        cond do
          tag == s.listening ->
            Process.send_after(self(), {:retry_listen, s.epoch}, 500)

            {:noreply,
             emit(
               %{s | listening: nil},
               :subscription_closed,
               %{"error" => inspect(reason)},
               all_targets(s)
             )}

          Map.has_key?(s.pending, tag) ->
            {:noreply,
             finish_error(s, tag, %{
               reason: :transport_error,
               message: "HTTP worker failed: #{inspect(reason)}"
             })}

          true ->
            {:noreply, s}
        end
    end
  end

  def handle_info({:timeout, id}, s) do
    case s.pending[id] do
      nil ->
        {:noreply, s}

      %{internal: :probe} ->
        {:noreply, fallback(cancel_request(s, id))}

      _ ->
        {:noreply,
         finish_error(cancel_transport(s, id), id, %{
           reason: :timeout,
           message:
             "RPC timed out; work was cancelled if supported. Do not blindly retry side effects."
         })}
    end
  end

  def handle_info(:deliver, s) do
    s =
      Enum.reduce(s.queue, %{s | queue: %{}}, fn {target, events}, acc ->
        Enum.reduce(events, acc, fn event, acc -> deliver(acc, target, event) end)
      end)

    Process.send_after(self(), :deliver, 200)
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  def terminate(_, s) do
    stop_transports(s)
    :ok
  end

  defp probe(s), do: send_request(s, "server/discover", %{}, [timeout: 2000], nil, :probe)

  defp fallback(s) do
    s = %{s | version: hd(@legacy)}

    send_request(
      s,
      "initialize",
      %{
        "protocolVersion" => s.version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "seedling", "version" => "1.0.0"}
      },
      [timeout: 10_000],
      nil,
      :initialize
    )
  end

  defp ready(s, info) do
    s = %{s | status: :ready, info: info, last_error: nil, retry: 100}

    s =
      emit(
        s,
        :connected,
        %{"protocolVersion" => s.version, "capabilities" => info["capabilities"] || %{}},
        all_targets(s)
      )

    refresh(s, %{})
  end

  defp send_request(s, method, params, opts, from, internal, headers \\ []) do
    id = s.seq + 1
    meta = params["_meta"] || %{}

    meta =
      if s.version == @modern,
        do:
          Map.merge(meta, %{
            "io.modelcontextprotocol/protocolVersion" => s.version,
            "io.modelcontextprotocol/clientInfo" => %{"name" => "seedling", "version" => "1.0.0"},
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }),
        else: meta

    meta =
      if opts[:log_level],
        do: Map.put(meta, "io.modelcontextprotocol/logLevel", opts[:log_level]),
        else: meta

    meta =
      if opts[:progress],
        do: Map.put(meta, "progressToken", "seedling-#{s.epoch}-#{id}"),
        else: meta

    params = if meta == %{}, do: params, else: Map.put(params, "_meta", meta)
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    timer = Process.send_after(self(), {:timeout, id}, opts[:timeout] || 30_000)

    pending = %{
      from: from,
      method: method,
      opts: opts,
      internal: internal,
      timer: timer,
      params: params
    }

    send_wire(%{s | seq: id, pending: Map.put(s.pending, id, pending)}, id, message, headers)
  end

  defp send_wire(s, tag, msg, headers \\ []) do
    if s.config["transport"] == "stdio" do
      try do
        Port.command(s.port, Jason.encode!(msg) <> "\n")
        s
      rescue
        e -> down(s, %{reason: :write_failed, message: Exception.message(e)})
      end
    else
      worker = Transport.http(self(), s.epoch, tag, s.config, msg, s.version, s.session, headers)
      %{s | workers: Map.put(s.workers, tag, worker)}
    end
  end

  defp notify(s, method, params),
    do: send_wire(s, make_ref(), %{"jsonrpc" => "2.0", "method" => method, "params" => params})

  defp safe_wire(s, tag, msg) do
    wire(s, tag, msg)
  rescue
    _e ->
      down(s, %{
        reason: :invalid_frame,
        message:
          "Server sent malformed MCP fields; inspect server implementation/stderr. Reconnecting."
      })
  end

  defp wire(s, tag, %{"jsonrpc" => "2.0", "id" => id} = msg) do
    cond do
      Map.has_key?(msg, "method") ->
        s = emit(s, "protocol/server_request", msg, all_targets(s))

        if s.version != @modern,
          do:
            send_wire(s, make_ref(), %{
              "jsonrpc" => "2.0",
              "id" => id,
              "error" => %{"code" => -32601, "message" => "Client capability not supported"}
            }),
          else: s

      id == s.listening and s.version == @modern ->
        Process.send_after(self(), {:retry_listen, s.epoch}, 500)
        emit(%{s | listening: nil}, :subscription_closed, msg, all_targets(s))

      not Map.has_key?(s.pending, id) ->
        s

      Map.has_key?(msg, "error") ->
        rpc_error(s, id, msg["error"])

      Map.has_key?(msg, "result") ->
        result(s, id, msg["result"])

      true ->
        finish_error(s, id, %{
          reason: :invalid_response,
          message: "JSON-RPC response lacks result/error (stream #{inspect(tag)})."
        })
    end
  end

  defp wire(s, tag, %{"jsonrpc" => "2.0", "method" => method} = msg)
       when is_binary(method) and byte_size(method) <= 256 do
    params = msg["params"] || %{}
    sub_id = get_in(params, ["_meta", "io.modelcontextprotocol/subscriptionId"])

    change =
      method in [
        "notifications/subscriptions/acknowledged",
        "notifications/resources/updated",
        "notifications/tools/list_changed",
        "notifications/resources/list_changed",
        "notifications/prompts/list_changed"
      ]

    if s.version == @modern and change and sub_id != s.listening do
      s
    else
      s = if method == "notifications/tools/list_changed", do: %{s | tools: %{}}, else: s

      targets =
        if method == "notifications/resources/updated",
          do: MapSet.union(s.watchers, Map.get(s.subs, params["uri"], MapSet.new())),
          else: all_targets(s)

      targets =
        if method == "notifications/progress" do
          token = params["progressToken"]

          Enum.reduce(s.pending, targets, fn {_id, p}, acc ->
            if get_in(p.params, ["_meta", "progressToken"]) == token and p.from,
              do: MapSet.put(acc, p.opts[:notify] || elem(p.from, 0)),
              else: acc
          end)
        else
          targets
        end

      targets =
        if method == "notifications/message" do
          Enum.reduce(s.pending, targets, fn {id, p}, acc ->
            if p.from && (tag == id or (tag == :stdio and not is_nil(p.opts[:log_level]))),
              do: MapSet.put(acc, p.opts[:notify] || elem(p.from, 0)),
              else: acc
          end)
        else
          targets
        end

      s = emit(s, method, params, targets)

      if method == "notifications/subscriptions/acknowledged" do
        missing =
          Map.keys(s.subs) -- (get_in(params, ["notifications", "resourceSubscriptions"]) || [])

        if missing != [],
          do: emit(s, :subscription_rejected, %{"uris" => missing}, all_targets(s)),
          else: s
      else
        s
      end
    end
  end

  defp wire(s, _, _),
    do: down(s, %{reason: :invalid_frame, message: "Server sent invalid JSON-RPC envelope."})

  defp rpc_error(s, id, rpc) do
    p = s.pending[id]
    s = remove_pending(s, id)

    e = %{
      reason: :rpc_error,
      message: "MCP JSON-RPC error (inspect rpc envelope).",
      rpc: Bounds.wrap(rpc, s.dir)
    }

    cond do
      p.internal == :probe and rpc["code"] not in [-32020, -32021, -32022] ->
        fallback(s)

      p.internal == :probe ->
        fail(s, e)

      p.internal == :initialize ->
        fail(s, e)

      p.from ->
        GenServer.reply(p.from, {:error, e})
        s

      true ->
        emit(s, :subscription_rejected, rpc, all_targets(s))
    end
  end

  defp result(s, id, data) do
    p = s.pending[id]
    s = remove_pending(s, id)

    case p.internal do
      :probe ->
        versions = data["supportedVersions"] || []

        cond do
          @modern in versions ->
            ready(s, data)

          true ->
            fail(s, %{
              reason: :unsupported_version,
              message: "Modern server has no supported version in common: #{inspect(versions)}"
            })
        end

      :initialize ->
        version = data["protocolVersion"]

        if version in @legacy do
          s = %{s | version: version}

          if s.config["transport"] == "stdio" do
            ready(notify(s, "notifications/initialized", %{}), data)
          else
            send_wire(%{s | status: :initializing, info: data}, :initialized, %{
              "jsonrpc" => "2.0",
              "method" => "notifications/initialized",
              "params" => %{}
            })
          end
        else
          fail(s, %{
            reason: :unsupported_version,
            message: "Server selected unsupported revision #{inspect(version)}."
          })
        end

      {:restore, uri} ->
        emit(s, :restored, %{"uri" => uri}, all_targets(s))

      _ ->
        {s, data} = cache_tools(s, p.method, data)
        if p.from, do: GenServer.reply(p.from, {:ok, Bounds.wrap(data, s.dir, p.opts)})
        s
    end
  end

  defp finish_error(s, id, e) do
    case s.pending[id] do
      nil ->
        s

      p ->
        s = remove_pending(s, id)

        cond do
          p.internal == :probe ->
            fallback(s)

          p.internal == :initialize ->
            down(s, e)

          p.from ->
            GenServer.reply(p.from, {:error, e})
            s

          true ->
            emit(s, :subscription_rejected, %{"error" => e.message}, all_targets(s))
        end
    end
  end

  defp remove_pending(s, id) do
    if s.pending[id], do: Process.cancel_timer(s.pending[id].timer)
    %{s | pending: Map.delete(s.pending, id)}
  end

  defp cancel_request(s, id), do: s |> cancel_transport(id) |> remove_pending(id)

  defp cancel_transport(s, id) do
    if s.config["transport"] == "stdio" do
      notify(s, "notifications/cancelled", %{"requestId" => id, "reason" => "Cancelled by client"})
    else
      case s.workers[id] do
        {pid, _} ->
          Process.exit(pid, :kill)
          drop_worker(s, id)

        nil ->
          s
      end
    end
  end

  defp drop_worker(s, tag) do
    case s.workers[tag] do
      {_, ref} -> Process.demonitor(ref, [:flush])
      nil -> :ok
    end

    %{s | workers: Map.delete(s.workers, tag), http_status: Map.delete(s.http_status, tag)}
  end

  defp refresh(s, old) do
    if s.version == @modern do
      s = if s.listening, do: cancel_transport(s, s.listening), else: s
      # Modern HTTP listen uses its request ID as worker tag, unlike legacy GET.
      s = %{s | listening: nil}

      if MapSet.size(all_targets(s)) > 0 do
        id = s.seq + 1

        filter = %{
          "toolsListChanged" => true,
          "resourcesListChanged" => true,
          "promptsListChanged" => true,
          "resourceSubscriptions" => Map.keys(s.subs)
        }

        meta = %{
          "io.modelcontextprotocol/protocolVersion" => s.version,
          "io.modelcontextprotocol/clientInfo" => %{"name" => "seedling", "version" => "1.0.0"},
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }

        s = %{s | seq: id, listening: id}

        send_wire(s, id, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => "subscriptions/listen",
          "params" => %{"notifications" => filter, "_meta" => meta}
        })
      else
        s
      end
    else
      s =
        Enum.reduce(Map.keys(old) -- Map.keys(s.subs), s, fn uri, acc ->
          send_request(
            acc,
            "resources/unsubscribe",
            %{"uri" => uri},
            [timeout: 5000],
            nil,
            :unsubscribe
          )
        end)

      s =
        Enum.reduce(Map.keys(s.subs) -- Map.keys(old), s, fn uri, acc ->
          if get_in(s.info, ["capabilities", "resources", "subscribe"]),
            do:
              send_request(
                acc,
                "resources/subscribe",
                %{"uri" => uri},
                [timeout: 5000],
                nil,
                {:restore, uri}
              ),
            else:
              emit(
                acc,
                :subscription_rejected,
                %{"uri" => uri, "error" => "Server does not advertise resources.subscribe"},
                all_targets(acc)
              )
        end)

      if s.config["transport"] == "http" and is_nil(s.listening) and
           MapSet.size(all_targets(s)) > 0 do
        worker =
          Transport.http(
            self(),
            s.epoch,
            :listen,
            s.config,
            nil,
            s.version,
            s.session,
            [],
            :get,
            s.last_event_id
          )

        %{s | listening: :listen, workers: Map.put(s.workers, :listen, worker)}
      else
        s
      end
    end
  end

  defp cache_tools(s, "tools/list", %{"tools" => tools} = data) when is_list(tools) do
    {s, valid} =
      Enum.reduce(tools, {s, []}, fn tool, {acc, valid} ->
        case Headers.tool(tool) do
          {:ok, annotations} ->
            {%{acc | tools: Map.put(acc.tools, tool["name"], annotations)}, [tool | valid]}

          {:error, _}
          when :erlang.map_get("transport", s.config) == "http" and s.version == @modern ->
            {emit(
               acc,
               "client/warning",
               %{"tool" => tool["name"], "error" => "Invalid x-mcp-header schema; tool excluded"},
               all_targets(acc)
             ), valid}

          _ ->
            {acc, [tool | valid]}
        end
      end)

    {s, Map.put(data, "tools", Enum.reverse(valid))}
  end

  defp cache_tools(s, _, data), do: {s, data}

  defp extra_headers(
         %{version: @modern, config: %{"transport" => "http"}} = s,
         "tools/call",
         params
       ) do
    case Map.fetch(s.tools, params["name"]) do
      {:ok, annotations} ->
        Headers.values(annotations, params["arguments"] || %{})

      :error ->
        error(
          :discover_tools_first,
          "Call tools/2 (and follow next_cursor) before modern HTTP tools/call; schema header mirroring is required."
        )
    end
  end

  defp extra_headers(_, _, _), do: {:ok, []}

  defp supported?(s, method) do
    capability = method |> String.split("/") |> hd()

    capability not in ["tools", "resources", "prompts"] or
      Map.has_key?(s.info["capabilities"] || %{}, capability)
  end

  defp fail(s, e) do
    stop_transports(s)

    emit(
      %{
        s
        | status: :failed,
          last_error: e,
          port: nil,
          os_pid: nil,
          guardian: nil,
          workers: %{},
          listening: nil
      },
      :disconnected,
      %{"error" => e.message},
      all_targets(s)
    )
  end

  defp down(%{status: :disconnected} = s, _e), do: s

  defp down(s, e) do
    Enum.each(s.pending, fn {_id, p} ->
      Process.cancel_timer(p.timer)
      if p.from, do: GenServer.reply(p.from, {:error, e})
    end)

    stop_transports(s)
    Process.send_after(self(), :open, s.retry)

    emit(
      %{
        s
        | status: :disconnected,
          last_error: e,
          port: nil,
          os_pid: nil,
          guardian: nil,
          workers: %{},
          pending: %{},
          listening: nil,
          retry: min(s.retry * 2, 5000)
      },
      :disconnected,
      %{"error" => e.message},
      all_targets(s)
    )
  end

  defp stop_transports(s) do
    Enum.each(s.workers, fn {_, {pid, ref}} ->
      Process.demonitor(ref, [:flush])
      Process.exit(pid, :kill)
    end)

    Transport.close(s.port, s.os_pid, s.guardian)
  end

  defp valid_target?(pid) when is_pid(pid), do: true

  defp valid_target?({:agent, name}),
    do: is_binary(name) and name != "" and byte_size(name) <= 256

  defp valid_target?(_), do: false

  defp all_targets(s),
    do: Enum.reduce(s.subs, s.watchers, fn {_, targets}, acc -> MapSet.union(acc, targets) end)

  defp emit(s, kind, data, targets) do
    envelope = Bounds.wrap(data, s.dir, max_bytes: 4000, max_items: 20)

    Enum.reduce(targets, s, fn target, acc ->
      deliver(acc, target, {:seedling_mcp, s.name, kind, envelope})
    end)
  end

  defp deliver(s, target, event) do
    pid =
      try do
        case target do
          {:agent, name} -> s.resolver.(name)
          pid -> pid
        end
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    if is_pid(pid) and Process.alive?(pid) do
      send(pid, event)
      s
    else
      if is_pid(target) do
        s
      else
        events = Map.get(s.queue, target, [])

        if length(events) >= 100 do
          overflow =
            {:seedling_mcp, s.name, :delivery_overflow,
             %{
               data: %{
                 "message" =>
                   "Absent agent queue exceeded 100; oldest events lost. Refresh discovery/resources."
               },
               truncated: false
             }}

          %{s | queue: Map.put(s.queue, target, Enum.take(events, -98) ++ [overflow, event])}
        else
          %{s | queue: Map.put(s.queue, target, events ++ [event])}
        end
      end
    end
  end

  defp persist(s) do
    targets = fn set ->
      Enum.flat_map(set, fn
        {:agent, name} -> [name]
        _ -> []
      end)
    end

    data = %{
      "name" => s.name,
      "config_path" => s.config_path,
      "watchers" => targets.(s.watchers),
      "subscriptions" =>
        s.subs
        |> Enum.flat_map(fn {uri, set} ->
          case targets.(set) do
            [] -> []
            names -> [{uri, names}]
          end
        end)
        |> Map.new()
    }

    case Seedling.Files.write(Path.join(s.dir, "intent.json"), Jason.encode!(data)) do
      {:ok, _} -> :ok
      e -> e
    end
  end

  defp load_intents(s) do
    with {:ok, raw} <- File.read(Path.join(s.dir, "intent.json")),
         {:ok, data} <- Jason.decode(raw) do
      watchers = MapSet.new(Enum.map(data["watchers"] || [], &{:agent, &1}))

      subs =
        Map.new(data["subscriptions"] || %{}, fn {uri, names} ->
          {uri, MapSet.new(Enum.map(names, &{:agent, &1}))}
        end)

      %{s | watchers: watchers, subs: subs}
    else
      _ -> s
    end
  end
end

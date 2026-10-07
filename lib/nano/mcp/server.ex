defmodule Nano.MCP.Server do
  @moduledoc """
  One connection to an MCP server, as a GenServer, speaking **both eras** of the protocol:

    * *modern* (per-request metadata, revision `2026-07-28`): each request carries
      `_meta` with `io.modelcontextprotocol/protocolVersion`, `clientInfo` and
      `clientCapabilities`; the server's era and versions are probed with `server/discover`.
    * *legacy* (initialization handshake, `2025-11-25` and earlier): the `initialize` /
      `notifications/initialized` handshake, after which requests carry no `_meta`.

  The probe, and the fall back to `initialize` on any error that is not a recognized
  modern error, is what `specification/2026-07-28/basic/transports/stdio.md` prescribes
  under "Backward Compatibility". The result of the probe is remembered for the life of
  the connection (`:era` in state), so a legacy reference server and a modern one are
  both usable without the caller choosing.

  The transport is a port for stdio and `Req` for streamable HTTP. Requests are
  asynchronous inside the process: the caller's `from` is kept by JSON-RPC id, so a slow
  tool call cannot block notifications behind it. Notifications are forwarded to
  subscribed agents with `Nano.MCP.deliver/3`.
  """

  use GenServer
  require Logger

  alias Nano.MCP.JSONRPC, as: P

  @modern "2026-07-28"
  @legacy_versions ["2025-11-25", "2025-06-18", "2025-03-26"]
  @reconnect_ms 3_000
  @request_timeout 120_000

  def start_link({id, config}), do: GenServer.start_link(__MODULE__, {id, config})

  def child_spec({id, config}) do
    %{id: {__MODULE__, id}, start: {__MODULE__, :start_link, [{id, config}]}, restart: :permanent}
  end

  ## GenServer

  @impl true
  def init({id, config}) do
    state = %{
      id: id,
      config: config,
      port: nil,
      session: nil,
      era: nil,
      version: nil,
      next_id: 0,
      waiting: %{},
      buffer: "",
      tools: nil,
      resources: nil,
      resource_templates: nil,
      prompts: nil,
      server_info: nil,
      capabilities: nil,
      instructions: nil,
      probe_timer: nil,
      stderr_log: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case ensure_registered(state) do
      :ok ->
        case open(state) do
          {:ok, state} ->
            {:noreply, probe(state)}

          {:error, reason, state} ->
            Logger.warning("mcp #{state.id}: cannot start: #{inspect(reason)}")
            {:noreply, schedule_reconnect(state)}
        end

      {:error, reason} ->
        Logger.warning("mcp #{state.id}: cannot register: #{inspect(reason)}")
        {:noreply, schedule_reconnect(state)}
    end
  end

  defp ensure_registered(state) do
    case Registry.register(Nano.MCP.Registry, state.id, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---- requests ----------------------------------------------------------------

  @impl true
  def handle_call(:info, _from, state), do: {:reply, info(state), state}

  def handle_call(:ping, from, state) do
    if state.era, do: {:noreply, start_request(state, from, "ping", %{})}, else: {:reply, :not_ready, state}
  end

  def handle_call(:tools, from, state), do: catalogue_call(state, :tools, from)
  def handle_call(:resources, from, state), do: catalogue_call(state, :resources, from)

  def handle_call(:resource_templates, from, state), do: catalogue_call(state, :resource_templates, from)

  def handle_call(:prompts, from, state), do: catalogue_call(state, :prompts, from)

  def handle_call(:catalogue, _from, state) do
    # Ask for whatever is cold, then answer from the cache once they land: a call in flight
    # would block the transport. Sending all four and deferring the reply keeps the loop free.
    state = Enum.reduce([:tools, :resources, :prompts], state, fn key, s ->
      if Map.get(s, key) == nil, do: refresh_async(s, key), else: s
    end)

    {:reply, {state.tools || [], state.resources || [], state.prompts || []}, state}
  end

  def handle_call(:refresh, _from, state) do
    state = Enum.reduce([:tools, :resources, :resource_templates, :prompts], state, &refresh_async(&2, &1))
    {:reply, {state.tools, state.resources, state.resource_templates, state.prompts}, state}
  end

  def handle_call({:call_tool, tool, args}, from, state),
    do: {:noreply, start_request(state, from, "tools/call", %{"name" => to_string(tool), "arguments" => args})}

  def handle_call({:read_resource, uri}, from, state),
    do: {:noreply, start_request(state, from, "resources/read", %{"uri" => uri})}

  def handle_call({:get_prompt, name, args}, from, state),
    do: {:noreply, start_request(state, from, "prompts/get", %{"name" => to_string(name), "arguments" => args})}

  def handle_call({:subscribe_resource, uri}, from, state),
    do: {:noreply, start_request(state, from, "resources/subscribe", %{"uri" => uri})}

  def handle_call({:unsubscribe_resource, uri}, from, state),
    do: {:noreply, start_request(state, from, "resources/unsubscribe", %{"uri" => uri})}

  def handle_call({:request, method, params}, from, state),
    do: {:noreply, start_request(state, from, method, params)}

  def handle_call({:listen, params}, from, state),
    do: {:noreply, start_request(state, from, "subscriptions/listen", params)}

  def handle_call(msg, _from, state) do
    Logger.info("mcp #{state.id}: ignored #{inspect(msg, limit: 5)}")
    {:reply, {:error, :unknown_call}, state}
  end

  # ---- transport --------------------------------------------------------------

  defp open(%{config: %{transport: :stdio} = config} = state) do
    [program | args] = config.command || []

    case System.find_executable(program) do
      nil ->
        {:error, {:program_not_found, program}, state}

      path ->
        env = Enum.map(config.env || [], fn {k, v} -> {to_charlist(to_string(k)), to_charlist(to_string(v))} end)

        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :hide,
            :stderr_to_stdout,
            args: Enum.map(args, &to_string/1),
            env: env,
            cd: config[:dir] || Nano.Util.app_dir()
          ])

        {:ok, %{state | port: port, buffer: ""}}
    end
  rescue
    e -> {:error, e, state}
  end

  defp open(%{config: %{transport: :http}} = state), do: {:ok, state}
  defp open(%{config: config} = state), do: {:error, {:unknown_transport, config[:transport]}, state}

  defp write(%{config: %{transport: :stdio}} = state, message) do
    if state.port do
      send(state.port, {self(), {:command, P.encode(message) <> "\n"}})
      {:ok, state, []}
    else
      {:error, :not_connected, state}
    end
  end

  defp write(%{config: %{transport: :http} = config} = state, message) do
    headers =
      %{"accept" => "application/json, text/event-stream", "content-type" => "application/json"}
      |> Map.merge(config.headers || %{})
      |> then(fn h -> if state.session, do: Map.put(h, "mcp-session-id", state.session), else: h end)
      |> then(fn h -> if state.version, do: Map.put(h, "mcp-protocol-version", state.version), else: h end)

    case Req.post(config.url, json: message, headers: headers, retry: false, receive_timeout: 600_000) do
      {:ok, %{status: status, body: body, headers: rh}} when status in [200, 201, 202] ->
        state = remember_session(state, rh)
        {:ok, state, http_messages(body, rh)}

      {:ok, %{status: 400} = resp} ->
        # A modern server rejects a malformed/mismatched request with 400 + a JSON-RPC error.
        {:error, {:http, 400, resp.body, resp.headers}, state}

      {:ok, %{status: 404}} ->
        {:error, :session_expired, %{state | session: nil}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}, state}

      {:error, e} ->
        {:error, {:transport, e}, state}
    end
  end

  defp write(state, _message), do: {:error, :no_transport, state}

  defp remember_session(state, headers) do
    case header(headers, "mcp-session-id") do
      nil -> state
      id -> %{state | session: id}
    end
  end

  defp header(headers, name) do
    headers
    |> Enum.filter(fn {k, _} -> String.downcase(to_string(k)) == name end)
    |> Enum.map(fn {_, v} -> v |> List.wrap() |> List.last() |> to_string() end)
    |> List.first()
  end

  defp http_messages(body, headers) do
    ct = header(headers, "content-type") || "application/json"

    cond do
      String.contains?(ct, "text/event-stream") and is_binary(body) -> P.decode_sse(body)
      is_binary(body) -> P.decode_body(body)
      is_map(body) -> [body]
      is_list(body) -> body
      true -> []
    end
  end

  # ---- the era probe ----------------------------------------------------------

  # Probe first, as the stdio binding prescribes:
  #   DiscoverResult -> modern; use a supported version.
  #   UnsupportedProtocolVersionError, or an equivalent modern error -> modern; pick from its list.
  #   anything else, or silence -> legacy; do the initialize handshake.
  defp probe(state) do
    id = next_id(state)
    state = %{state | waiting: Map.put(state.waiting, id, {:probe, System.monotonic_time(:millisecond)})}
    timer = Process.send_after(self(), {:mcp_timeout, id}, 4_000)
    message = request_message(%{state | next_id: id}, id, "server/discover", %{}, modern: true)

    case write(state, message) do
      {:ok, state, messages} -> Enum.reduce(messages, %{state | probe_timer: timer}, &handle_message(&2, &1))
      {:error, _reason, state} -> fallback(state)
    end
  end

  defp fallback(state) do
    if state.probe_timer, do: Process.cancel_timer(state.probe_timer)
    initialize(state, @legacy_versions)
  end

  defp initialize(state, versions) do
    [version | rest] = versions
    id = next_id(state)

    params = %{
      "protocolVersion" => version,
      "capabilities" => client_capabilities(),
      "clientInfo" => client_info()
    }

    message = %{"jsonrpc" => "2.0", "id" => id, "method" => "initialize", "params" => params}
    state = %{state | waiting: Map.put(state.waiting, id, {:initialize, rest}), version: nil}

    case write(state, message) do
      {:ok, state, messages} -> Enum.reduce(messages, state, &handle_message(&2, &1))
      {:error, reason, state} ->
        Logger.warning("mcp " <> state.id <> ": initialize write failed: " <> inspect(reason))
        schedule_reconnect(state)
    end
  end

  defp after_initialize(state, version, result) do
    state = %{
      state
      | era: :legacy,
        version: version,
        server_info: result["serverInfo"],
        capabilities: result["capabilities"] || %{},
        instructions: result["instructions"]
    }

    case write(state, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}) do
      {:ok, state, _} -> refresh_all(state)
      {:error, _reason, state} -> schedule_reconnect(state)
    end
  end

  # After a successful discover: modern era, negotiated version, then fetch the catalogues.
  defp after_probe(state, result) do
    supported = result["supportedVersions"] || result["supported"] || [@modern]
    {version, _rest} = pick_version(supported)

    state = %{
      state
      | era: :modern,
        version: version,
        server_info: result["serverInfo"],
        capabilities: result["capabilities"] || %{},
        instructions: result["instructions"]
    }

    refresh_all(state)
  end

  defp pick_version(supported) do
    if @modern in supported, do: {@modern, supported}, else: {List.first(supported) || @modern, supported}
  end

  ## Requests

  defp next_id(state), do: state.next_id + 1

  defp request_message(state, id, method, params, opts) do
    base = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    if Keyword.get(opts, :modern, state.era == :modern) do
      Map.put(base, "params", Map.put(params, "_meta", request_meta(state)))
    else
      base
    end
  end

  defp request_meta(state) do
    %{
      "io.modelcontextprotocol/protocolVersion" => state.version || @modern,
      "io.modelcontextprotocol/clientInfo" => client_info(),
      "io.modelcontextprotocol/clientCapabilities" => client_capabilities()
    }
  end

  defp client_info, do: %{"name" => "nano-mcp-client", "version" => "0.1.0"}

  defp client_capabilities do
    %{
      "roots" => %{"listChanged" => true},
      "elicitation" => %{},
      "sampling" => %{}
    }
  end

  defp start_request(%{era: nil} = state, from, _method, _params) do
    # Probed but not yet negotiated: the caller may retry in a moment.
    GenServer.reply(from, {:error, :not_ready})
    state
  end

  defp start_request(state, from, method, params) do
    id = next_id(state)
    state = %{state | next_id: id, waiting: Map.put(state.waiting, id, from)}
    message = request_message(state, id, method, params, [])

    case write(state, message) do
      {:ok, state, messages} ->
        Process.send_after(self(), {:mcp_timeout, id}, @request_timeout)
        Enum.reduce(messages, state, &handle_message(&2, &1))

      {:error, reason, state} ->
        GenServer.reply(from, {:error, reason})
        %{state | waiting: Map.delete(state.waiting, id)}
    end
  end

  # The waiting entry decides how the response is routed. Internal bookkeeping is tagged with a
  # leading atom; anything else is a real GenServer `from` and gets a reply.
  defp reply(state, id, response) do
    case Map.pop(state.waiting, id) do
      {nil, _} ->
        Logger.info("mcp #{state.id}: response to unknown id #{id}")
        state

      {{:probe, _started}, waiting} ->
        state = %{state | waiting: waiting, probe_timer: nil}

        case response do
          {:ok, result} -> after_probe(state, result)
          {:error, {:mcp_error, %{"code" => code}}} when code in [-32022, -32021] -> after_probe(state, %{})
          {:error, _reason} -> fallback(state)
        end

      {{:initialize, rest}, waiting} ->
        state = %{state | waiting: waiting}

        case response do
          {:ok, result} ->
            after_initialize(state, result["protocolVersion"] || List.first(@legacy_versions), result)

          {:error, _} when rest != [] ->
            initialize(state, rest)

          {:error, reason} ->
            Logger.warning("mcp #{state.id}: initialize failed: #{inspect(reason)}")
            schedule_reconnect(close(state))
        end

      {{:list_noreply, key, result_key}, waiting} ->
        state = %{state | waiting: waiting}
        state = case response do
          {:ok, result} -> Map.put(state, key, result[result_key] || [])
          {:error, {:mcp_error, %{"code" => -32601}}} -> Map.put(state, key, [])
          _ -> state
        end
        state

      {{:list, key, result_key, from}, waiting} ->
        state = %{state | waiting: waiting}
        state = case response do
          {:ok, result} -> Map.put(state, key, result[result_key] || [])
          {:error, {:mcp_error, %{"code" => -32601}}} -> Map.put(state, key, [])
          _ -> state
        end
        GenServer.reply(from, Map.get(state, key, []))
        state

      {from, waiting} ->
        GenServer.reply(from, response)
        %{state | waiting: waiting}
    end
  end


  defp unwrap(%{"result" => result}), do: {:ok, P.normalize_result(result)}
  defp unwrap(%{"error" => error}), do: {:error, {:mcp_error, error}}
  defp unwrap(other), do: {:error, {:bad_response, other}}

  ## Incoming

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state),
    do: {:noreply, consume(%{state | buffer: state.buffer <> data})}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("mcp #{state.id}: server exited (#{status})")
    {:noreply, schedule_reconnect(close(state))}
  end

  def handle_info(:reconnect, state), do: {:noreply, state, {:continue, :connect}}

  def handle_info({:mcp_timeout, id}, state) do
    case state.waiting[id] do
      :probe -> {:noreply, fallback(%{state | waiting: Map.delete(state.waiting, id)})}
      nil -> {:noreply, state}
      _ -> {:noreply, reply(state, id, {:error, :timeout})}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close(state)
    :ok
  end

  defp close(state) do
    if state.port, do: catch_close(state.port)
    for {_id, from} <- state.waiting, is_from?(from), do: GenServer.reply(from, {:error, :disconnected})
    %{state | port: nil, session: nil, era: nil, version: nil, buffer: "", waiting: %{}}
  end

  # A waiting entry is a real caller only when it is a GenServer `from`; probe/list entries
  # are bookkeeping and must not be replied to.
  defp is_from?({pid, _ref}) when is_pid(pid), do: true
  defp is_from?(_), do: false

  defp catch_close(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  defp consume(state) do
    case P.take_message(state.buffer) do
      {:ok, message, rest} -> %{state | buffer: rest} |> handle_message(message) |> consume()
      :more -> state
      {:invalid, reason, rest} ->
        Logger.warning("mcp #{state.id}: bad message: #{inspect(reason)}")
        consume(%{state | buffer: rest})
    end
  end

  defp handle_message(state, %{"id" => id} = response) when is_integer(id), do: reply(state, id, unwrap(response))

  defp handle_message(state, %{"method" => "ping", "id" => id}) do
    _ = write(state, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
    state
  end

  defp handle_message(state, %{"method" => "roots/list", "id" => id}) do
    _ = write(state, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"roots" => []}})
    state
  end

  defp handle_message(state, %{"method" => "notifications/tools/list_changed"}) do
    forward(state, "notifications/tools/list_changed", %{})
    refresh_async(%{state | tools: nil}, :tools)
  end

  defp handle_message(state, %{"method" => "notifications/resources/list_changed"}) do
    forward(state, "notifications/resources/list_changed", %{})
    %{state | resources: nil, resource_templates: nil}
  end

  defp handle_message(state, %{"method" => "notifications/prompts/list_changed"}) do
    forward(state, "notifications/prompts/list_changed", %{})
    refresh_async(%{state | prompts: nil}, :prompts)
  end

  defp handle_message(state, %{"method" => "notifications/resources/updated", "params" => params}) do
    forward(state, "notifications/resources/updated", params, params["uri"])
    state
  end

  defp handle_message(state, %{"method" => method} = message) do
    forward(state, method, message["params"] || %{})
    state
  end

  defp handle_message(state, _other), do: state

  defp forward(state, method, params, uri \\ nil) do
    Nano.MCP.deliver(state.id, uri, {:mcp, %{server: state.id, method: method, params: params}})
  end

  ## Catalogues
  ## Catalogues
  #
  # A read answers from the cache; a cold cache sends the list request and *defers* the
  # caller's reply until it arrives, so a caller that reads right after `connect/3` gets the
  # catalogue instead of an empty list, and the process keeps draining the transport meanwhile.

  defp catalogue_call(state, key, from) do
    case Map.get(state, key) do
      nil -> {:noreply, refresh_deferred(state, key, from)}
      cached -> {:reply, cached, state}
    end
  end

  defp refresh_deferred(state, key, from) do
    {method, result_key} = list_request(key)
    id = next_id(state)
    message = request_message(%{state | next_id: id}, id, method, %{}, [])
    state = %{state | waiting: Map.put(state.waiting, id, {:list, key, result_key, from})}

    case write(state, message) do
      {:ok, state, messages} ->
        Process.send_after(self(), {:mcp_timeout, id}, @request_timeout)
        Enum.reduce(messages, state, &handle_message(&2, &1))

      {:error, reason, state} ->
        GenServer.reply(from, {:error, reason})
        %{state | waiting: Map.delete(state.waiting, id)}
    end
  end

  # Non-blocking refresh: after initialize/discover, and on list_changed notifications.
  defp refresh_async(state, key) do
    if state.era == nil do
      state
    else
      {method, result_key} = list_request(key)
      id = next_id(state)
      message = request_message(%{state | next_id: id}, id, method, %{}, [])
      state = %{state | waiting: Map.put(state.waiting, id, {:list_noreply, key, result_key})}

      case write(state, message) do
        {:ok, state, messages} -> Enum.reduce(messages, state, &handle_message(&2, &1))
        {:error, _reason, state} -> %{state | waiting: Map.delete(state.waiting, id)}
      end
    end
  end

  defp refresh_all(state),
    do: Enum.reduce([:tools, :resources, :resource_templates, :prompts], state, &refresh_async(&2, &1))

  defp list_request(:tools), do: {"tools/list", "tools"}
  defp list_request(:resources), do: {"resources/list", "resources"}
  defp list_request(:resource_templates), do: {"resources/templates/list", "resourceTemplates"}
  defp list_request(:prompts), do: {"prompts/list", "prompts"}


  defp schedule_reconnect(state) do
    Process.send_after(self(), :reconnect, @reconnect_ms)
    state
  end

  defp info(state) do
    %{
      id: state.id,
      transport: state.config.transport,
      era: state.era,
      protocolVersion: state.version,
      serverInfo: state.server_info,
      capabilities: state.capabilities,
      instructions: state.instructions,
      connected: state.era != nil
    }
  end
end

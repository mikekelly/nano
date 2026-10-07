defmodule Nano.MCP.Server do
  @moduledoc """
  One connection to an MCP server, as a `GenServer`. stdio servers are subprocesses driven
  over a port; streamable-HTTP servers are driven with `Req`. The connection is supervised
  and reconnects (with backoff) when the transport drops.

  Requests are asynchronous inside this process: the caller's `GenServer.call` `from` is
  kept in `waiting`, keyed by JSON-RPC id, and the reply goes out when the matching response
  arrives. Nothing blocks the loop, so a slow tool call cannot queue notifications behind it
  and the transport is always drained.

  The connection keeps the negotiated session (protocol version, server info, capabilities)
  and caches the server's tools, resources and prompts, invalidated by
  `notifications/*/list_changed`. Notifications are forwarded with `Nano.MCP.deliver/3`;
  a server's client-directed requests (`ping`, `roots/list`) are answered here.
  """

  use GenServer
  require Logger

  alias Nano.MCP.Protocol, as: P

  @pv "2025-06-18"
  @reconnect_ms 2_000
  @request_timeout 120_000

  def start_link({id, config}), do: GenServer.start_link(__MODULE__, {id, config})

  def child_spec({id, config}) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [{id, config}]},
      restart: :permanent,
      type: :worker
    }
  end

  ## GenServer

  @impl true
  def init({id, config}) do
    state = %{
      id: id,
      config: config,
      port: nil,
      session: nil,
      next_id: 0,
      waiting: %{},
      buffer: "",
      tools: nil,
      resources: nil,
      resource_templates: nil,
      prompts: nil,
      info: %{
        id: id,
        transport: config.transport,
        connected_at: nil,
        serverInfo: nil,
        capabilities: nil,
        instructions: nil,
        protocolVersion: nil
      }
    }

    {:ok, state, {:continue, :connect}}
  end

  # Connecting is asynchronous too: the initialize request goes out with a `self()` waiter,
  # and the loop stays free to read the transport. The reply arrives as `{:mcp_self, …}`.
  @impl true
  def handle_continue(:connect, state) do
    case ensure_registered(state) do
      {:ok, state} ->
        case open(state) do
          {:ok, state} ->
            Process.send_after(self(), :initialize_timeout, 30_000)
            {:noreply, self_request(state, "initialize", initialize_params(), 30_000)}

          {:error, reason, state} ->
            Logger.warning("mcp #{state.id}: could not start: #{inspect(reason)}")
            {:noreply, schedule_reconnect(state)}
        end

      {:error, reason, state} ->
        Logger.warning("mcp #{state.id}: could not register: #{inspect(reason)}")
        {:noreply, schedule_reconnect(state)}
    end
  end

  # The registry maps a server id to this process, so `Nano.MCP` can find it without a call.
  defp ensure_registered(state) do
    if Registry.lookup(Nano.MCP.Registry, state.id) == [] do
      case Registry.register(Nano.MCP.Registry, state.id, nil) do
        {:ok, _} -> {:ok, state}
        {:error, {:already_registered, _}} -> {:ok, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, state.info, state}

  def handle_call(:connected?, _from, state),
    do: {:reply, state.port != nil or state.session != nil, state}

  def handle_call(:ping, from, state), do: {:noreply, start_request(state, from, "ping", %{})}
  def handle_call(:tools, _from, state), do: {:reply, catalogue(state, :tools), state}
  def handle_call(:resources, _from, state), do: {:reply, catalogue(state, :resources), state}

  def handle_call(:resource_templates, _from, state),
    do: {:reply, catalogue(state, :resource_templates), state}

  def handle_call(:prompts, _from, state), do: {:reply, catalogue(state, :prompts), state}

  def handle_call(:catalogue, _from, state) do
    {:reply, {catalogue(state, :tools), catalogue(state, :resources), catalogue(state, :prompts)},
     state}
  end

  def handle_call(:refresh, _from, state) do
    state = refresh_async_all_fresh(state)
    {:reply, {state.tools, state.resources, state.resource_templates, state.prompts}, state}
  end

  def handle_call({:call_tool, tool, args}, from, state),
    do:
      {:noreply,
       start_request(state, from, "tools/call", %{"name" => to_string(tool), "arguments" => args})}

  def handle_call({:read_resource, uri}, from, state),
    do: {:noreply, start_request(state, from, "resources/read", %{"uri" => uri})}

  def handle_call({:get_prompt, name, args}, from, state),
    do:
      {:noreply,
       start_request(state, from, "prompts/get", %{"name" => to_string(name), "arguments" => args})}

  def handle_call({:subscribe_resource, uri}, from, state),
    do: {:noreply, start_request(state, from, "resources/subscribe", %{"uri" => uri})}

  def handle_call({:unsubscribe_resource, uri}, from, state),
    do: {:noreply, start_request(state, from, "resources/unsubscribe", %{"uri" => uri})}

  def handle_call({:request, method, params}, from, state),
    do: {:noreply, start_request(state, from, method, params)}

  def handle_call(msg, _from, state) do
    Logger.info("mcp #{state.id}: ignored call #{inspect(msg, limit: 5)}")
    {:reply, {:error, :unknown_call}, state}
  end

  defp refresh_async_all_fresh(state) do
    state =
      Enum.reduce(
        [:tools, :resources, :resource_templates, :prompts],
        %{state | tools: nil, resources: nil, resource_templates: nil, prompts: nil},
        &refresh_async(&2, &1)
      )

    state
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, consume(%{state | buffer: state.buffer <> data})}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("mcp #{state.id}: server exited (#{status})")
    {:noreply, schedule_reconnect(close(state))}
  end

  def handle_info(:reconnect, state), do: {:noreply, state, {:continue, :connect}}

  def handle_info({:mcp_self, {:ok, result}}, state) do
    state = %{
      state
      | info:
          Map.merge(state.info, %{
            serverInfo: result["serverInfo"],
            capabilities: result["capabilities"] || %{},
            instructions: result["instructions"],
            protocolVersion: result["protocolVersion"],
            connected_at: now()
          })
    }

    case write(state, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}) do
      {:ok, state, _} -> {:noreply, refresh_all(state)}
      {:error, _reason, state} -> {:noreply, schedule_reconnect(close(state))}
    end
  end

  def handle_info({:mcp_self, {:error, reason}}, state) do
    Logger.warning("mcp #{state.id}: initialize failed: #{inspect(reason)}")
    {:noreply, schedule_reconnect(close(state))}
  end

  def handle_info(:initialize_timeout, %{info: %{protocolVersion: nil}} = state) do
    Logger.warning("mcp #{state.id}: initialize timed out")
    {:noreply, schedule_reconnect(close(state))}
  end

  def handle_info(:initialize_timeout, state), do: {:noreply, state}

  def handle_info({:mcp_timeout, id}, state) do
    if Map.has_key?(state.waiting, id) do
      {:noreply, reply(state, id, {:error, :timeout})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:mcp_response, _id, _} = msg, state) do
    {:noreply, handle_message(state, elem(msg, 2))}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close(state)
    :ok
  end

  ## Transport

  defp open(%{config: %{transport: :stdio} = config} = state) do
    [program | args] = config.command || []

    case System.find_executable(program) do
      nil ->
        {:error, {:program_not_found, program}, state}

      path ->
        env = Enum.map(config.env || [], fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :hide,
            :stderr_to_stdout,
            args: args,
            env: env,
            cd: Nano.Util.app_dir()
          ])

        {:ok, %{state | port: port, buffer: ""}}
    end
  rescue
    e -> {:error, e, state}
  end

  defp open(%{config: %{transport: :http}} = state), do: {:ok, state}

  defp open(%{config: config} = state),
    do: {:error, {:unknown_transport, Map.get(config, :transport)}, state}

  defp close(state) do
    if state.port, do: catch_close(state.port)
    for {_id, from} <- state.waiting, do: GenServer.reply(from, {:error, :disconnected})
    %{state | port: nil, session: nil, buffer: "", waiting: %{}}
  end

  defp catch_close(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  defp write(%{config: %{transport: :stdio}} = state, message) do
    if state.port do
      send(state.port, {self(), {:command, Jason.encode!(message) <> "\n"}})
      {:ok, state, []}
    else
      {:error, :not_connected, state}
    end
  end

  # HTTP has no persistent connection: the response to a POST is read right here. Returned
  # messages are handled by the caller *after* it has registered its waiter, so a response
  # is never dropped for arriving before the id was remembered.
  defp write(%{config: %{transport: :http} = config} = state, message) do
    headers =
      %{
        "accept" => "application/json, text/event-stream",
        "mcp-protocol-version" => state.info.protocolVersion || @pv
      }
      |> Map.merge(config.headers || %{})
      |> then(fn h ->
        if state.session, do: Map.put(h, "mcp-session-id", state.session), else: h
      end)

    case Req.post(config.url,
           json: message,
           headers: headers,
           retry: false,
           receive_timeout: 600_000
         ) do
      {:ok, %{status: status, body: body, headers: resp_headers}} when status in [200, 202] ->
        state = remember_session(state, resp_headers)
        {:ok, state, http_messages(body, resp_headers)}

      {:ok, %{status: 404}} ->
        {:error, :session_expired, %{state | session: nil}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}, state}

      {:error, e} ->
        {:error, {:transport, e}, state}
    end
  end

  defp write(state, _message), do: {:error, :not_connected, state}

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
    content_type = header(headers, "content-type") || "application/json"

    cond do
      String.contains?(content_type, "text/event-stream") -> P.decode_sse(to_string(body))
      is_binary(body) -> P.decode_body(body)
      is_map(body) -> [body]
      is_list(body) -> body
      true -> []
    end
  end

  ## Requests

  # A request whose reply goes back into this mailbox; used for the initialize handshake.
  defp self_request(state, method, params, timeout) do
    id = state.next_id + 1
    state = %{state | next_id: id, waiting: Map.put(state.waiting, id, {self(), :self})}
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    case write(state, message) do
      {:ok, state, messages} ->
        Process.send_after(self(), {:mcp_timeout, id}, timeout)
        Enum.reduce(messages, state, &handle_message(&2, &1))

      {:error, _reason, state} ->
        state
    end
  end

  defp start_request(state, from, method, params) do
    id = state.next_id + 1
    state = %{state | next_id: id, waiting: Map.put(state.waiting, id, from)}
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    case write(state, message) do
      {:ok, state, messages} ->
        Process.send_after(self(), {:mcp_timeout, id}, @request_timeout)
        Enum.reduce(messages, state, &handle_message(&2, &1))

      {:error, reason, state} ->
        GenServer.reply(from, {:error, reason})
        %{state | waiting: Map.delete(state.waiting, id)}
    end
  end

  defp reply(state, id, response) do
    me = self()

    case Map.pop(state.waiting, id) do
      {nil, _} ->
        Logger.info("mcp #{state.id}: response to unknown id #{id}")
        state

      {{^me, :self}, waiting} ->
        send(me, {:mcp_self, response})
        %{state | waiting: waiting}

      {{:list, key, result_key}, waiting} ->
        case response do
          {:ok, result} -> Map.put(%{state | waiting: waiting}, key, result[result_key] || [])
          _ -> %{state | waiting: waiting}
        end

      {from, waiting} ->
        GenServer.reply(from, response)
        %{state | waiting: waiting}
    end
  end

  defp unwrap(%{"result" => result}), do: {:ok, P.normalize_result(result)}
  defp unwrap(%{"error" => error}), do: {:error, {:mcp_error, error}}
  defp unwrap(other), do: {:error, {:bad_response, other}}

  defp initialize_params do
    %{
      "protocolVersion" => @pv,
      "capabilities" => %{"roots" => %{"listChanged" => true}},
      "clientInfo" => %{"name" => "nano", "version" => "0.1.0"}
    }
  end

  ## Incoming

  defp consume(state) do
    case P.take_message(state.buffer) do
      {:ok, message, rest} ->
        %{state | buffer: rest} |> handle_message(message) |> consume()

      :more ->
        state

      {:invalid, reason, rest} ->
        Logger.warning("mcp #{state.id}: bad message: #{inspect(reason)}")
        consume(%{state | buffer: rest})
    end
  end

  defp handle_message(state, %{"id" => id} = response) when is_integer(id),
    do: reply(state, id, unwrap(response))

  defp handle_message(state, %{"method" => "ping", "id" => id}) do
    {:ok, state, _} = write(state, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
    state
  end

  defp handle_message(state, %{"method" => "roots/list", "id" => id}) do
    {:ok, state, _} =
      write(state, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"roots" => []}})

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
  #
  # A catalogue read must not block the loop (the transport has to be drained), so `tools/1`
  # and friends return whatever is cached and ask the server to refresh it in the background
  # when the cache is cold. `refresh/1` forces a fetch and waits for it.

  defp catalogue(state, key) do
    case Map.get(state, key) do
      nil ->
        # Cold cache: ask for the list, then a later read finds it. (The reply is delivered
        # asynchronously; a caller wanting a fresh list in the same call uses `refresh/1`.)
        _state = refresh_async(state, key)
        []

      cached ->
        cached
    end
  end

  @doc "Forces a fresh fetch of the catalogues and returns them; call via `Nano.MCP`."
  def refresh(pid), do: GenServer.call(pid, :refresh, 60_000)

  # Sends list requests and remembers their ids by key; the replies land in `handle_message`.
  defp refresh_async(state, key) do
    {method, result_key} = list_request(key)
    id = state.next_id + 1
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => %{}}

    case write(%{state | next_id: id}, message) do
      {:ok, state, messages} ->
        # Register the waiter before draining the response, so an immediate reply is routed.
        state = %{state | waiting: Map.put(state.waiting, id, {:list, key, result_key})}
        Enum.reduce(messages, state, &handle_message(&2, &1))

      {:error, _reason, state} ->
        state
    end
  end

  defp list_request(:tools), do: {"tools/list", "tools"}
  defp list_request(:resources), do: {"resources/list", "resources"}
  defp list_request(:resource_templates), do: {"resources/templates/list", "resourceTemplates"}
  defp list_request(:prompts), do: {"prompts/list", "prompts"}

  defp refresh_all(state) do
    Enum.reduce(
      [:tools, :resources, :resource_templates, :prompts],
      state,
      &refresh_async(&2, &1)
    )
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :reconnect, @reconnect_ms)
    state
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end

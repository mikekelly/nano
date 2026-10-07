defmodule Seedling.MCP.HTTP do
  @moduledoc """
  Streamable HTTP transport. `start_link(config, owner)` starts an independent
  connection; `send_message/2` never waits for network I/O. Events are
  `{:mcp_message, transport, map}` and `{:mcp_transport_down, transport, reason}`.
  Supports revision 2026-07-28 and legacy 2025-11-25.
  Config keys: url, headers, timeout (30s), max_bytes (1MiB), listen (true),
  stream_timeout (24h wall cap for long notification streams).
  `register_tools/2` validates/caches x-mcp-header annotations and returns
  valid definitions. tools/list replies also update this cache automatically.
  HTTP redirects and automatic retries are disabled (credentials are not leaked
  and non-idempotent tool calls are not replayed). Legacy SSE resumption uses
  GET only; modern streams never resume implicitly. Long streams bound retained
  data per event rather than lifetime bytes. Core owns reconnection on failure.
  """
  use GenServer

  def start_link(config, owner), do: GenServer.start_link(__MODULE__, {config, owner})
  def send_message(pid, message), do: GenServer.call(pid, {:send, message})
  def set_version(pid, version), do: GenServer.call(pid, {:version, version})
  def register_tools(pid, tools), do: GenServer.call(pid, {:tools, tools})
  def close(pid), do: GenServer.stop(pid, :normal)

  def init({config, owner}) do
    url = get(config, :url, nil)

    if is_binary(url) and URI.parse(url).scheme in ["http", "https"] do
      Process.monitor(owner)

      {:ok,
       %{
         config: config,
         owner: owner,
         session: nil,
         version: nil,
         jobs: %{},
         listening: false,
         tools: %{}
       }}
    else
      {:stop, :invalid_url}
    end
  end

  def handle_call({:tools, tools}, _, state) do
    {message, state} = learn_tools(%{"result" => %{"tools" => tools}}, state)
    {:reply, message["result"]["tools"], state}
  end

  def handle_call({:version, version}, _, state), do: {:reply, :ok, %{state | version: version}}

  def handle_call({:send, message}, _, state) when is_map(message) do
    version =
      get_in(message, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"]) ||
        state.version

    state = %{state | version: version}
    state = start_job(state, :post, message, nil)

    state =
      if not modern?(state.version) and message["method"] == "notifications/initialized" and
           get(state.config, :listen, true) and
           not state.listening do
        start_job(%{state | listening: true}, :get, nil, nil)
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_info({:headers, worker, headers}, state) do
    session = List.first(Map.get(headers, "mcp-session-id", []))

    if not modern?(state.version) and Map.has_key?(state.jobs, worker) and is_binary(session) and
         Regex.match?(~r/^[\x21-\x7e]+$/, session) do
      {:noreply, %{state | session: session}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:message, worker, message}, state) do
    if Map.has_key?(state.jobs, worker) do
      {message, state} = learn_tools(message, state)
      send(state.owner, {:mcp_message, self(), message})
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:finished, worker, result}, state) do
    case Map.pop(state.jobs, worker) do
      {nil, _} ->
        {:noreply, state}

      {job, jobs} ->
        cancel_timer(job.timer)
        Process.demonitor(job.ref, [:flush])
        state = %{state | jobs: jobs}

        case result do
          {:resume, id, retry} ->
            if job.kind == :get or id != nil do
              wait = min(retry, max(0, job.deadline - System.monotonic_time(:millisecond)))
              Process.send_after(self(), {:resume, job, id}, wait)
              {:noreply, state}
            else
              down(state, :disconnected_without_event_id)
            end

          :ok ->
            {:noreply, state}

          {:error, reason} ->
            down(state, reason)
        end
    end
  end

  def handle_info({:resume, job, id}, state) do
    if System.monotonic_time(:millisecond) < job.deadline do
      {:noreply, start_job(state, :get, job.message, id, job.deadline)}
    else
      down(state, :timeout)
    end
  end

  def handle_info({:timeout, worker}, state) do
    case Map.pop(state.jobs, worker) do
      {nil, _} ->
        {:noreply, state}

      {job, jobs} ->
        Process.exit(worker, :kill)
        Process.demonitor(job.ref, [:flush])
        down(%{state | jobs: jobs}, :timeout)
    end
  end

  def handle_info({:DOWN, _, :process, pid, reason}, state) do
    cond do
      pid == state.owner ->
        {:stop, :normal, state}

      Map.has_key?(state.jobs, pid) ->
        {job, jobs} = Map.pop(state.jobs, pid)
        cancel_timer(job.timer)
        down(%{state | jobs: jobs}, {:worker_exit, reason})

      true ->
        {:noreply, state}
    end
  end

  def terminate(_, state) do
    Enum.each(state.jobs, fn {pid, _} -> Process.exit(pid, :kill) end)

    if state.session do
      config = state.config
      headers = headers(state, :delete, nil)

      spawn(fn ->
        Req.request(
          method: :delete,
          url: get(config, :url, nil),
          headers: headers,
          retry: false,
          redirect: false,
          receive_timeout: 2000
        )
      end)
    end

    :ok
  end

  defp down(state, reason) do
    send(state.owner, {:mcp_transport_down, self(), reason})
    {:noreply, state}
  end

  defp start_job(state, kind, message, id, deadline \\ nil) do
    long = kind == :get or (is_map(message) and message["method"] == "subscriptions/listen")

    timeout =
      if long,
        do: get(state.config, :stream_timeout, 86_400_000),
        else: get(state.config, :timeout, 30_000)

    deadline = deadline || System.monotonic_time(:millisecond) + timeout
    remaining = max(1, deadline - System.monotonic_time(:millisecond))
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          run(
            parent,
            state.config,
            kind,
            message,
            headers(state, kind, id, message),
            remaining,
            id
          )

        send(parent, {:finished, self(), result})
      end)

    timer = Process.send_after(self(), {:timeout, pid}, remaining)
    job = %{kind: kind, message: message, deadline: deadline, ref: ref, timer: timer}
    %{state | jobs: Map.put(state.jobs, pid, job)}
  end

  defp headers(state, kind, id, message \\ nil) do
    base =
      get(state.config, :headers, %{})
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), v} end)
      |> Map.new()

    base =
      Map.drop(base, [
        "accept",
        "content-type",
        "mcp-session-id",
        "mcp-protocol-version",
        "last-event-id"
      ])

    base =
      Map.put(
        base,
        "accept",
        if(kind == :post, do: "application/json, text/event-stream", else: "text/event-stream")
      )

    base = if kind == :post, do: Map.put(base, "content-type", "application/json"), else: base

    base =
      if not is_nil(state.session) and not modern?(state.version),
        do: Map.put(base, "mcp-session-id", state.session),
        else: base

    base = if state.version, do: Map.put(base, "mcp-protocol-version", state.version), else: base
    base = if id, do: Map.put(base, "last-event-id", id), else: base

    if kind == :post and modern?(state.version),
      do: metadata_headers(base, message, state.tools),
      else: base
  end

  defp get(config, key, default),
    do: Map.get(config, key, Map.get(config, Atom.to_string(key), default))

  defp run(parent, config, kind, message, headers, timeout, id) do
    cap = get(config, :max_bytes, 1_048_576)

    Process.put(:stream, %{
      buffer: "",
      data: [],
      id: id,
      retry: 1000,
      bytes: 0,
      complete: false,
      sse: false,
      headers: false
    })

    callback = fn {:data, chunk}, {req, resp} ->
      stream = Process.get(:stream)
      unless stream.headers, do: send(parent, {:headers, self(), resp.headers})

      sse =
        String.starts_with?(
          List.first(Map.get(resp.headers, "content-type", [])) || "",
          "text/event-stream"
        )

      if byte_size(chunk) + stream.bytes > cap, do: throw(:response_too_large)

      stream = %{
        stream
        | headers: true,
          sse: sse,
          bytes: stream.bytes + byte_size(chunk),
          buffer: stream.buffer <> chunk
      }

      stream =
        if sse and resp.status in 200..299, do: parse_lines(stream, parent, message), else: stream

      stream =
        if sse and (kind == :get or message["method"] == "subscriptions/listen"),
          do: %{
            stream
            | bytes: byte_size(stream.buffer) + Enum.reduce(stream.data, 0, &(byte_size(&1) + &2))
          },
          else: stream

      Process.put(:stream, stream)
      if stream.complete, do: {:halt, {req, resp}}, else: {:cont, {req, resp}}
    end

    opts = [
      method: kind,
      url: get(config, :url, nil),
      headers: headers,
      retry: false,
      redirect: false,
      decode_body: false,
      receive_timeout: timeout,
      connect_options: [timeout: min(timeout, 10_000)],
      into: callback
    ]

    opts = if kind == :post, do: Keyword.put(opts, :body, Jason.encode!(message)), else: opts

    case Req.request(opts) do
      {:ok, resp} ->
        send(parent, {:headers, self(), resp.headers})
        stream = Process.get(:stream)

        cond do
          resp.status == 405 and kind == :get ->
            :ok

          resp.status == 404 and Map.has_key?(headers, "mcp-session-id") ->
            {:error, :session_expired}

          resp.status not in 200..299 ->
            case Jason.decode(stream.buffer) do
              {:ok, value} when is_map(value) ->
                if Map.has_key?(value, "error"), do: send(parent, {:message, self(), value})

                if Map.has_key?(value, "error"),
                  do: :ok,
                  else: {:error, {:http_status, resp.status}}

              _ ->
                {:error, {:http_status, resp.status}}
            end

          resp.status == 202 and kind == :post ->
            if Map.has_key?(message, "id"), do: {:error, :unexpected_accepted}, else: :ok

          stream.sse and stream.complete ->
            :ok

          stream.sse and modern?(headers["mcp-protocol-version"]) ->
            {:error, :stream_closed}

          stream.sse ->
            {:resume, stream.id, stream.retry}

          kind == :get ->
            {:error, :expected_sse}

          true ->
            type = List.first(Map.get(resp.headers, "content-type", [])) || ""

            if String.starts_with?(type, "application/json") do
              case Jason.decode(stream.buffer) do
                {:ok, value} when is_map(value) ->
                  send(parent, {:message, self(), value})
                  :ok

                _ ->
                  {:error, :invalid_json}
              end
            else
              {:error, :unexpected_content_type}
            end
        end

      {:error, reason} ->
        stream = Process.get(:stream)

        if stream.sse and stream.id and not modern?(headers["mcp-protocol-version"]),
          do: {:resume, stream.id, stream.retry},
          else: {:error, reason}
    end
  rescue
    e -> {:error, {:http_exception, Exception.message(e)}}
  catch
    :response_too_large -> {:error, :response_too_large}
    :invalid_sse_json -> {:error, :invalid_sse_json}
  end

  # Incremental UTF-8-safe byte framing. CRLF, LF and bare CR are accepted;
  # a trailing CR is retained until the next chunk to avoid splitting CRLF.
  defp parse_lines(stream, parent, message) do
    case :binary.match(stream.buffer, ["\r", "\n"]) do
      :nomatch ->
        stream

      {pos, 1} ->
        <<line::binary-size(^pos), sep, rest::binary>> = stream.buffer

        if sep == 13 and rest == "" do
          stream
        else
          rest =
            if sep == 13 and String.starts_with?(rest, "\n"),
              do: binary_part(rest, 1, byte_size(rest) - 1),
              else: rest

          stream = line(%{stream | buffer: rest}, line, parent, message)
          parse_lines(stream, parent, message)
        end
    end
  end

  defp line(stream, "", parent, message) do
    data = stream.data |> Enum.reverse() |> Enum.join("\n")

    if data != "" do
      case Jason.decode(data) do
        {:ok, value} when is_map(value) ->
          send(parent, {:message, self(), value})

          complete =
            is_map(message) and Map.has_key?(message, "id") and value["id"] == message["id"] and
              (Map.has_key?(value, "result") or Map.has_key?(value, "error"))

          %{stream | data: [], complete: stream.complete or complete}

        _ ->
          throw(:invalid_sse_json)
      end
    else
      %{stream | data: []}
    end
  end

  defp line(stream, ":" <> _, _, _), do: stream

  defp line(stream, text, _, _) do
    [field | values] = String.split(text, ":", parts: 2)
    value = List.first(values) || ""

    value =
      if String.starts_with?(value, " "),
        do: binary_part(value, 1, byte_size(value) - 1),
        else: value

    case field do
      "data" ->
        %{stream | data: [value | stream.data]}

      "id" ->
        if String.contains?(value, <<0>>),
          do: stream,
          else: %{stream | id: if(value == "", do: nil, else: value)}

      "retry" ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> %{stream | retry: n}
          _ -> stream
        end

      _ ->
        stream
    end
  end

  defp cancel_timer(timer), do: Process.cancel_timer(timer)
  defp modern?(version), do: is_binary(version) and version >= "2026-07-28"

  defp metadata_headers(headers, message, tools) do
    headers = Map.put(headers, "mcp-method", message["method"])
    params = message["params"] || %{}
    name = params["name"] || params["uri"]

    headers =
      if message["method"] in ["tools/call", "resources/read", "prompts/get"] and is_binary(name),
        do: Map.put(headers, "mcp-name", encode_header(name)),
        else: headers

    if message["method"] == "tools/call" do
      Enum.reduce(Map.get(tools, name, []), headers, fn {path, annotation}, headers ->
        case get_in(params["arguments"] || %{}, path) do
          nil ->
            headers

          value
          when is_binary(value) or is_boolean(value) or
                 (is_integer(value) and value in -9_007_199_254_740_991..9_007_199_254_740_991) ->
            Map.put(
              headers,
              "mcp-param-" <> String.downcase(annotation),
              encode_header(to_string(value))
            )

          _ ->
            throw(:invalid_header_value)
        end
      end)
    else
      headers
    end
  end

  defp encode_header(value) do
    if Regex.match?(~r/^[\x09\x20-\x7e]*$/, value) and String.trim(value) == value and
         not (String.starts_with?(value, "=?base64?") and String.ends_with?(value, "?=")) do
      value
    else
      "=?base64?" <> Base.encode64(value) <> "?="
    end
  end

  defp learn_tools(message, state) do
    case get_in(message, ["result", "tools"]) do
      tools when is_list(tools) ->
        {valid, cache} =
          Enum.reduce(tools, {[], state.tools}, fn tool, {valid, cache} ->
            try do
              specs = annotations(tool["inputSchema"] || %{}, [], true)
              names = Enum.map(specs, fn {_, name} -> String.downcase(name) end)
              if length(names) != length(Enum.uniq(names)), do: throw(:invalid_annotation)
              {[tool | valid], Map.put(cache, tool["name"], specs)}
            catch
              :invalid_annotation -> {valid, Map.delete(cache, tool["name"])}
            end
          end)

        {put_in(message, ["result", "tools"], Enum.reverse(valid)), %{state | tools: cache}}

      _ ->
        {message, state}
    end
  end

  defp annotations(schema, path, reachable) when is_map(schema) do
    own =
      case schema["x-mcp-header"] do
        nil ->
          []

        name ->
          if not (reachable and path != [] and is_binary(name) and
                    Regex.match?(~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/, name) and
                    schema["type"] in ["string", "integer", "boolean"]),
             do: throw(:invalid_annotation)

          [{path, name}]
      end

    own ++
      Enum.flat_map(schema, fn
        {"properties", props} when is_map(props) ->
          Enum.flat_map(props, fn {name, child} ->
            annotations(child, path ++ [name], reachable)
          end)

        {"x-mcp-header", _} ->
          []

        {_, child} ->
          annotations(child, path, false)
      end)
  end

  defp annotations(children, path, reachable) when is_list(children),
    do: Enum.flat_map(children, &annotations(&1, path, reachable))

  defp annotations(_, _, _), do: []
end

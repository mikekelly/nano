defmodule MCP.HTTP do
  @moduledoc """
  Bounded Streamable HTTP transport independent of the MCP RPC client.

  `start(config, owner)` starts an **unlinked** process. `send_message/2` is
  asynchronous; decoded JSON objects arrive as
  `{:mcp_transport, transport, {:message, object}}`. Fatal errors arrive as
  `{:mcp_transport, transport, {:down, reason}}`, followed by termination.
  `close/1` is idempotent. The owner's death also closes all sockets.

      {:ok, transport} = MCP.HTTP.start(%{"url" => "https://example.org/mcp"}, self())
      MCP.HTTP.send_message(transport, %{"jsonrpc" => "2.0", "id" => 1,
        "method" => "initialize", "params" => %{"protocolVersion" => "2025-11-25"}})

  Config string keys: `url` (http/https), `headers` (string map), `timeout_ms`
  (default 30_000), `max_message_bytes` (default 8 MiB), `protocol_version`
  (default `2026-07-28`). Sending `initialize` selects legacy mode and the
  subsequent result supplies the negotiated version. HTTP redirects are
  deliberately not followed, so authorization cannot leak across origins.
  Each HTTP request owns a separate socket; there is no global client pool or
  application configuration. TLS uses Mint's certificate verification defaults.

  Implements the initialization/session/GET binding from **2025-11-25**, read
  alongside current **2026-07-28** on 2026-10-08. For modern requests containing
  `params._meta.io.modelcontextprotocol/protocolVersion`, it mirrors protocol,
  method and name headers and forwards JSON error bodies even on non-2xx status.
  No GET or session is created without a legacy initialize exchange. Modern
  schema-derived `Mcp-Param-*` headers and protocol negotiation belong to the
  caller through the optional `send_message/3` header hook; this transport does
  not discover or validate tool schemas. Legacy HTTP+SSE with
  a separate `endpoint` event is not supported.

  Modern `notifications/cancelled` messages are intercepted: the matching
  request socket is closed rather than POSTing a notification. For legacy
  sessions cancellation notifications are POSTed normally. At most 64 HTTP
  requests may be in flight; exceeding this bound terminates the transport.

  SSE comments, an initial UTF-8 BOM, LF/CR/CRLF, multiline data and split chunks are
  supported. JSON bodies and individual SSE frames are bounded. No automatic
  retry, replay, or Last-Event-ID resumption occurs: stream failure reports down
  so the RPC owner can reconnect, reinitialize and restore subscriptions. A
  successful request-scoped SSE response closes its socket immediately. Legacy
  GET and modern `subscriptions/listen` streams have no idle timeout; ordinary
  requests use `timeout_ms` as socket idle timeout, not a total RPC deadline.
  Session DELETE on explicit close is best-effort, bounded to one second.
  """
  use GenServer

  @default_limit 8 * 1024 * 1024
  @reserved ~w(accept content-type content-length host connection mcp-session-id mcp-protocol-version mcp-method mcp-name)

  @doc "Validate configuration and start unlinked (network errors arrive asynchronously)."
  def start(config, owner) when is_map(config) and is_pid(owner) do
    with {:ok, opts} <- validate(config), do: GenServer.start(__MODULE__, {opts, owner})
  end

  def start(_, _), do: {:error, :invalid_config}

  @doc "Enqueue one JSON object. Delivery errors are sent to the owner."
  def send_message(pid, message), do: send_message(pid, message, %{})

  @doc """
  Enqueue with additional per-message HTTP headers (string map).

  Use this hook for caller-validated schema-derived `Mcp-Param-*` headers.
  Values must already be safely encoded as ASCII HTTP field values (including
  the MCP base64 sentinel when necessary). Per-message headers override config
  headers case-insensitively, but may not override transport-owned headers
  such as Accept, Content-Type, session, protocol, method or name. Invalid
  headers terminate the transport with `:invalid_message_headers`.
  """
  def send_message(pid, message, headers), do: GenServer.cast(pid, {:send, message, headers})

  @doc "Close sockets and terminate the session, if any. Safe to call more than once."
  def close(pid) do
    try do
      GenServer.stop(pid, :normal, 2000)
    catch
      :exit, {:noproc, _} -> :ok
      :exit, {:normal, _} -> :ok
    end
  end

  @impl true
  def init({opts, owner}) do
    Process.flag(:trap_exit, true)

    {:ok,
     Map.merge(opts, %{
       owner: owner,
       owner_ref: Process.monitor(owner),
       workers: %{},
       session: nil,
       protocol: opts.protocol,
       era:
         if(opts.protocol in ["2025-03-26", "2025-06-18", "2025-11-25"],
           do: :legacy,
           else: :modern
         ),
       get_started: false,
       expired: false
     })}
  end

  @impl true
  def handle_cast(
        {:send, %{"method" => "notifications/cancelled", "params" => %{"requestId" => id}},
         _headers},
        %{era: :modern} = s
      ) do
    {cancelled, kept} = Enum.split_with(s.workers, fn {_pid, w} -> w.message["id"] == id end)

    Enum.each(cancelled, fn {pid, w} ->
      Process.demonitor(w.ref, [:flush])
      Process.exit(pid, :kill)
    end)

    {:noreply, %{s | workers: Map.new(kept)}}
  end

  def handle_cast({:send, message, extra_headers}, s) do
    with :ok <- validate_message_headers(extra_headers),
         true <- is_map(message),
         {:ok, body} <- Jason.encode(message),
         true <- byte_size(body) <= s.limit,
         true <- map_size(s.workers) < 64 do
      s = if message["method"] == "initialize", do: %{s | era: :legacy, protocol: nil}, else: s
      {:noreply, launch(s, "POST", message, body, extra_headers)}
    else
      {:error, :invalid_message_headers} -> fail(s, :invalid_message_headers)
      _ -> fail(s, :invalid_or_oversized_outbound_message)
    end
  end

  @impl true
  def handle_call({:http, pid, event}, _from, s) do
    case Map.fetch(s.workers, pid) do
      :error ->
        {:reply, :halt, s}

      {:ok, w} ->
        case http_event(event, w, s) do
          {:ok, w, s} ->
            {:reply, :ok, put_in(s.workers[pid], w)}

          {:done, s} ->
            Process.demonitor(w.ref, [:flush])
            s = %{s | workers: Map.delete(s.workers, pid)}

            s =
              if s.era == :legacy and w.message["method"] == "notifications/initialized" and
                   not s.get_started,
                 do: launch(%{s | get_started: true}, "GET", %{}, ""),
                 else: s

            {:reply, :halt, s}

          {:error, reason, s} ->
            notify(s, {:down, reason})
            {:stop, :normal, :halt, s}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = s),
    do: {:stop, :normal, s}

  def handle_info({:DOWN, _ref, :process, pid, reason}, s) do
    if Map.has_key?(s.workers, pid), do: fail(s, {:http_worker_exit, reason}), else: {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s) do
    Enum.each(s.workers, fn {pid, _} -> Process.exit(pid, :kill) end)

    if s.session && not s.expired do
      headers = headers(s, "DELETE", %{})
      uri = s.uri
      # This worker owns its socket and is bounded independently of the caller.
      spawn(fn ->
        {:ok, timer} = :timer.exit_after(1000, :kill)

        try do
          request(uri, "DELETE", headers, "", 1000, fn _ -> :halt end)
        after
          :timer.cancel(timer)
        end
      end)
    end

    :ok
  end

  defp fail(s, reason) do
    notify(s, {:down, reason})
    {:stop, :normal, s}
  end

  defp notify(s, event), do: send(s.owner, {:mcp_transport, self(), event})

  defp launch(s, method, message, body, extra_headers \\ %{}) do
    parent = self()

    hs =
      headers(s, method, message)
      |> Map.new()
      |> Map.merge(Map.new(extra_headers, fn {k, v} -> {String.downcase(k), v} end))
      |> Map.to_list()

    timeout = s.timeout
    stream = method == "GET" or message["method"] == "subscriptions/listen"

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          request(
            s.uri,
            method,
            hs,
            body,
            timeout,
            fn event ->
              GenServer.call(parent, {:http, self(), event}, :infinity)
            end,
            stream
          )
        end,
        [:link, :monitor]
      )

    w = %{
      ref: ref,
      method: method,
      message: message,
      status: nil,
      type: nil,
      buffer: "",
      frame: %{line: "", first_line: true, skip_lf: false, data: [], event: "", bytes: 0}
    }

    put_in(s.workers[pid], w)
  end

  defp headers(s, method, message) do
    meta_version = get_in(message, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"])
    version = meta_version || s.protocol

    base =
      s.headers ++
        [
          {"accept",
           if(method == "GET",
             do: "text/event-stream",
             else: "application/json, text/event-stream"
           )}
        ]

    base = if method == "POST", do: base ++ [{"content-type", "application/json"}], else: base
    base = if s.session, do: base ++ [{"mcp-session-id", s.session}], else: base
    base = if is_binary(version), do: base ++ [{"mcp-protocol-version", version}], else: base

    if s.era == :modern and is_binary(message["method"]) do
      base = base ++ [{"mcp-method", encode_header(message["method"])}]

      name =
        case message["method"] do
          "resources/read" -> get_in(message, ["params", "uri"])
          m when m in ["tools/call", "prompts/get"] -> get_in(message, ["params", "name"])
          _ -> nil
        end

      if is_binary(name), do: base ++ [{"mcp-name", encode_header(name)}], else: base
    else
      base
    end
  end

  defp encode_header(value) do
    if value == String.trim(value) and Regex.match?(~r/^[\x09\x20-\x7e]*$/, value) and
         not (String.starts_with?(value, "=?base64?") and String.ends_with?(value, "?=")),
       do: value,
       else: "=?base64?" <> Base.encode64(value) <> "?="
  end

  defp http_event({:status, status}, w, s), do: {:ok, %{w | status: status}, s}

  defp http_event({:headers, hs}, w, s) do
    hs = Map.new(hs, fn {k, v} -> {String.downcase(k), v} end)

    type =
      hs
      |> Map.get("content-type", "")
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()

    cond do
      w.status == 404 and s.session != nil ->
        {:error, :session_expired, %{s | expired: true}}

      w.method == "GET" and w.status == 405 ->
        {:done, s}

      w.status == 202 ->
        {:ok, %{w | type: :empty}, s}

      w.status in 200..299 and type == "text/event-stream" ->
        session_headers(hs, %{w | type: :sse}, s)

      type == "application/json" ->
        session_headers(hs, %{w | type: :json}, s)

      true ->
        {:error, {:http_status, w.status}, s}
    end
  end

  defp http_event({:data, data}, %{type: :json} = w, s) do
    if byte_size(w.buffer) + byte_size(data) <= s.limit,
      do: {:ok, %{w | buffer: w.buffer <> data}, s},
      else: {:error, :message_too_large, s}
  end

  defp http_event({:data, data}, %{type: :sse} = w, s) do
    case sse(data, w.frame, [], s.limit) do
      {:ok, frame, messages} ->
        Enum.reduce_while(messages, {:ok, %{w | frame: frame}, s}, fn data, {:ok, w, s} ->
          case deliver(data, w, s) do
            {:ok, s, final?} -> if final?, do: {:halt, {:done, s}}, else: {:cont, {:ok, w, s}}
            {:error, reason} -> {:halt, {:error, reason, s}}
          end
        end)

      {:error, reason} ->
        {:error, reason, s}
    end
  end

  defp http_event({:data, _}, _w, s), do: {:error, :unexpected_response_body, s}

  defp http_event(:done, %{type: :json} = w, s) do
    case deliver(w.buffer, w, s) do
      {:ok, s, _} -> {:done, s}
      {:error, reason} -> {:error, reason, s}
    end
  end

  defp http_event(:done, %{type: :empty}, s), do: {:done, s}
  defp http_event(:done, _w, s), do: {:error, :sse_closed, s}
  defp http_event({:error, reason}, _w, s), do: {:error, {:http_error, reason}, s}

  defp session_headers(hs, w, s) do
    session = hs["mcp-session-id"]

    if w.message["method"] == "initialize" and session != nil do
      if byte_size(session) <= 8192 and Regex.match?(~r/^[\x21-\x7e]+$/, session),
        do: {:ok, w, %{s | session: session}},
        else: {:error, :invalid_session_id, s}
    else
      {:ok, w, s}
    end
  end

  defp deliver(data, w, s) do
    case Jason.decode(data) do
      {:ok, message} when is_map(message) ->
        final? =
          Map.has_key?(w.message, "id") and message["id"] == w.message["id"] and
            (Map.has_key?(message, "result") or Map.has_key?(message, "error"))

        version =
          if final? and w.message["method"] == "initialize",
            do: get_in(message, ["result", "protocolVersion"]),
            else: nil

        s = if is_binary(version), do: %{s | protocol: version}, else: s
        notify(s, {:message, message})
        {:ok, s, final?}

      _ ->
        {:error, :invalid_json_message}
    end
  end

  # A line-oriented parser avoids rescanning entire incomplete events.
  defp sse(<<>>, frame, messages, _limit), do: {:ok, frame, Enum.reverse(messages)}

  defp sse(<<10, rest::binary>>, %{skip_lf: true} = frame, messages, limit),
    do: sse(rest, %{frame | skip_lf: false}, messages, limit)

  defp sse(data, frame, messages, limit) do
    case :binary.match(data, ["\r", "\n"]) do
      :nomatch ->
        if frame.bytes + byte_size(data) > limit,
          do: {:error, :message_too_large},
          else:
            {:ok,
             %{
               frame
               | line: frame.line <> data,
                 bytes: frame.bytes + byte_size(data),
                 skip_lf: false
             }, Enum.reverse(messages)}

      {pos, 1} ->
        <<part::binary-size(^pos), sep, rest::binary>> = data

        if frame.bytes + pos + 1 > limit do
          {:error, :message_too_large}
        else
          line = frame.line <> part
          frame = %{frame | line: "", bytes: frame.bytes + pos + 1, skip_lf: sep == 13}
          {frame, messages} = sse_line(line, frame, messages)
          sse(rest, frame, messages, limit)
        end
    end
  end

  defp sse_line(line, %{first_line: true} = frame, messages) do
    line =
      case line do
        <<239, 187, 191, rest::binary>> -> rest
        _ -> line
      end

    sse_line(line, %{frame | first_line: false}, messages)
  end

  defp sse_line("", frame, messages) do
    data = frame.data |> Enum.reverse() |> Enum.join("\n")

    messages =
      if data != "" and frame.event in ["", "message"], do: [data | messages], else: messages

    {%{frame | data: [], event: "", bytes: 0}, messages}
  end

  defp sse_line(":" <> _, frame, messages), do: {frame, messages}

  defp sse_line(line, frame, messages) do
    [field | values] = String.split(line, ":", parts: 2)

    value =
      case values do
        [" " <> value] -> value
        [value] -> value
        [] -> ""
      end

    frame =
      case field do
        "data" -> %{frame | data: [value | frame.data]}
        "event" -> %{frame | event: value}
        _ -> frame
      end

    {frame, messages}
  end

  defp request(uri, method, headers, body, timeout, callback, stream \\ false) do
    scheme = if uri.scheme == "https", do: :https, else: :http
    opts = [mode: :passive, protocols: [:http1], transport_opts: [timeout: timeout]]

    case Mint.HTTP.connect(scheme, uri.host, uri.port, opts) do
      {:ok, conn} ->
        try do
          target =
            if(uri.path in [nil, ""], do: "/", else: uri.path) <>
              if(uri.query, do: "?" <> uri.query, else: "")

          case Mint.HTTP.request(conn, method, target, headers, body) do
            {:ok, conn, _ref} -> receive_http(conn, timeout, callback, stream, false)
            {:error, _, reason} -> callback.({:error, reason})
          end
        after
          Mint.HTTP.close(conn)
        end

      {:error, reason} ->
        callback.({:error, reason})
    end
  end

  defp receive_http(conn, timeout, callback, stream, started) do
    case Mint.HTTP.recv(conn, 0, if(stream and started, do: :infinity, else: timeout)) do
      {:ok, conn, events} ->
        {action, started} =
          Enum.reduce_while(events, {:ok, started}, fn event, {_, started} ->
            mapped =
              case event do
                {:status, _, status} -> {:status, status}
                {:headers, _, headers} -> {:headers, headers}
                {:data, _, data} -> {:data, data}
                {:done, _} -> :done
                {:error, _, reason} -> {:error, reason}
              end

            if callback.(mapped) == :halt,
              do: {:halt, {:halt, started}},
              else: {:cont, {:ok, started or match?({:headers, _}, mapped)}}
          end)

        if action != :halt, do: receive_http(conn, timeout, callback, stream, started)

      {:error, _, reason, _events} ->
        callback.({:error, reason})
    end
  end

  defp validate(config) do
    url = config["url"]
    hs = Map.get(config, "headers", %{})
    timeout = Map.get(config, "timeout_ms", 30_000)
    limit = Map.get(config, "max_message_bytes", @default_limit)
    protocol = Map.get(config, "protocol_version") || "2026-07-28"

    with true <- is_binary(url),
         %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} = uri <- URI.parse(url),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "",
         true <- is_map(hs) and Enum.all?(hs, &valid_header?/1),
         true <- is_integer(timeout) and timeout > 0 and timeout <= 2_147_483_647,
         true <- is_integer(limit) and limit > 0,
         true <- is_binary(protocol) and Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, protocol),
         true <- uri.port in 1..65535 do
      hs = for {k, v} <- hs, String.downcase(k) not in @reserved, do: {String.downcase(k), v}
      {:ok, %{uri: uri, headers: hs, timeout: timeout, limit: limit, protocol: protocol}}
    else
      _ -> {:error, :invalid_config}
    end
  rescue
    _ -> {:error, :invalid_config}
  end

  defp validate_message_headers(headers) do
    if is_map(headers) and
         Enum.all?(headers, fn pair ->
           valid_header?(pair) and String.downcase(elem(pair, 0)) not in @reserved
         end), do: :ok, else: {:error, :invalid_message_headers}
  end

  defp valid_header?({k, v}) when is_binary(k) and is_binary(v),
    do:
      Regex.match?(~r/^[!#$%&'*+.^_`|~0-9a-zA-Z-]+$/, k) and
        Regex.match?(~r/^[\x09\x20-\x7e]*$/, v)

  defp valid_header?(_), do: false
end

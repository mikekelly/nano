defmodule Nano.MCP.HTTP do
  @moduledoc """
  Streamable HTTP MCP transport, researched against 2026-07-28 and 2025-11-25.
  Modern streams use POST subscriptions/listen and are not resumable. The client
  supplies per-request metadata; standard method/name headers are mirrored here.
  send_message/3 accepts extra prevalidated custom parameter headers.
  Modern cancellation notifications close the matching request stream locally.
  POST responses support JSON and SSE; after initialization GET listens for push.
  Each SSE stream resumes separately using Last-Event-ID and the server retry delay.
  Session expiration is reported so the owner can initialize a new transport.
  JSON bodies and SSE events are limited to 4 MiB; 64 requests may be in flight.
  Redirects and automatic POST retries are disabled. Legacy SSE is not supported.
  """
  use GenServer
  @limit 4 * 1024 * 1024
  def start_link(owner, config), do: GenServer.start_link(__MODULE__, {owner, config})
  def send_message(pid, message) when is_map(message), do: send_message(pid, message, %{})
  def send_message(pid, message, headers), do: GenServer.cast(pid, {:send, message, headers})
  def set_protocol(pid, version), do: GenServer.call(pid, {:set_protocol, version})
  defp modern?(version), do: version >= "2026-07-28"

  def encode_header(value) do
    value = to_string(value)

    if value =~ ~r/^[\x20-\x7e\x09]*$/ and String.trim(value) == value and
         not (String.starts_with?(value, "=?base64?") and String.ends_with?(value, "?=")),
       do: value,
       else: "=?base64?" <> Base.encode64(value) <> "?="
  end

  def stop(pid), do: GenServer.stop(pid, :normal)
  @impl true
  def init({owner, config}) do
    uri = URI.parse(config["url"] || "")

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      {:ok,
       %{
         owner: owner,
         owner_ref: Process.monitor(owner),
         config: config,
         session: nil,
         version: config["protocol_version"] || "2026-07-28",
         jobs: %{},
         listening: false
       }}
    else
      {:stop, :invalid_url}
    end
  end

  @impl true
  def handle_cast({:send, message, headers}, s) do
    if modern?(s.version) and message["method"] == "notifications/cancelled" do
      {:noreply, cancel(s, get_in(message, ["params", "requestId"]))}
    else
      if map_size(s.jobs) >= 64,
        do: down(s, :too_many_requests),
        else: {:noreply, launch(s, %{new_job(:post, message) | extra_headers: headers})}
    end
  end

  defp cancel(s, id) do
    {cancelled, retained} =
      Enum.split_with(s.jobs, fn {_, job} -> job.message && job.message["id"] == id end)

    for {_, job} <- cancelled do
      if job.ref, do: Process.demonitor(job.ref, [:flush])
      if job.pid, do: Process.exit(job.pid, :kill)
    end

    %{s | jobs: Map.new(retained)}
  end

  defp new_job(method, message) do
    %{
      key: make_ref(),
      extra_headers: %{},
      version: nil,
      status: nil,
      method: method,
      message: message,
      buffer: "",
      data: [],
      size: 0,
      event: "",
      first_line: true,
      cursor: nil,
      retry: 1000,
      complete: false,
      headers: false,
      type: nil,
      pid: nil,
      ref: nil
    }
  end

  defp launch(s, job) do
    parent = self()
    job = %{job | version: s.version}

    version =
      get_in(job.message || %{}, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"]) ||
        s.version

    headers =
      Map.new(s.config["headers"] || %{}, fn {k, v} -> {String.downcase(k), v} end)
      |> Map.merge(%{
        "accept" => "application/json, text/event-stream",
        "mcp-protocol-version" => version
      })

    headers =
      if s.session && not modern?(job.version),
        do: Map.put(headers, "mcp-session-id", s.session),
        else: Map.delete(headers, "mcp-session-id")

    headers =
      if job.cursor && job.cursor != "" && not modern?(job.version),
        do: Map.put(headers, "last-event-id", job.cursor),
        else: Map.delete(headers, "last-event-id")

    headers =
      Map.merge(
        headers,
        Map.new(job.extra_headers, fn {k, v} -> {String.downcase(k), encode_header(v)} end)
      )

    headers =
      if modern?(job.version) and job.message do
        headers = Map.put(headers, "mcp-method", job.message["method"] || "")

        name =
          case job.message["method"] do
            "resources/read" ->
              get_in(job.message, ["params", "uri"])

            method when method in ["tools/call", "prompts/get"] ->
              get_in(job.message, ["params", "name"])

            _ ->
              nil
          end

        if name,
          do: Map.put(headers, "mcp-name", encode_header(name)),
          else: Map.delete(headers, "mcp-name")
      else
        headers
      end

    {pid, ref} =
      spawn_monitor(fn ->
        opts = [
          method: job.method,
          url: s.config["url"],
          headers: headers,
          retry: false,
          redirect: false,
          decode_body: false,
          receive_timeout: 120_000,
          into: fn {:data, bytes}, {req, resp} ->
            case GenServer.call(parent, {:chunk, job.key, resp, bytes}, :infinity) do
              :ok -> {:cont, {req, resp}}
              :halt -> {:halt, {req, resp}}
            end
          end
        ]

        opts = if job.method == :post, do: Keyword.put(opts, :json, job.message), else: opts
        send(parent, {:finished, job.key, Req.request(opts)})
      end)

    put_in(s.jobs[job.key], %{job | pid: pid, ref: ref})
  end

  @impl true
  def handle_call({:set_protocol, version}, _, s),
    do: {:reply, :ok, %{s | version: version, session: nil}}

  def handle_call({:chunk, key, resp, bytes}, _from, s) do
    if not Map.has_key?(s.jobs, key) do
      {:reply, :halt, s}
    else
      try do
        {s, job} = headers(s, s.jobs[key], resp)
        {s, job} = consume(s, job, bytes)

        {:reply, if(job.complete and job.type == :sse, do: :halt, else: :ok),
         put_in(s.jobs[key], job)}
      catch
        {:transport_error, reason} ->
          notify(s, {:down, reason})
          {:stop, :normal, :halt, s}
      end
    end
  end

  defp headers(s, %{headers: true} = job, _), do: {s, job}

  defp headers(s, job, resp) do
    cond do
      resp.status == 405 and job.method == :get ->
        {s, %{job | headers: true, type: :unsupported, complete: true}}

      resp.status == 404 and s.session != nil ->
        throw({:transport_error, :session_expired})

      resp.status in [400, 404, 405] and modern?(job.version) ->
        {s, %{job | headers: true, type: :http_error, status: resp.status}}

      resp.status not in [200, 202, 204] ->
        throw({:transport_error, {:http_status, resp.status}})

      true ->
        type =
          case List.first(Req.Response.get_header(resp, "content-type")) do
            "text/event-stream" <> _ -> :sse
            "application/json" <> _ -> :json
            _ -> :empty
          end

        session = List.first(Req.Response.get_header(resp, "mcp-session-id"))
        initializing = job.message && job.message["method"] == "initialize"

        if session && initializing && not Regex.match?(~r/^[\x21-\x7e]+$/, session),
          do: throw({:transport_error, :invalid_session_id})

        s =
          if session && initializing && not modern?(job.version),
            do: %{s | session: session},
            else: s

        {s, %{job | headers: true, type: type}}
    end
  end

  defp consume(s, %{type: :unsupported} = job, _), do: {s, job}

  defp consume(s, %{type: :sse} = job, bytes),
    do: parse_lines(s, %{job | buffer: job.buffer <> bytes})

  defp consume(s, job, bytes) do
    buffer = job.buffer <> bytes
    if byte_size(buffer) > @limit, do: throw({:transport_error, :input_too_large})
    {s, %{job | buffer: buffer}}
  end

  defp parse_lines(s, job) do
    case :binary.match(job.buffer, ["\n", "\r"]) do
      :nomatch ->
        if byte_size(job.buffer) + job.size > @limit,
          do: throw({:transport_error, :input_too_large})

        {s, job}

      {n, 1} ->
        if job.size + n > @limit, do: throw({:transport_error, :input_too_large})

        if n == byte_size(job.buffer) - 1 and :binary.at(job.buffer, n) == 13 do
          {s, job}
        else
          line = binary_part(job.buffer, 0, n)

          line =
            if job.first_line, do: String.replace_prefix(line, <<239, 187, 191>>, ""), else: line

          skip =
            if binary_part(job.buffer, n, min(2, byte_size(job.buffer) - n)) == "\r\n",
              do: 2,
              else: 1

          rest = binary_part(job.buffer, n + skip, byte_size(job.buffer) - n - skip)

          {s, job} =
            line(s, %{job | buffer: rest, first_line: false, size: job.size + n + 1}, line)

          parse_lines(s, job)
        end
    end
  end

  defp line(s, job, "") do
    data = job.data |> Enum.reverse() |> Enum.join("\n")

    {s, job} =
      if data != "" and job.event in ["", "message"], do: deliver(s, job, data), else: {s, job}

    {s, %{job | data: [], event: "", size: 0}}
  end

  defp line(s, job, ":" <> _), do: {s, job}

  defp line(s, job, text) do
    [field | values] = String.split(text, ":", parts: 2)

    value =
      case values do
        [" " <> value] -> value
        [value] -> value
        [] -> ""
      end

    job =
      case field do
        "data" -> %{job | data: [value | job.data]}
        "event" -> %{job | event: value}
        "id" -> if String.contains?(value, <<0>>), do: job, else: %{job | cursor: value}
        "retry" -> if value =~ ~r/^\d+$/, do: %{job | retry: String.to_integer(value)}, else: job
        _ -> job
      end

    {s, job}
  end

  defp deliver(s, job, data) do
    case Jason.decode(data) do
      {:ok, %{} = message} ->
        notify(s, {:message, message})

        initialized =
          not modern?(job.version) && job.message && job.message["method"] == "initialize" &&
            Map.has_key?(message, "result")

        s =
          if initialized,
            do: %{s | version: get_in(message, ["result", "protocolVersion"]) || s.version},
            else: s

        s =
          if initialized && not s.listening,
            do: launch(%{s | listening: true}, new_job(:get, nil)),
            else: s

        complete =
          job.message && Map.has_key?(job.message, "id") && message["id"] == job.message["id"] &&
            (Map.has_key?(message, "result") or Map.has_key?(message, "error"))

        {s, %{job | complete: job.complete or !!complete}}

      _ ->
        throw({:transport_error, :invalid_json_message})
    end
  end

  @impl true
  def handle_info({:finished, key, result}, s) do
    job = s.jobs[key]
    if job, do: Process.demonitor(job.ref, [:flush])

    if is_nil(job) do
      {:noreply, s}
    else
      try do
        {s, job} =
          case result do
            {:ok, resp} ->
              headers(s, job, resp)

            {:error, reason} ->
              if job.type == :sse,
                do: {s, job},
                else: throw({:transport_error, {:http_error, reason}})
          end

        {s, job} =
          if job.type == :http_error do
            message =
              case Jason.decode(job.buffer) do
                {:ok, %{} = message} ->
                  message

                _ ->
                  %{
                    "jsonrpc" => "2.0",
                    "id" => job.message["id"],
                    "error" => %{
                      "code" => -32000,
                      "message" => "HTTP error",
                      "data" => %{"http_status" => job.status}
                    }
                  }
              end

            notify(s, {:message, message})
            {s, %{job | complete: true}}
          else
            {s, job}
          end

        {s, job} = if job.type == :json, do: deliver(s, job, job.buffer), else: {s, job}

        if job.type == :empty and job.buffer != "",
          do: throw({:transport_error, :unexpected_content_type})

        if modern?(job.version) and job.type == :sse and not job.complete,
          do: throw({:transport_error, :stream_closed})

        s = %{s | jobs: Map.delete(s.jobs, key)}

        if not modern?(job.version) and job.type == :sse and not job.complete and
             (job.method == :get or job.cursor not in [nil, ""]) do
          resumed = %{
            job
            | method: :get,
              buffer: "",
              data: [],
              size: 0,
              event: "",
              first_line: true,
              headers: false,
              pid: nil,
              ref: nil
          }

          Process.send_after(self(), {:resume, resumed}, min(job.retry, 4_294_967_295))
          {:noreply, put_in(s.jobs[key], resumed)}
        else
          {:noreply, s}
        end
      catch
        {:transport_error, reason} -> down(s, reason)
      end
    end
  end

  def handle_info({:resume, job}, s) do
    if Map.has_key?(s.jobs, job.key), do: {:noreply, launch(s, job)}, else: {:noreply, s}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, s) do
    if ref == s.owner_ref, do: {:stop, :normal, s}, else: down(s, {:worker_down, reason})
  end

  defp notify(s, event), do: send(s.owner, {:mcp_transport, self(), event})

  defp down(s, reason) do
    notify(s, {:down, reason})
    {:stop, :normal, s}
  end

  @impl true
  def terminate(_, s) do
    for {_, job} <- s.jobs, is_pid(job.pid), do: Process.exit(job.pid, :kill)
    :ok
  end
end

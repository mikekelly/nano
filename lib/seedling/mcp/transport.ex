defmodule Seedling.MCP.Transport do
  @moduledoc false
  alias Seedling.MCP.{Bounds, Headers}

  def open_stdio(config, dir, owner) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "stderr.log")
    group_path = Path.join(dir, "group-#{Base.encode16(:crypto.strong_rand_bytes(8))}.pid")

    cmd = Enum.map_join([config["command"] | config["args"] || []], " ", &quote_arg/1)
    setsid = System.find_executable("setsid") || raise "Install util-linux (setsid)."

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stream,
        {:args,
         [
           "-c",
           "exec #{quote_arg(setsid)} --wait /bin/sh -c #{quote_arg("printf %s \"$$\" > #{quote_arg(group_path)} && exec #{cmd}")} 2>>#{quote_arg(path)}"
         ]},
        {:cd, config["cwd"] || File.cwd!()},
        {:env,
         Enum.map(config["env"] || %{}, fn {k, v} ->
           {String.to_charlist(k), String.to_charlist(v)}
         end)}
      ])

    guardian =
      spawn(fn ->
        ref = Process.monitor(owner)

        receive do
          {:DOWN, ^ref, :process, ^owner, _} ->
            case group_pid(group_path, 500) do
              {:ok, pid} -> kill(pid)
              _ -> :ok
            end

          :stop ->
            Process.demonitor(ref, [:flush])
        end

        File.rm(group_path)
      end)

    # setsid may fork if the port child was a process-group leader. Its os_pid
    # then names the waiting wrapper, NOT the server/session leader. Use $$.
    case group_pid(group_path, 500) do
      {:ok, pid} ->
        {:ok, port, pid, path, guardian}

      _ ->
        Port.close(port)
        send(guardian, :stop)

        Seedling.MCP.error(
          :stdio_start,
          "Server did not record its process group; check command/cwd/permissions."
        )
    end
  rescue
    e -> Seedling.MCP.error(:stdio_start, Exception.message(e))
  end

  defp group_pid(_path, 0), do: {:error, :missing_group}

  defp group_pid(path, n) do
    case File.read(path) do
      {:ok, binary} ->
        case Integer.parse(binary) do
          {pid, ""} when pid > 0 ->
            {:ok, pid}

          _ ->
            Process.sleep(10)
            group_pid(path, n - 1)
        end

      _ ->
        Process.sleep(10)
        group_pid(path, n - 1)
    end
  end

  def close(port, pid, guardian) do
    if guardian, do: send(guardian, :stop)
    if is_port(port) and Port.info(port), do: Port.close(port)
    if pid, do: kill(pid)
    :ok
  end

  defp kill(pid) do
    Seedling.Shell.sh(
      "/bin/kill -TERM -- -#{pid} 2>/dev/null; sleep 0.05; /bin/kill -KILL -- -#{pid} 2>/dev/null",
      timeout: 3000,
      max_bytes: 100,
      max_lines: 2,
      spool_dir: "/tmp/seedling-mcp-cleanup"
    )
  end

  defp quote_arg(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  def http(
        owner,
        epoch,
        tag,
        config,
        message,
        version,
        session,
        extra \\ [],
        method \\ :post,
        last_id \\ nil
      ) do
    :erlang.spawn_opt(
      fn ->
        Process.put(:mcp_buffer, "")
        Process.put(:mcp_headers, false)
        Process.put(:mcp_last_id, last_id)

        headers =
          Map.to_list(config["headers"] || %{}) ++
            [
              {"accept", "application/json, text/event-stream"},
              {"content-type", "application/json"},
              {"mcp-protocol-version", version}
            ] ++
            if(session, do: [{"mcp-session-id", session}], else: [])

        headers = if last_id, do: headers ++ [{"last-event-id", last_id}], else: headers
        headers = headers ++ extra ++ standard_headers(message, version)

        opts = [
          url: config["url"],
          method: method,
          headers: headers,
          retry: false,
          redirect: false,
          receive_timeout: :infinity,
          connect_options: [timeout: 10_000],
          into: fn {:data, data}, {req, resp} ->
            if not Process.get(:mcp_headers) do
              send(owner, {:http_headers, epoch, tag, resp.status, resp.headers})
              Process.put(:mcp_headers, true)
            end

            cap = config["max_message_bytes"] || 8_000_000
            content = resp.headers |> Map.get("content-type", []) |> Enum.join(";")

            if String.contains?(content, "text/event-stream") do
              stream_sse(owner, epoch, tag, data, cap)
            else
              buffer = Process.get(:mcp_buffer) <> data

              if byte_size(buffer) > cap,
                do: raise("HTTP JSON response exceeds max_message_bytes")

              Process.put(:mcp_buffer, buffer)
            end

            {:cont, {req, resp}}
          end
        ]

        opts = if message, do: Keyword.put(opts, :body, Jason.encode!(message)), else: opts
        result = Req.request(opts)

        case result do
          {:ok, resp} ->
            if not Process.get(:mcp_headers),
              do: send(owner, {:http_headers, epoch, tag, resp.status, resp.headers})

            buffer = Process.get(:mcp_buffer)

            if buffer != "" and
                 not String.contains?(
                   Enum.join(Map.get(resp.headers, "content-type", [])),
                   "text/event-stream"
                 ),
               do: decode_send(owner, epoch, tag, buffer)

            send(owner, {:http_done, epoch, tag, resp.status, Process.get(:mcp_last_id)})

          {:error, e} ->
            send(owner, {:http_error, epoch, tag, inspect(e)})
        end
      end,
      [:link, :monitor]
    )
  end

  def delete_session(config, session, version) do
    headers =
      Map.to_list(config["headers"] || %{}) ++
        [{"mcp-session-id", session}, {"mcp-protocol-version", version}]

    Req.request(
      url: config["url"],
      method: :delete,
      headers: headers,
      retry: false,
      redirect: false,
      receive_timeout: 3000,
      connect_options: [timeout: 3000]
    )
  rescue
    _ -> :ok
  end

  defp standard_headers(%{"method" => method, "params" => params}, "2026-07-28") do
    name =
      if method in ["tools/call", "prompts/get"],
        do: params["name"],
        else: if(method == "resources/read", do: params["uri"])

    [{"mcp-method", method}] ++ if(name, do: [{"mcp-name", Headers.encode(name)}], else: [])
  end

  defp standard_headers(_, _), do: []

  defp stream_sse(owner, epoch, tag, data, cap) do
    buffer = Process.get(:mcp_buffer) <> data
    # Preserve a final CR until the next chunk so CRLF split across chunks is one newline.
    {body, ending} =
      if String.ends_with?(buffer, "\r"),
        do: {binary_part(buffer, 0, byte_size(buffer) - 1), "\r"},
        else: {buffer, ""}

    normalized = body |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
    parts = String.split(normalized <> ending, "\n\n")

    tail = List.last(parts)
    if byte_size(tail) > cap, do: raise("SSE event exceeds max_message_bytes")

    Enum.each(Enum.drop(parts, -1), fn event ->
      if byte_size(event) > cap, do: raise("SSE event exceeds max_message_bytes")
      lines = String.split(event, ~r/\r?\n/)

      id =
        Enum.find_value(lines, fn line ->
          if String.starts_with?(line, "id:"),
            do: String.trim_leading(binary_part(line, 3, byte_size(line) - 3), " ")
        end)

      if id do
        Process.put(:mcp_last_id, id)
        send(owner, {:sse_id, epoch, tag, id})
      end

      payload =
        lines
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map(fn line ->
          String.trim_leading(binary_part(line, 5, byte_size(line) - 5), " ")
        end)
        |> Enum.join("\n")

      if payload != "", do: decode_send(owner, epoch, tag, payload)
    end)

    Process.put(:mcp_buffer, tail)
  end

  defp decode_send(owner, epoch, tag, data) do
    case Jason.decode(data) do
      {:ok, msg} when is_map(msg) -> send(owner, {:wire, epoch, tag, msg})
      _ -> raise "Malformed MCP JSON frame: #{Bounds.prefix(data, 100)}"
    end
  end
end

defmodule Vega.MCP.HTTP do
  @moduledoc false
  @max_wire 8 * 1024 * 1024
  # One lightweight process per HTTP stream; incremental parsing bounds memory even
  # for an infinite notification stream. Req automatic retry is disabled: tools may
  # have side effects and must never be silently called twice.
  def run(owner, gen, config, session, version, kind, msg) do
    Process.put(:mcp_kind, kind)
    Process.put(:mcp_buffer, "")
    Process.put(:mcp_sse, false)
    Process.put(:mcp_headers, false)

    headers =
      Map.get(config, "headers", %{})
      |> Map.to_list()
      |> Enum.reject(fn {key, _} ->
        key = String.downcase(key)

        key in [
          "accept",
          "content-type",
          "mcp-method",
          "mcp-name",
          "mcp-protocol-version",
          "mcp-session-id",
          "last-event-id"
        ] or String.starts_with?(key, "mcp-param-")
      end)

    headers =
      headers ++
        [
          {"accept",
           if(kind == :get, do: "text/event-stream", else: "application/json, text/event-stream")},
          {"mcp-protocol-version", version}
        ]

    headers =
      if kind == :get and config["_last_event_id"],
        do: headers ++ [{"last-event-id", config["_last_event_id"]}],
        else: headers

    headers =
      if is_binary(session) and version != Vega.MCP.Protocol.modern(),
        do: headers ++ [{"mcp-session-id", session}],
        else: headers

    headers =
      if version == Vega.MCP.Protocol.modern() and msg,
        do: headers ++ Vega.MCP.Protocol.headers(msg, Map.get(config, "_schemas", %{})),
        else: headers

    opts = [
      url: config["url"],
      method: kind,
      headers: headers ++ [{"content-type", "application/json"}],
      retry: false,
      redirect: false,
      decode_body: false,
      # Connection timers own finite RPC deadlines; long-lived listen/GET streams
      # may legitimately be quiet indefinitely and must not impose a 2min cap.
      receive_timeout: :infinity,
      into: fn {:data, data}, {request, response} ->
        unless Process.get(:mcp_headers) do
          Process.put(:mcp_headers, true)
          sid = List.first(Req.Response.get_header(response, "mcp-session-id"))
          if sid, do: send(owner, {:http_headers, gen, sid})
          type = List.first(Req.Response.get_header(response, "content-type")) || ""
          Process.put(:mcp_sse, String.starts_with?(type, "text/event-stream"))
        end

        buffer = Process.get(:mcp_buffer) <> data
        if byte_size(buffer) > @max_wire, do: raise("MCP wire limit exceeded")
        buffer = if Process.get(:mcp_sse), do: consume(buffer, owner, gen), else: buffer
        Process.put(:mcp_buffer, buffer)
        {:cont, {request, response}}
      end
    ]

    opts =
      if msg, do: opts ++ [body: Jason.encode!(msg)], else: opts

    case Req.request(opts) do
      {:ok, %{status: 405}} when kind == :get ->
        :unsupported

      {:ok, %{status: status} = response} when status in 200..299 ->
        sid = List.first(Req.Response.get_header(response, "mcp-session-id"))
        if sid, do: send(owner, {:http_headers, gen, sid})
        buffer = Process.get(:mcp_buffer)

        if not Process.get(:mcp_sse) and buffer != "" do
          case Jason.decode(buffer) do
            {:ok, value} when is_map(value) -> send(owner, {:wire, gen, value})
            _ -> raise("Invalid MCP JSON response")
          end
        end

        :ok

      {:ok, %{status: status}} ->
        if version == Vega.MCP.Protocol.modern() do
          case Jason.decode(Process.get(:mcp_buffer)) do
            {:ok, %{"error" => _, "id" => _} = error} ->
              send(owner, {:wire, gen, error})
              :ok

            _ ->
              {:error, {:http_status, status}}
          end
        else
          {:error, {:http_status, status}}
        end

      {:error, error} ->
        {:error, {:http_transport, error.__struct__}}
    end
  rescue
    e -> {:error, {:http_transport, e.__struct__}}
  end

  @doc false
  def consume(buffer, owner, gen) do
    # Normalize CRLF only after complete line boundaries, retaining a trailing CR
    # until the next chunk. SSE accepts LF and CRLF line endings.
    case Regex.run(~r/\r?\n\r?\n/, buffer, return: :index) do
      [{index, length}] ->
        event = binary_part(buffer, 0, index)

        if Process.get(:mcp_kind) == :get do
          fields =
            event
            |> String.split(~r/\r?\n/)
            |> Enum.reduce(%{}, fn line, acc ->
              case String.split(line, ":", parts: 2) do
                [key, value] -> Map.put(acc, key, String.replace_prefix(value, " ", ""))
                _ -> acc
              end
            end)

          retry =
            case Integer.parse(fields["retry"] || "") do
              {n, ""} when n >= 0 -> n
              _ -> nil
            end

          send(owner, {:sse_state, gen, fields["id"], retry})
        end

        data =
          event
          |> String.split(~r/\r?\n/)
          |> Enum.filter(&String.starts_with?(&1, "data:"))
          |> Enum.map(fn line ->
            String.replace_prefix(line, "data:", "") |> String.replace_prefix(" ", "")
          end)
          |> Enum.join("\n")

        if data != "" do
          case Jason.decode(data) do
            {:ok, message} when is_map(message) -> send(owner, {:wire, gen, message})
            _ -> raise("Invalid MCP SSE data")
          end
        end

        consume(
          binary_part(buffer, index + length, byte_size(buffer) - index - length),
          owner,
          gen
        )

      nil ->
        buffer
    end
  end
end

defmodule SeedMCP.HTTP do
  @moduledoc false
  def run(server, method, message, session, cap, emit) do
    headers =
      Map.to_list(server["headers"] || %{}) ++
        [
          {"accept", "application/json, text/event-stream"},
          {"mcp-protocol-version",
           get_in(message, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"]) ||
             "2025-11-25"}
        ]

    headers = headers ++ metadata_headers(message, server)

    modern =
      get_in(message, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"]) ==
        "2026-07-28"

    session = if modern, do: nil, else: session
    headers = if session, do: [{"mcp-session-id", session} | headers], else: headers

    opts = [
      url: server["url"],
      method: method,
      headers: headers,
      retry: false,
      redirect: false,
      receive_timeout: 60_000,
      decode_body: false,
      into: fn {:data, chunk}, {req, resp} ->
        sid = header(resp, "mcp-session-id")
        if sid, do: emit.({:session, sid})
        buffer = Map.get(resp.private, :mcp_buffer, "") <> chunk
        sse = String.contains?(header(resp, "content-type") || "", "text/event-stream")
        buffer = if sse, do: parse_sse(buffer, cap, emit), else: buffer
        if byte_size(buffer) > cap, do: throw({:mcp_error, "HTTP frame exceeds frame_bytes"})
        {:cont, {req, %{resp | private: Map.put(resp.private, :mcp_buffer, buffer)}}}
      end
    ]

    opts = if message, do: Keyword.put(opts, :json, message), else: opts

    case Req.request(opts) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        buffer = Map.get(resp.private, :mcp_buffer, "")
        sse = String.contains?(header(resp, "content-type") || "", "text/event-stream")

        if buffer != "" and not sse do
          case Jason.decode(buffer) do
            {:ok, m} when is_map(m) -> emit.({:message, m})
            _ -> throw({:mcp_error, "Invalid HTTP JSON-RPC response"})
          end
        end

        {:ok, header(resp, "mcp-session-id")}

      {:ok, %{status: 405}} when method == :get ->
        {:ok, :get_disabled}

      {:ok, %{status: status} = resp} ->
        case Jason.decode(Map.get(resp.private, :mcp_buffer, "")) do
          {:ok, %{"id" => _, "error" => _} = error} ->
            emit.({:message, error})
            {:ok, session}

          _ ->
            {:error, "HTTP status #{status}"}
        end

      {:error, error} ->
        {:error, String.slice(Exception.message(error), 0, 500)}
    end
  rescue
    e -> {:error, String.slice(Exception.message(e), 0, 500)}
  catch
    {:mcp_error, error} -> {:error, error}
  end

  @doc false
  def encode_header(value) do
    value = to_string(value)
    safe = Enum.all?(:binary.bin_to_list(value), &(&1 in 32..126 or &1 == 9))
    sentinel = String.starts_with?(value, "=?base64?") and String.ends_with?(value, "?=")

    if safe and String.trim(value) == value and not sentinel,
      do: value,
      else: "=?base64?" <> Base.encode64(value) <> "?="
  end

  defp metadata_headers(nil, _), do: []

  defp metadata_headers(message, server) do
    method = message["method"]
    params = message["params"] || %{}
    headers = if method, do: [{"mcp-method", encode_header(method)}], else: []

    headers =
      if method in ["tools/call", "resources/read", "prompts/get"] do
        name = params["name"] || params["uri"]
        if name, do: [{"mcp-name", encode_header(name)} | headers], else: headers
      else
        headers
      end

    if method == "tools/call" do
      schema = get_in(server, ["_toolSchemas", params["name"]]) || %{}
      headers ++ parameter_headers(schema, params["arguments"] || %{})
    else
      headers
    end
  end

  defp parameter_headers(schema, arguments) when is_map(schema) and is_map(arguments) do
    Enum.flat_map(schema["properties"] || %{}, fn {key, property} ->
      value = arguments[key]
      name = property["x-mcp-header"]

      direct =
        if is_binary(name) and name =~ ~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/ and
             (is_binary(value) or is_boolean(value) or
                (is_integer(value) and abs(value) <= 9_007_199_254_740_991)) do
          [{"mcp-param-" <> String.downcase(name), encode_header(value)}]
        else
          []
        end

      direct ++ parameter_headers(property, value)
    end)
  end

  defp parameter_headers(_, _), do: []

  defp header(resp, key), do: List.first(Req.Response.get_header(resp, key))

  defp parse_sse(buffer, cap, emit) do
    # Normalize CRLF even when the CR and LF arrive in separate network chunks.
    buffer = String.replace(buffer, "\r\n", "\n")

    case :binary.match(buffer, "\n\n") do
      :nomatch ->
        buffer

      {offset, 2} ->
        frame = binary_part(buffer, 0, offset)
        if byte_size(frame) > cap, do: throw({:mcp_error, "SSE frame exceeds frame_bytes"})

        data =
          frame
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "data:"))
          |> Enum.map(&(String.replace_prefix(&1, "data:", "") |> String.replace_prefix(" ", "")))
          |> Enum.join("\n")

        if data != "" do
          case Jason.decode(data) do
            {:ok, m} when is_map(m) -> emit.({:message, m})
            _ -> throw({:mcp_error, "Invalid SSE JSON-RPC response"})
          end
        end

        parse_sse(binary_part(buffer, offset + 2, byte_size(buffer) - offset - 2), cap, emit)
    end
  end
end

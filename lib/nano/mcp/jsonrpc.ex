defmodule Nano.MCP.JSONRPC do
  @moduledoc """
  JSON-RPC 2.0 framing for MCP: encoding, pulling whole newline-delimited messages out of a
  byte buffer, decoding SSE `data:` events, and shaping results into plain Elixir terms.

  Pure functions; the transports in `Nano.MCP.Server` own the state.
  """

  @doc "One JSON line carrying `message` (no embedded newlines, so it frames itself)."
  def encode(message), do: Jason.encode!(message)

  @doc """
  Takes one newline-delimited message from `buffer`:

    * `{:ok, message, rest}`
    * `:more` — an incomplete message; read more bytes
    * `{:invalid, reason, rest}` — a line that is not JSON; the line is dropped, the stream goes on
  """
  def take_message(buffer) do
    case :binary.match(buffer, "\n") do
      {pos, 1} ->
        line = binary_part(buffer, 0, pos)
        rest = binary_part(buffer, pos + 1, byte_size(buffer) - pos - 1)

        case Jason.decode(line) do
          {:ok, message} -> {:ok, message, rest}
          {:error, reason} -> {:invalid, reason, rest}
        end

      :nomatch ->
        :more
    end
  end

  @doc "A JSON body that may hold one message or an array of them."
  def decode_body(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) -> list
      {:ok, map} -> [map]
      _ -> []
    end
  end

  @doc """
  The JSON-RPC messages carried by an SSE body's `data:` events (multi-line fields joined,
  comments ignored), for the streamable-HTTP transport.
  """
  def decode_sse(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.reduce([], fn
      "data:" <> rest, acc -> [String.trim_leading(rest, " ") | acc]
      _, acc -> acc
    end)
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn data ->
      case Jason.decode(data) do
        {:ok, map} -> [map]
        _ -> []
      end
    end)
  end

  @doc """
  A result as a plain Elixir term: text stays text, binary payloads become short references,
  everything is capped. Adds `"text"` joining the text parts, for the common case.
  """
  def normalize_result(%{"content" => content} = result) when is_list(content) do
    parts = Enum.map(content, &normalize_part/1)

    text =
      parts
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => t} when is_binary(t) -> [t]
        _ -> []
      end)
      |> Enum.join("\n")

    result |> Map.put("content", parts) |> Map.put("text", clip(text))
  end

  def normalize_result(%{"contents" => contents} = result) when is_list(contents) do
    parts = Enum.map(contents, &normalize_resource/1)
    text = parts |> Enum.map(& &1["text"]) |> Enum.reject(&is_nil/1) |> Enum.join("\n")
    result |> Map.put("contents", parts) |> Map.put("text", clip(text))
  end

  def normalize_result(result), do: result

  defp normalize_part(%{"type" => "text", "text" => text} = part) when is_binary(text),
    do: %{part | "text" => clip(text)}

  defp normalize_part(%{"type" => type} = part) when type in ["image", "audio"] do
    data = part["data"] || ""
    part |> Map.put("data", "<" <> type <> ": " <> Integer.to_string(byte_size(data)) <> " base64 bytes>") |> Map.put("bytes", byte_size(data))
  end

  defp normalize_part(%{"type" => "resource", "resource" => r} = part),
    do: %{part | "resource" => normalize_resource(r)}

  defp normalize_part(other), do: other

  defp normalize_resource(%{"blob" => blob} = r) when is_binary(blob),
    do: %{r | "blob" => "<blob: #{byte_size(blob)} base64 bytes>", "bytes" => byte_size(blob)}

  defp normalize_resource(%{"text" => text} = r) when is_binary(text),
    do: %{r | "text" => clip(text)}

  defp normalize_resource(other), do: other

  defp clip(text) do
    max = Application.get_env(:nano, :mcp_result_bytes, 16_000)
    if byte_size(text) <= max, do: text, else: binary_part(text, 0, max) <> "\n[cut at #{max} bytes]"
  end
end

defmodule Nano.MCP.Protocol do
  @moduledoc """
  JSON-RPC 2.0 framing for MCP: newline-delimited messages (stdio), SSE `data:` events
  (streamable HTTP), and the small result-shaping rules (text stays text; binary payloads
  become references; everything is capped).

  Deliberately small: it encodes a message, pulls whole messages out of a byte buffer,
  decodes an SSE body, and normalises results. The transports (`Nano.MCP.Server`) own the
  state; this module is pure functions.
  """

  alias Nano.MCP

  @doc "Encodes a message as one JSON line (no embedded newlines)."
  def encode(message), do: Jason.encode!(message)

  @doc """
  Pulls one newline-delimited message out of `buffer`.
  `{:ok, message, rest}` | `:more` | `{:invalid, reason, rest}` (bad JSON: the line is
  dropped so the stream keeps going).
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

  @doc """
  Decodes a JSON body that may hold one message or an array of them.
  """
  def decode_body(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) -> list
      {:ok, map} -> [map]
      _ -> []
    end
  end

  @doc """
  Decodes an SSE body into the JSON-RPC messages its `data:` events carry. Handles
  multi-line `data:` fields and ignores comments (`:`) and other fields, per the SSE spec.
  """
  def decode_sse(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.reduce([], fn line, acc ->
      cond do
        String.starts_with?(line, "data:") ->
          [String.trim_leading(String.replace_prefix(line, "data:", ""), " ") | acc]

        true ->
          acc
      end
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
  Normalises an MCP result so it is a plain Elixir term: text parts stay strings, images and
  other binary payloads become `%{type: "image" | "audio" | "blob", mimeType:, data: <base64
  reference>}`, and long text is capped at `Nano.MCP.limits().result_bytes`. Also adds a
  `"text"` key joining the text parts, for the common case.
  """
  def normalize_result(%{"content" => content} = result) when is_list(content) do
    parts = Enum.map(content, &normalize_part/1)
    # The text parts, joined, as the convenience field; binary parts stay as references.
    text =
      parts
      |> Enum.map(fn
        %{"type" => "text", "text" => t} when is_binary(t) -> t
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    result |> Map.put("content", parts) |> Map.put("text", clip(text))
  end

  def normalize_result(%{"contents" => contents} = result) when is_list(contents) do
    parts = Enum.map(contents, &normalize_resource/1)
    text = parts |> Enum.map(&Map.get(&1, "text")) |> Enum.reject(&is_nil/1) |> Enum.join("\n")
    result |> Map.put("contents", parts) |> Map.put("text", clip(text))
  end

  def normalize_result(result) when is_map(result), do: result

  defp normalize_part(%{"type" => "text", "text" => text} = part) when is_binary(text),
    do: Map.put(part, "text", clip(text))

  defp normalize_part(%{"type" => type} = part) when type in ["image", "audio"] do
    part
    |> Map.put("bytes", byte_size(part["data"] || ""))
    |> Map.put("data", "<#{type} reference: #{byte_size(part["data"] || "")} base64 bytes>")
  end

  defp normalize_part(%{"type" => "resource", "resource" => resource} = part),
    do: Map.put(part, "resource", normalize_resource(resource))

  defp normalize_part(other), do: other

  defp normalize_resource(%{"blob" => blob} = resource) when is_binary(blob) do
    resource
    |> Map.put("bytes", byte_size(blob))
    |> Map.put("blob", "<blob reference: #{byte_size(blob)} base64 bytes>")
  end

  defp normalize_resource(%{"text" => text} = resource) when is_binary(text),
    do: Map.put(resource, "text", clip(text))

  defp normalize_resource(other), do: other

  defp clip(text), do: Nano.Util.clip(text, max: MCP.limits().result_bytes)
end

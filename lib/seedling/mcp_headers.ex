defmodule Seedling.MCP.Headers do
  @moduledoc "2026-07-28 MCP HTTP tool header schema validation and encoding."
  def bindings(tool) do
    schema = tool["inputSchema"] || %{}
    entries = walk(schema, [])

    names =
      Enum.map(entries, fn {_, name, _} ->
        if is_binary(name), do: String.downcase(name), else: name
      end)

    valid =
      Enum.all?(entries, fn {path, name, type} ->
        path != [] and is_binary(name) and Regex.match?(~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/, name) and
          type in ["string", "integer", "boolean"]
      end)

    if valid and count(schema) == length(entries) and Enum.uniq(names) == names,
      do: {:ok, entries},
      else: {:error, :invalid_x_mcp_header}
  end

  def headers(entries, args) do
    Enum.reduce(entries, %{}, fn {path, name, type}, acc ->
      value = fetch(args, path)

      if is_nil(value) do
        acc
      else
        unless (type == "string" and is_binary(value)) or
                 (type == "boolean" and is_boolean(value)) or
                 (type == "integer" and is_integer(value) and abs(value) <= 9_007_199_254_740_991),
               do: raise(ArgumentError, "invalid MCP header parameter #{inspect(path)}")

        Map.put(acc, "mcp-param-" <> String.downcase(name), encode(to_string(value)))
      end
    end)
  end

  def encode(value) do
    if String.trim(value) != value or
         (String.starts_with?(value, "=?base64?") and String.ends_with?(value, "?=")) or
         not Enum.all?(:binary.bin_to_list(value), &(&1 == 9 or &1 in 32..126)) do
      "=?base64?" <> Base.encode64(value) <> "?="
    else
      value
    end
  end

  defp fetch(value, []), do: value
  defp fetch(value, [key | rest]) when is_map(value), do: fetch(value[key], rest)
  defp fetch(_, _), do: nil

  defp walk(schema, path) when is_map(schema) do
    own =
      if Map.has_key?(schema, "x-mcp-header"),
        do: [{path, schema["x-mcp-header"], schema["type"]}],
        else: []

    own ++
      Enum.flat_map(schema["properties"] || %{}, fn {key, child} -> walk(child, path ++ [key]) end)
  end

  defp walk(_, _), do: []

  defp count(map) when is_map(map),
    do:
      if(Map.has_key?(map, "x-mcp-header"), do: 1, else: 0) +
        Enum.reduce(map, 0, fn {_, v}, n -> n + count(v) end)

  defp count(list) when is_list(list), do: Enum.reduce(list, 0, fn v, n -> n + count(v) end)
  defp count(_), do: 0
end

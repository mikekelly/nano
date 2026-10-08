defmodule Seedling.MCP.Headers do
  @moduledoc false
  def encode(value) do
    v = to_string(value)

    safe =
      v == String.trim(v) and Enum.all?(:binary.bin_to_list(v), &(&1 in 32..126 or &1 == 9)) and
        not (String.starts_with?(v, "=?base64?") and String.ends_with?(v, "?="))

    if safe, do: v, else: "=?base64?#{Base.encode64(v)}?="
  end

  def tool(tool) do
    {annotations, invalid} = walk(tool["inputSchema"] || %{}, [], true, [], false)
    names = Enum.map(annotations, fn {_, name, _} -> String.downcase(name) end)

    if invalid or length(Enum.uniq(names)) != length(names),
      do: {:error, :invalid_header_schema},
      else: {:ok, annotations}
  end

  defp walk(schema, path, reachable, acc, bad) when is_map(schema) do
    {acc, bad} =
      if Map.has_key?(schema, "x-mcp-header") do
        name = schema["x-mcp-header"]

        valid =
          reachable and path != [] and is_binary(name) and
            Regex.match?(~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/, name) and
            schema["type"] in ["string", "integer", "boolean"]

        if valid, do: {[{path, name, schema["type"]} | acc], bad}, else: {acc, true}
      else
        {acc, bad}
      end

    Enum.reduce(schema, {acc, bad}, fn
      {"properties", properties}, {a, b} when is_map(properties) ->
        Enum.reduce(properties, {a, b}, fn {key, value}, {a2, b2} ->
          walk(value, path ++ [key], reachable, a2, b2)
        end)

      {"x-mcp-header", _}, state ->
        state

      {_key, value}, {a, b} ->
        walk(value, path, false, a, b)
    end)
  end

  defp walk(list, path, reachable, acc, bad) when is_list(list),
    do: Enum.reduce(list, {acc, bad}, fn v, {a, b} -> walk(v, path, reachable, a, b) end)

  defp walk(_, _, _, acc, bad), do: {acc, bad}

  def values(annotations, args) do
    Enum.reduce_while(annotations, {:ok, []}, fn {path, name, type}, {:ok, acc} ->
      value = fetch(args, path)

      valid =
        case type do
          "string" -> is_binary(value)
          "integer" -> is_integer(value) and abs(value) <= 9_007_199_254_740_991
          "boolean" -> is_boolean(value)
        end

      cond do
        is_nil(value) ->
          {:cont, {:ok, acc}}

        valid ->
          {:cont, {:ok, [{"mcp-param-" <> name, encode(value)} | acc]}}

        true ->
          {:halt,
           Seedling.MCP.error(
             :invalid_header_argument,
             "Invalid primitive/safe integer at #{Enum.join(path, ".")}."
           )}
      end
    end)
  end

  defp fetch(value, []), do: value
  defp fetch(value, [key | rest]) when is_map(value), do: fetch(value[key], rest)
  defp fetch(_, _), do: nil
end

defmodule Nano.MCP.ToolHeaders do
  @moduledoc """
  Validates and extracts 2026-07-28 Streamable HTTP `x-mcp-header` annotations.
  Only primitive properties reached exclusively through `properties` are eligible.
  Invalid annotations reject the tool even when its arguments omit that property.
  Call `extract(schema, %{})` to validate a tool before publishing its catalog entry.
  Returned values are encoded once using the transport's Base64 sentinel rules.
  This validates header annotations, not the whole JSON Schema or tool arguments.
  """
  @token ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/
  @safe_integer 9_007_199_254_740_991

  def extract(schema, arguments) when is_map(schema) and is_map(arguments) do
    try do
      {annotations, _, _} = walk(schema, [], true, [], MapSet.new(), 0, 0)

      headers =
        Enum.reduce(annotations, %{}, fn {name, path, type}, headers ->
          case fetch(arguments, path) do
            :missing ->
              headers

            {:ok, nil} ->
              headers

            {:ok, value} ->
              if valid_value?(type, value) do
                Map.put(headers, "mcp-param-" <> name, Nano.MCP.HTTP.encode_header(value))
              else
                throw({:invalid_header_argument, path})
              end
          end
        end)

      {:ok, headers}
    catch
      reason -> {:error, reason}
    end
  end

  def extract(_, _), do: {:error, :invalid_schema_or_arguments}

  defp walk(node, path, reachable, annotations, names, count, depth) when is_map(node) do
    if depth > 64 or count >= 10_000, do: throw(:schema_too_large)

    {annotations, names} =
      if Map.has_key?(node, "x-mcp-header") do
        name = node["x-mcp-header"]
        type = node["type"]

        if not reachable or path == [] or Map.has_key?(node, "$ref"),
          do: throw({:unreachable_header_annotation, path})

        if not is_binary(name) or not Regex.match?(@token, name),
          do: throw({:invalid_header_name, path})

        if type not in ["string", "integer", "boolean"], do: throw({:invalid_header_type, path})
        name = String.downcase(name)
        if MapSet.member?(names, name), do: throw({:duplicate_header_name, name})
        {[{name, path, type} | annotations], MapSet.put(names, name)}
      else
        {annotations, names}
      end

    Enum.reduce(node, {annotations, names, count + 1}, fn {key, value},
                                                          {annotations, names, count} ->
      if key == "properties" and is_map(value) do
        Enum.reduce(value, {annotations, names, count}, fn {property, child}, {a, n, c} ->
          walk(
            child,
            path ++ [property],
            reachable and not Map.has_key?(node, "$ref"),
            a,
            n,
            c,
            depth + 1
          )
        end)
      else
        walk(value, path, false, annotations, names, count, depth + 1)
      end
    end)
  end

  defp walk(nodes, path, _, a, n, c, depth) when is_list(nodes) do
    if depth > 64 or c >= 10_000, do: throw(:schema_too_large)

    Enum.reduce(nodes, {a, n, c + 1}, fn node, {a, n, c} ->
      walk(node, path, false, a, n, c, depth + 1)
    end)
  end

  defp walk(_, _, _, a, n, c, _), do: {a, n, c}
  defp fetch(value, []), do: {:ok, value}

  defp fetch(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, value} -> fetch(value, rest)
      :error -> :missing
    end
  end

  defp fetch(_, _), do: :missing
  defp valid_value?("string", value), do: is_binary(value) and String.valid?(value)
  defp valid_value?("boolean", value), do: is_boolean(value)
  defp valid_value?("integer", value), do: is_integer(value) and abs(value) <= @safe_integer
end

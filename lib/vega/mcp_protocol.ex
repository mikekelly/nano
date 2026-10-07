defmodule Vega.MCP.Protocol do
  @moduledoc false
  @modern "2026-07-28"
  def modern, do: @modern

  def metadata(params) do
    meta =
      Map.get(params, "_meta", %{})
      |> Map.merge(%{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientInfo" => %{"name" => "vega", "version" => "1.1"},
        "io.modelcontextprotocol/clientCapabilities" => %{}
      })

    Map.put(params, "_meta", meta)
  end

  def headers(%{"method" => method, "params" => params}, schemas) do
    name =
      case method do
        "resources/read" -> params["uri"]
        m when m in ["tools/call", "prompts/get"] -> params["name"]
        _ -> nil
      end

    headers = [{"mcp-method", method}]
    headers = if name, do: headers ++ [{"mcp-name", encode_header(name)}], else: headers

    case {method, Map.get(schemas, params["name"])} do
      {"tools/call", annotations} when is_list(annotations) ->
        Enum.reduce(annotations, headers, fn {path, header, type}, acc ->
          value = get_in(Map.get(params, "arguments", %{}), Enum.map(path, &Access.key(&1)))

          if is_nil(value) do
            acc
          else
            unless valid_value?(type, value),
              do: raise(ArgumentError, "Invalid x-mcp-header argument")

            text = if is_binary(value), do: value, else: to_string(value)
            acc ++ [{"mcp-param-" <> String.downcase(header), encode_header(text)}]
          end
        end)

      _ ->
        headers
    end
  end

  def encode_header(value) do
    safe =
      value != "" and String.trim(value) == value and
        Enum.all?(:binary.bin_to_list(value), &(&1 in 32..126)) and
        not (String.starts_with?(value, "=?base64?") and String.ends_with?(value, "?="))

    if safe, do: value, else: "=?base64?" <> Base.encode64(value) <> "?="
  end

  defp valid_value?("string", v), do: is_binary(v)
  defp valid_value?("boolean", v), do: is_boolean(v)
  defp valid_value?("integer", v), do: is_integer(v) and abs(v) <= 9_007_199_254_740_991
  defp valid_value?(_, _), do: false

  # Traverse the complete schema, marking only properties-chain descendants as
  # statically reachable. Reject misplaced annotations, not just malformed names.
  def annotations(schema) do
    try do
      entries = walk(schema, [], true)
      names = Enum.map(entries, fn {_, name, _} -> String.downcase(name) end)
      if Enum.uniq(names) != names, do: throw(:duplicate_header)
      {:ok, entries}
    catch
      reason -> {:error, reason}
    end
  end

  defp walk(map, path, reachable) when is_map(map) do
    own =
      if Map.has_key?(map, "x-mcp-header") do
        header = map["x-mcp-header"]
        type = map["type"]

        unless reachable and path != [] and is_binary(header) and
                 Regex.match?(~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/, header) and
                 type in ["integer", "string", "boolean"],
               do: throw(:invalid_header_annotation)

        [{path, header, type}]
      else
        []
      end

    children =
      Enum.flat_map(map, fn
        {"properties", properties} when is_map(properties) ->
          Enum.flat_map(properties, fn {name, child} -> walk(child, path ++ [name], reachable) end)

        {_, child} when is_map(child) or is_list(child) ->
          walk(child, path, false)

        _ ->
          []
      end)

    own ++ children
  end

  defp walk(list, path, _) when is_list(list), do: Enum.flat_map(list, &walk(&1, path, false))
  defp walk(_, _, _), do: []
end

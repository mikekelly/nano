defmodule Seedling.MCP.Schema do
  @moduledoc false
  @token ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/
  def annotations(schema) do
    with {:ok, fields} <- walk(schema, [], true),
         names = Enum.map(fields, fn {name, _, _} -> String.downcase(name) end),
         true <- length(names) == length(Enum.uniq(names)) do
      {:ok, fields}
    else
      false -> {:error, :duplicate_header_annotation}
      error -> error
    end
  end

  def headers(schema, arguments) do
    with {:ok, fields} <- annotations(schema) do
      Enum.reduce_while(fields, {:ok, %{}}, fn {name, path, type}, {:ok, headers} ->
        value = get_in(arguments, path)

        cond do
          value == nil ->
            {:cont, {:ok, headers}}

          type == "integer" and (not is_integer(value) or abs(value) > 9_007_199_254_740_991) ->
            {:halt, {:error, :invalid_header_integer}}

          type == "boolean" and not is_boolean(value) ->
            {:halt, {:error, :invalid_header_boolean}}

          type == "string" and not is_binary(value) ->
            {:halt, {:error, :invalid_header_string}}

          true ->
            {:cont,
             {:ok,
              Map.put(
                headers,
                "mcp-param-" <> String.downcase(name),
                Seedling.MCP.HTTP.header_value(to_string(value))
              )}}
        end
      end)
    end
  end

  defp walk(map, path, allowed) when is_map(map) do
    annotation = map["x-mcp-header"]

    cond do
      annotation != nil and
          (not allowed or path == [] or not is_binary(annotation) or
             not Regex.match?(@token, annotation) or
             map["type"] not in ["string", "integer", "boolean"]) ->
        {:error, :invalid_header_annotation}

      true ->
        initial = if annotation, do: [{annotation, path, map["type"]}], else: []

        Enum.reduce_while(map, {:ok, initial}, fn {key, value}, {:ok, fields} ->
          result =
            if key == "properties" and is_map(value) do
              Enum.reduce_while(value, {:ok, []}, fn {name, child}, {:ok, acc} ->
                case walk(child, path ++ [name], allowed) do
                  {:ok, more} -> {:cont, {:ok, acc ++ more}}
                  error -> {:halt, error}
                end
              end)
            else
              walk(value, path, false)
            end

          case result do
            {:ok, more} -> {:cont, {:ok, fields ++ more}}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp walk(list, path, allowed) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn child, {:ok, fields} ->
      case walk(child, path, allowed) do
        {:ok, more} -> {:cont, {:ok, fields ++ more}}
        error -> {:halt, error}
      end
    end)
  end

  defp walk(_, _, _), do: {:ok, []}
end

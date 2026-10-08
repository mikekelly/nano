defmodule Seedling.MCP.Config do
  @moduledoc false
  def path, do: Path.join([File.cwd!(), "priv", "seedling", "mcp.json"])

  def load(path) do
    with {:ok, json} <- File.read(path),
         {:ok, %{"servers" => servers}} when is_map(servers) <- Jason.decode(json) do
      {:ok, servers}
    else
      error -> {:error, {:config, path, error}}
    end
  end

  def resolve(config) do
    case config["transport"] do
      "stdio" ->
        command = config["command"]
        executable = if is_binary(command), do: System.find_executable(command)

        cond do
          executable == nil -> {:error, {:executable_not_found, command}}
          not is_list(config["args"] || []) -> {:error, :invalid_args}
          true -> {:ok, Map.put(config, "command", executable)}
        end

      transport when transport in ["http", "streamable_http"] ->
        case URI.parse(config["url"] || "") do
          %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
            {:ok, config}

          _ ->
            {:error, :invalid_url}
        end

      _ ->
        {:error, :unknown_transport}
    end
  end

  def secrets(map) do
    Enum.reduce_while(map || %{}, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case value do
        %{"env" => name} ->
          case System.get_env(name) do
            nil -> {:halt, {:error, {:missing_env, name}}}
            value -> {:cont, {:ok, Map.put(acc, key, value)}}
          end

        value when is_binary(value) ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        _ ->
          {:halt, {:error, :invalid_secret_value}}
      end
    end)
  end
end

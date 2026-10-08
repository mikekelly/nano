defmodule MCP.Config do
  @moduledoc """
  Committed JSON server catalog. `MCP.Config.load(path)` validates it and resolves exact
  `${ENV_NAME}` strings in `env` and `headers` from the OS environment (never evals code).
  No shell is involved: stdio `command` plus `args` execute directly. Trust config as code;
  servers have the permissions of this node. Credentials belong in environment variables,
  not the catalog. Explicit `protocol_version` selects legacy HTTP; default is modern.
  """
  def load(path) do
    with {:ok, json} <- File.read(path),
         {:ok, %{"servers" => servers}} when is_map(servers) <- Jason.decode(json) do
      Enum.reduce_while(servers, {:ok, %{}}, fn {name, config}, {:ok, acc} ->
        case validate(name, config) do
          {:ok, c} -> {:cont, {:ok, Map.put(acc, name, c)}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, reason} -> {:error, {:config, reason}}
      _ -> {:error, :config_requires_servers_object}
    end
  end

  defp validate(name, c) when is_map(c) do
    valid =
      is_binary(name) and name =~ ~r/^[a-zA-Z0-9_.-]{1,100}$/ and
        c["protocol_version"] in [
          nil,
          "auto",
          "2026-07-28",
          "2025-11-25",
          "2025-06-18",
          "2025-03-26",
          "2024-11-05"
        ] and
        valid_integer?(c["timeout_ms"], 100, 300_000) and
        valid_integer?(c["max_message_bytes"], 1024, 64_000_000)

    transport =
      case c["transport"] do
        "stdio" ->
          is_binary(c["command"]) and is_list(c["args"] || []) and
            Enum.all?(c["args"] || [], &is_binary/1) and (is_nil(c["cwd"]) or is_binary(c["cwd"]))

        "http" ->
          is_binary(c["url"]) and URI.parse(c["url"]).scheme in ["http", "https"] and
            not is_nil(URI.parse(c["url"]).host)

        _ ->
          false
      end

    if valid and transport do
      with {:ok, env} <- resolve(c["env"] || %{}),
           {:ok, headers} <- resolve(c["headers"] || %{}) do
        {:ok, c |> Map.put("env", env) |> Map.put("headers", headers)}
      end
    else
      {:error, {:invalid_server_config, name}}
    end
  end

  defp validate(name, _), do: {:error, {:invalid_server_config, name}}
  defp valid_integer?(nil, _, _), do: true
  defp valid_integer?(n, low, high), do: is_integer(n) and n >= low and n <= high

  defp resolve(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      if is_binary(k) and is_binary(v) do
        value =
          case Regex.run(~r/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/, v) do
            [_, name] -> System.get_env(name)
            nil -> v
          end

        if value,
          do: {:cont, {:ok, Map.put(acc, k, value)}},
          else: {:halt, {:error, {:missing_environment_variable, k}}}
      else
        {:halt, {:error, :env_and_headers_must_be_string_maps}}
      end
    end)
  end

  defp resolve(_), do: {:error, :env_and_headers_must_be_string_maps}
end

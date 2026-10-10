defmodule Nano.MCP.Config do
  @moduledoc """
  Source-controlled server definitions in `priv/mcp_servers.json` (override with
  application env `:nano, :mcp_config_path`). `servers` maps stable IDs to stdio
  (`command`, `args`, optional `cwd`, `env`) or HTTP (`url`, `headers`) definitions.
  Secrets must use `{"setting": "NAME"}` or `{"env": "NAME"}` references, resolved
  at connection time, never written to MCP state or reported in errors.
  Configured commands execute with the node's privileges: trust the config file.
  `priv/mcp_servers.example.json` is documentation only, not auto-loaded. Its stdio
  example requires Node/npx installed separately; the HTTP URL is a placeholder.
  Authorization references resolve the complete header value (including Bearer).
  Optional `subscription_timeout_ms` controls automatic restore/ack request timeout
  (default 10 seconds, clamped at 120 seconds). Restoration retries back off separately.
  """
  def path,
    do:
      Application.get_env(
        :nano,
        :mcp_config_path,
        Path.expand("../../../priv/mcp_servers.json", __DIR__)
      )

  def load do
    with {:ok, bytes} <- File.read(path()),
         {:ok, %{"servers" => servers}} when is_map(servers) <- Jason.decode(bytes) do
      {:ok, servers}
    else
      _ -> {:error, :invalid_mcp_config}
    end
  end

  def fetch(id) when is_binary(id) do
    with {:ok, servers} <- load(),
         {:ok, config} <- Map.fetch(servers, id),
         {:ok, resolved} <- resolve(config),
         :ok <- validate(resolved) do
      {:ok, resolved}
    else
      :error -> {:error, :unknown_server}
      error -> error
    end
  end

  def fetch(_), do: {:error, :invalid_server_id}

  def validate(%{"transport" => "stdio", "command" => cmd} = c)
      when is_binary(cmd) and cmd != "" do
    if is_list(Map.get(c, "args", [])) and Enum.all?(Map.get(c, "args", []), &is_binary/1) and
         string_map?(Map.get(c, "env", %{})) and (is_nil(c["cwd"]) or is_binary(c["cwd"])),
       do: :ok,
       else: {:error, :invalid_stdio_config}
  end

  def validate(%{"transport" => "http", "url" => url} = c) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h, userinfo: nil} when s in ["http", "https"] and is_binary(h) ->
        if string_map?(Map.get(c, "headers", %{})), do: :ok, else: {:error, :invalid_http_headers}

      _ ->
        {:error, :invalid_http_url}
    end
  end

  def validate(_), do: {:error, :invalid_transport_config}

  defp resolve(%{"setting" => key} = m) when map_size(m) == 1 and is_binary(key),
    do: secret(Nano.Settings.get(key))

  defp resolve(%{"env" => key} = m) when map_size(m) == 1 and is_binary(key),
    do: secret(System.get_env(key))

  defp resolve(m) when is_map(m) do
    Enum.reduce_while(m, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case resolve(v) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, k, resolved)}}
        error -> {:halt, error}
      end
    end)
  end

  defp resolve(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn v, {:ok, acc} ->
      case resolve(v) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp resolve(v), do: {:ok, v}

  defp string_map?(map) when is_map(map),
    do: Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end)

  defp string_map?(_), do: false
  defp secret(v) when is_binary(v) and v != "", do: {:ok, v}
  defp secret({:ok, v}), do: secret(v)
  defp secret(_), do: {:error, :missing_secret_setting}
end

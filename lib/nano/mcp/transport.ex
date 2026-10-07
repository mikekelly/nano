defmodule Nano.MCP.Transport do
  @moduledoc false
  def open(%{"command" => command} = config, _owner, _generation) do
    executable = System.find_executable(command)

    if executable do
      env =
        Enum.map(Map.get(config, "env", %{}), fn {key, value} ->
          value =
            if String.starts_with?(value, "${") and String.ends_with?(value, "}"),
              do: System.get_env(String.slice(value, 2, byte_size(value) - 3)) || "",
              else: value

          {String.to_charlist(key), String.to_charlist(value)}
        end)

      options = [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, Map.get(config, "args", [])},
        {:env, env}
      ]

      options = if config["cwd"], do: [{:cd, config["cwd"]} | options], else: options
      {:ok, {:stdio, Port.open({:spawn_executable, executable}, options)}}
    else
      {:error, :executable_not_found}
    end
  rescue
    _ -> {:error, :spawn_failed}
  end

  def open(%{"url" => url}, _owner, _generation) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, :http}

      _ ->
        {:error, :invalid_url}
    end
  end

  def open(_, _, _), do: {:error, :invalid_transport}

  def post({:stdio, port}, message, _config, _session, _version, _owner, _generation) do
    Port.command(port, [Jason.encode!(message), "\n"])
    :ok
  rescue
    _ -> {:error, :closed}
  end

  def post(:http, message, config, session, version, owner, generation) do
    spawn_link(fn -> http(:post, message, config, session, version, owner, generation) end)
    :ok
  end

  def listen(config, session, version, owner, generation) do
    spawn_link(fn -> http(:get, nil, config, session, version, owner, generation) end)
  end

  def close({:stdio, port}) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  def close(_), do: :ok

  defp http(method, message, config, session, version, owner, generation) do
    headers =
      Map.get(config, "headers", %{})
      |> Enum.map(fn {k, v} ->
        value =
          if String.starts_with?(v, "${") and String.ends_with?(v, "}"),
            do: System.get_env(String.slice(v, 2, byte_size(v) - 3)) || "",
            else: v

        {k, value}
      end)

    headers =
      headers ++
        [{"accept", "application/json, text/event-stream"}, {"mcp-protocol-version", version}]

    headers = if session, do: [{"mcp-session-id", session} | headers], else: headers
    # Send each chunk immediately, including on a never-ending SSE connection.
    into = fn {:data, data}, {req, resp} ->
      send(
        owner,
        {:http_chunk, generation, self(), method, message && message["id"], resp.status,
         resp.headers, data}
      )

      {:cont, {req, resp}}
    end

    opts = [
      url: config["url"],
      method: method,
      headers: headers,
      into: into,
      retry: false,
      redirect: false,
      receive_timeout: Map.get(config, "receive_timeout", 60_000)
    ]

    opts = if message, do: Keyword.put(opts, :json, message), else: opts
    result = Req.request(opts)
    send(owner, {:http_done, generation, self(), method, message && message["id"], result})
  rescue
    error ->
      send(
        owner,
        {:http_done, generation, self(), method, message && message["id"],
         {:error, Exception.message(error)}}
      )
  end

  @doc "Incremental SSE parser; returns complete decoded JSON messages and unconsumed bytes."
  def sse(buffer) do
    normalized = String.replace(buffer, "\r\n", "\n")
    parts = String.split(normalized, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)

    messages =
      Enum.flat_map(complete, fn frame ->
        data =
          frame
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "data:"))
          |> Enum.map(&String.trim_leading(String.slice(&1, 5..-1//1), " "))
          |> Enum.join("\n")

        case Jason.decode(data) do
          {:ok, message} when is_map(message) -> [message]
          _ -> []
        end
      end)

    {messages, rest}
  end
end

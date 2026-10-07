defmodule Vega.MCP.Config do
  @moduledoc false
  # In-memory only: credentials never enter child specifications or subscription
  # files. Connection start/restart arguments contain only the public server name.
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def init(_), do: {:ok, %{}}
  def put(name, config), do: GenServer.call(__MODULE__, {:put, name, config})
  def get(name), do: GenServer.call(__MODULE__, {:get, name})
  def handle_call({:put, name, config}, _, s), do: {:reply, :ok, Map.put(s, name, config)}
  def handle_call({:get, name}, _, s), do: {:reply, Map.fetch(s, name), s}

  def handle_call(_, _, s), do: {:reply, {:error, :invalid_request}, s}
  def handle_cast(_, s), do: {:noreply, s}
  def handle_info(_, s), do: {:noreply, s}

  def format_status(status),
    do: Vega.MCP.Redact.status(status, %{definitions: map_size(status.state)})

  def terminate(reason, _), do: Vega.MCP.Redact.terminate(reason, :config)
end

defmodule Vega.MCP.Redact do
  @moduledoc false
  # OTP 25+ format_status/1 keys include both debug snapshots and error reports.
  # Redact messages/log/reason too: they may contain a put config, RPC arguments,
  # remote error bodies, env values, or authorization headers.
  def status(status, summary) do
    Map.new(status, fn
      {:state, _} -> {:state, summary}
      {:message, _} -> {:message, :redacted}
      {:reason, _} -> {:reason, :redacted}
      {:log, _} -> {:log, []}
      pair -> pair
    end)
  end

  # Incidental protocol/transport failure payloads can echo supplied credentials.
  # Scrub configured string values (including Bearer/--key=value components) before
  # sending error events or returning RPC errors. Successful tool/resource content
  # is intentional user data and is not altered.
  def value(term, config) do
    sensitive = Map.take(config, ["headers", "env", "args"])

    secrets =
      strings(sensitive)
      |> Enum.flat_map(fn value ->
        [value | String.split(value, ~r/[\s=]/)]
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort_by(&byte_size/1, :desc)

    pattern =
      if secrets == [],
        do: nil,
        else: Regex.compile!(Enum.map_join(secrets, "|", &Regex.escape/1))

    scrub(term, pattern)
  end

  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_map(value), do: Enum.flat_map(value, fn {_, v} -> strings(v) end)
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(_), do: []

  defp scrub(value, nil) when is_binary(value), do: value

  defp scrub(value, pattern) when is_binary(value),
    do: Regex.replace(pattern, value, "[REDACTED]")

  defp scrub(value, secrets) when is_map(value),
    do: Map.new(value, fn {k, v} -> {scrub(k, secrets), scrub(v, secrets)} end)

  defp scrub(value, secrets) when is_list(value), do: Enum.map(value, &scrub(&1, secrets))

  defp scrub(value, secrets) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&scrub(&1, secrets)) |> List.to_tuple()

  defp scrub(value, _), do: value

  def terminate(reason, kind) when reason not in [:normal, :shutdown] do
    # format_status protects GenServer reports, but not Supervisor/proc_lib exit
    # reasons or stacktrace BIF arguments. Replace the actual abnormal exit reason
    # as well, and clear pending mailbox payloads before proc_lib reports them.
    drain()
    exit({:mcp_service_failure, kind})
  end

  def terminate(_, _), do: :ok

  defp drain do
    receive do
      _ -> drain()
    after
      0 -> :ok
    end
  end
end

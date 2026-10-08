defmodule MCP.Stdio do
  @moduledoc false
  use GenServer

  def start(config, owner), do: GenServer.start(__MODULE__, {config, owner})
  def send_message(pid, message), do: GenServer.cast(pid, {:send, message})
  def close(pid), do: GenServer.stop(pid, :normal)

  def init({config, owner}) do
    Process.flag(:trap_exit, true)
    Process.monitor(owner)
    command = config["command"]

    executable =
      if Path.type(command) == :absolute, do: command, else: System.find_executable(command)

    if executable do
      options = [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: config["args"] || [],
        cd: config["cwd"] || "/app",
        env:
          Enum.map(config["env"] || %{}, fn {k, v} ->
            {String.to_charlist(k), String.to_charlist(v)}
          end)
      ]

      port = Port.open({:spawn_executable, String.to_charlist(executable)}, options)

      {:ok,
       %{port: port, owner: owner, buffer: "", cap: config["max_message_bytes"] || 8_000_000}}
    else
      {:stop, {:command_not_found, command}}
    end
  rescue
    e -> {:stop, {:spawn_failed, Exception.message(e)}}
  end

  def handle_cast({:send, message}, state) do
    data = Jason.encode!(message) <> "\n"

    if byte_size(data) > state.cap do
      down(state, :outgoing_message_too_large)
    else
      Port.command(state.port, data)
      {:noreply, state}
    end
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case frames(state.buffer <> data, state) do
      {:ok, buffer} -> {:noreply, %{state | buffer: buffer}}
      {:error, reason} -> down(state, reason)
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state),
    do: down(state, {:exit_status, code})

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: down(state, {:port_exit, reason})

  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, state) do
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp frames(data, state) do
    case :binary.match(data, "\n") do
      :nomatch ->
        if byte_size(data) <= state.cap, do: {:ok, data}, else: {:error, :frame_too_large}

      {size, 1} when size > state.cap ->
        {:error, :frame_too_large}

      {size, 1} ->
        <<line::binary-size(^size), _::binary-size(1), rest::binary>> = data

        case Jason.decode(line) do
          {:ok, %{} = message} ->
            send(state.owner, {:mcp_transport, self(), {:message, message}})
            frames(rest, state)

          _ ->
            {:error, :invalid_json_rpc_frame}
        end
    end
  end

  defp down(state, reason) do
    send(state.owner, {:mcp_transport, self(), {:down, reason}})
    {:stop, :normal, state}
  end
end

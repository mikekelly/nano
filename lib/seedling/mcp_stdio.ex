defmodule Seedling.MCP.Stdio do
  @moduledoc false
  use GenServer
  def start_link(config, owner), do: GenServer.start_link(__MODULE__, {config, owner})
  def send_message(pid, message), do: GenServer.call(pid, {:send, message})
  def set_version(_pid, _version), do: :ok
  def close(pid), do: GenServer.stop(pid, :normal)

  def init({c, owner}) do
    command = c["command"]

    executable =
      if String.contains?(command, "/"), do: command, else: System.find_executable(command)

    if executable do
      opts = [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, Map.get(c, "args", [])},
        {:cd, Map.get(c, "cwd", "/app")},
        {:env,
         Enum.map(Map.get(c, "env", %{}), fn {k, v} ->
           {String.to_charlist(k), String.to_charlist(v)}
         end)}
      ]

      port = Port.open({:spawn_executable, executable}, opts)
      {:ok, %{port: port, owner: owner, buffer: ""}}
    else
      {:stop, {:executable_not_found, command}}
    end
  rescue
    e -> {:stop, {:stdio_start_failed, Exception.message(e)}}
  end

  def handle_call({:send, message}, _, s) do
    Port.command(s.port, Jason.encode!(message) <> "\n")
    {:reply, :ok, s}
  end

  def handle_info({port, {:data, bytes}}, %{port: port} = s) do
    combined = s.buffer <> bytes

    if byte_size(combined) > 8_000_000 do
      send(s.owner, {:mcp_transport_down, self(), :frame_too_large})
      {:stop, :normal, s}
    else
      lines = String.split(combined, "\n")
      {buffer, complete} = List.pop_at(lines, -1)

      Enum.each(complete, fn line ->
        case Jason.decode(line) do
          {:ok, m} when is_map(m) -> send(s.owner, {:mcp_message, self(), m})
          _ -> send(s.owner, {:mcp_transport_warning, self(), :invalid_json})
        end
      end)

      {:noreply, %{s | buffer: buffer}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = s) do
    send(s.owner, {:mcp_transport_down, self(), {:exit_status, status}})
    {:stop, :normal, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  def terminate(_, s) do
    if Port.info(s.port), do: Port.close(s.port)
    :ok
  end
end

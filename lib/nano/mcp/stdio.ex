defmodule Nano.MCP.Stdio do
  @moduledoc """
  MCP 2026-07-28 newline-delimited UTF-8 JSON subprocess transport.
  The same framing also supports legacy MCP servers.
  `start_link(owner, config)` accepts string keys command, args (default []),
  env (resolved string overrides, default %{}), cwd (optional), and
  max_message_bytes (positive integer, default 8 MiB).
  Commands execute directly, without a shell. Stderr inherits VM stderr and
  never enters the protocol stream. Owner receives
  `{:mcp_transport, pid, {:message, map}}` or `{:mcp_transport, pid, {:down, reason}}`.
  Framing errors notify and exit normally; JSON-RPC semantics belong to sessions.
  Owner death closes the port. stop/1 notifies :normal. Invalid JSON, non-objects,
  oversized frames and unterminated final frames fail closed.
  Spec: https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio
  """
  use GenServer
  def start_link(owner, config), do: GenServer.start_link(__MODULE__, {owner, config})
  def send_message(pid, message) when is_map(message), do: GenServer.call(pid, {:send, message})

  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :redacted) |> Map.put(:message, :redacted)

  @impl true
  def init({owner, config}) do
    Process.flag(:trap_exit, true)

    with true <- is_pid(owner), {:ok, options, limit} <- options(config) do
      try do
        port = Port.open({:spawn_executable, options.command}, options.port)

        {:ok,
         %{
           owner: owner,
           monitor: Process.monitor(owner),
           port: port,
           buffer: "",
           limit: limit,
           down: false,
           os_pid: elem(Port.info(port, :os_pid), 1)
         }}
      rescue
        e -> {:stop, {:spawn_failed, Exception.message(e)}}
      end
    else
      _ -> {:stop, :invalid_config}
    end
  end

  defp options(config) when is_map(config) do
    command = config["command"]
    args = Map.get(config, "args", [])
    env = Map.get(config, "env", %{})
    cwd = config["cwd"]
    limit = Map.get(config, "max_message_bytes", 8 * 1024 * 1024)

    if is_binary(command) and command != "" and is_list(args) and
         Enum.all?(args, &is_binary/1) and is_map(env) and
         Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end) and
         (is_nil(cwd) or is_binary(cwd)) and is_integer(limit) and limit > 0 do
      executable = System.find_executable(command) || command

      opts = [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: Enum.map(args, &String.to_charlist/1),
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ]

      opts = if cwd, do: opts ++ [cd: String.to_charlist(cwd)], else: opts
      {:ok, %{command: String.to_charlist(executable), port: opts}, limit}
    else
      {:error, :invalid_config}
    end
  end

  defp options(_), do: {:error, :invalid_config}

  @impl true
  def handle_call({:send, message}, _from, s) do
    case Jason.encode(message) do
      {:ok, json} when byte_size(json) <= s.limit ->
        try do
          true = Port.command(s.port, [json, "\n"])
          {:reply, :ok, s}
        rescue
          _ -> {:stop, :normal, {:error, :closed}, notify_down(s, :closed)}
        end

      {:ok, _} ->
        {:reply, {:error, :message_too_large}, s}

      {:error, _} ->
        {:reply, {:error, :invalid_message}, s}
    end
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = s) do
    case frames(s.buffer <> chunk, s) do
      {:ok, s} -> {:noreply, s}
      {:error, reason, s} -> {:stop, :normal, notify_down(s, reason)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = s) do
    reason = if s.buffer == "", do: {:exit_status, status}, else: :unterminated_frame
    {:stop, :normal, notify_down(s, reason)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = s),
    do: {:stop, :normal, notify_down(s, {:port_exit, reason})}

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = s),
    do: {:stop, :normal, s}

  def handle_info({:EXIT, _pid, reason}, s), do: {:stop, :normal, notify_down(s, reason)}
  def handle_info(_, s), do: {:noreply, s}

  defp frames(data, s) do
    case :binary.match(data, "\n") do
      {n, 1} when n > s.limit ->
        {:error, :message_too_large, s}

      {n, 1} ->
        <<line::binary-size(^n), _newline, rest::binary>> = data

        case Jason.decode(line) do
          {:ok, message} when is_map(message) ->
            send(s.owner, {:mcp_transport, self(), {:message, message}})
            frames(rest, s)

          _ ->
            {:error, :invalid_json_message, s}
        end

      :nomatch when byte_size(data) > s.limit ->
        {:error, :message_too_large, s}

      :nomatch ->
        {:ok, %{s | buffer: :binary.copy(data)}}
    end
  end

  defp notify_down(%{down: true} = s, _reason), do: s

  defp notify_down(s, reason) do
    send(s.owner, {:mcp_transport, self(), {:down, reason}})
    %{s | down: true}
  end

  @impl true
  def terminate(reason, s) do
    notify_down(s, reason)

    if Port.info(s.port) do
      Port.close(s.port)
      shutdown(s.os_pid)
    end

    :ok
  end

  # Port.close closes stdin but cannot guarantee an uncooperative child exits.
  defp shutdown(os_pid) do
    Process.sleep(100)

    if os_alive?(os_pid) do
      signal(os_pid, "-TERM")
      Process.sleep(100)
      if os_alive?(os_pid), do: signal(os_pid, "-KILL")
    end
  end

  defp os_alive?(pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp signal(pid, sig) do
    System.cmd("/bin/kill", [sig, Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end
end

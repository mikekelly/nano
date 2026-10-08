defmodule Seedling.MCP.OSProcess do
  @moduledoc false
  # Closing an Erlang Port only closes pipes. A stdio server can ignore EOF, and
  # killing the connection bypasses terminate/2. An independent short-lived
  # watchdog therefore monitors BOTH owners of the OS process's lifetime.
  def watch(port, owner) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        case identity(pid) do
          nil ->
            {:error, :os_identity_unavailable}

          identity ->
            watchdog =
              spawn(fn ->
                port_ref = :erlang.monitor(:port, port)
                owner_ref = Process.monitor(owner)

                receive do
                  {:DOWN, ref, _, _, _} when ref == port_ref or ref == owner_ref ->
                    reap(identity)
                end
              end)

            {:ok, watchdog}
        end

      _ ->
        {:error, :port_unavailable}
    end
  end

  # Linux /proc's starttime is stable for a process lifetime, unlike a PID alone.
  # Treat zombies as already exited (the Port driver or init owns wait/reaping).
  def identity(pid) when is_integer(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [_, fields] <- Regex.run(~r/^\d+ \(.*\) (.*)$/s, stat),
         [state | rest] <- String.split(fields),
         true <- state != "Z",
         start when is_binary(start) <- Enum.at(rest, 18) do
      %{pid: pid, start: start}
    else
      _ -> nil
    end
  end

  def alive?(%{pid: pid} = expected), do: identity(pid) == expected

  defp reap(identity) do
    # Give a cooperative server a brief chance to consume stdin EOF first.
    unless wait(identity, 50) do
      signal(identity, "TERM")

      unless wait(identity, 250) do
        signal(identity, "KILL")
        wait(identity, 250)
      end
    end
  end

  defp signal(%{pid: pid} = expected, signal) do
    # Always check immediately before signalling, including after the grace wait.
    # Never kill a process merely because it now happens to hold an old PID.
    if alive?(expected) do
      case System.find_executable("kill") do
        nil ->
          :unavailable

        executable ->
          System.cmd(executable, ["-" <> signal, to_string(pid)], stderr_to_stdout: true)
      end
    end
  end

  defp wait(identity, remaining) when remaining <= 0, do: not alive?(identity)

  defp wait(identity, remaining) do
    if alive?(identity) do
      Process.sleep(10)
      wait(identity, remaining - 10)
    else
      true
    end
  end
end

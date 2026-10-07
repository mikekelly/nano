defmodule Seedling.Shell do
  @moduledoc "Independent shell workers. Named notify resolves on completion (60s retry); no durable delivery or node-restart survival. Output saved on disk; kill/timeout signals OS group and leader. Detached descendants may escape."

  def start(command, opts \\ []) do
    owner = Keyword.get(opts, :notify, self())
    caller = self()

    if is_binary(command) and valid_timeout?(Keyword.get(opts, :timeout, 60000)) do
      {:ok,
       spawn(fn ->
         Process.put(:"$callers", [caller])
         run(command, opts, owner)
       end)}
    else
      {:error, :invalid_command_or_timeout}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def kill(pid) when is_pid(pid), do: send(pid, :kill_command)

  def sh(command, opts \\ []) do
    with {:ok, pid} <- start(command, Keyword.put(opts, :notify, self())) do
      monitor = Process.monitor(pid)

      receive do
        {:shell_done, ^pid, result} ->
          Process.demonitor(monitor, [:flush])

          case Seedling.Files.tail(result.path, opts) do
            {:ok, tail} -> {:ok, Map.merge(result, tail)}
            {:error, error} -> {:ok, Map.put(result, :output_error, error)}
          end

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          {:error, {:worker_exit, reason}}
      end
    end
  end

  defp run(command, opts, owner) do
    started = System.monotonic_time(:millisecond)
    root = Keyword.get(opts, :log_dir, "/data/seedling/tasks")

    path =
      Path.join(
        root,
        "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.log"
      )

    result =
      try do
        File.mkdir_p!(root)
        File.write!(path, "")

        port =
          Port.open({:spawn_executable, System.find_executable("python3")}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args,
             [
               "-c",
               "import os,sys\ntry: os.setsid()\nexcept PermissionError: pass\nos.execv('/bin/sh', ['sh','-c','exec >\"$1\" 2>&1; eval \"$2\"','seedling',sys.argv[1],sys.argv[2]])",
               path,
               command
             ]},
            {:cd, Keyword.get(opts, :cwd, "/app")},
            {:env,
             Enum.map(Keyword.get(opts, :env, []), fn {k, v} ->
               {String.to_charlist(k), String.to_charlist(v)}
             end)}
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        timeout = Keyword.get(opts, :timeout, 60000)

        timer =
          if is_integer(timeout),
            do: Process.send_after(self(), :command_timeout, timeout),
            else: nil

        {status, reason} = wait(port, os_pid)
        if timer, do: Process.cancel_timer(timer)
        %{status: status, reason: reason}
      rescue
        e -> %{status: nil, reason: {:error, Exception.message(e)}}
      end

    bytes =
      case File.stat(path) do
        {:ok, stat} -> stat.size
        _ -> 0
      end

    result =
      Map.merge(result, %{
        path: path,
        bytes: bytes,
        elapsed_ms: max(0, System.monotonic_time(:millisecond) - started)
      })

    deliver(owner, {:shell_done, self(), result}, 600)
  end

  defp wait(port, os_pid) do
    receive do
      {^port, {:exit_status, status}} ->
        {status, :exited}

      {^port, {:data, _}} ->
        wait(port, os_pid)

      reason when reason in [:kill_command, :command_timeout] ->
        # Before Python setsid, its group may not exist yet: also signal leader PID.
        System.cmd("/bin/kill", ["-KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)
        System.cmd("/bin/kill", ["-KILL", "--", "#{os_pid}"], stderr_to_stdout: true)

        receive do
          {^port, {:exit_status, status}} -> {status, reason}
        after
          5000 ->
            if Port.info(port), do: Port.close(port)
            {nil, reason}
        end
    end
  end

  defp valid_timeout?(t), do: t in [nil, :infinity] or (is_integer(t) and t >= 0)

  defp deliver(owner, message, attempts) when is_binary(owner) do
    case NanoAgent.whereis(owner) do
      nil when attempts > 0 ->
        Process.sleep(100)
        deliver(owner, message, attempts - 1)

      nil ->
        :undelivered

      pid ->
        send(pid, message)
    end
  end

  defp deliver(owner, message, _) when is_pid(owner), do: send(owner, message)
  defp deliver(_, _, _), do: :undelivered
end

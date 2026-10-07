defmodule Seedling.Shell do
  @moduledoc "Independent shell workers. start/2 returns {:ok, pid}; notify: agent name survives agent restart. Completion: {:shell_done, pid, %{status: integer, reason: atom, path: binary, bytes: integer}}. kill/1 kills the OS group. sh/2 waits and adds bounded tail. Options: cwd, env (string pairs), timeout (ms), log_dir. Workers survive agents, not node restarts."
  def start(command, opts \\ []) do
    caller = self()
    owner = Keyword.get(opts, :notify, caller)

    {:ok,
     spawn(fn ->
       Process.put(:"$callers", [caller])
       run(command, opts, owner)
     end)}
  end

  def kill(pid), do: send(pid, :kill_command)

  def sh(command, opts \\ []) do
    {:ok, pid} = start(command, Keyword.put(opts, :notify, self()))

    receive do
      {:shell_done, ^pid, result} ->
        with {:ok, tail} <- Seedling.Files.tail(result.path, opts),
             do: {:ok, Map.merge(result, tail)}
    end
  end

  defp run(command, opts, owner) do
    root = Keyword.get(opts, :log_dir, "/data/seedling/tasks")

    path =
      Path.join(
        root,
        "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.log"
      )

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
      timer = Process.send_after(self(), :command_timeout, Keyword.get(opts, :timeout, 60000))
      {status, reason} = wait(port, os_pid)
      Process.cancel_timer(timer)

      deliver(
        owner,
        {:shell_done, self(),
         %{status: status, reason: reason, path: path, bytes: File.stat!(path).size}},
        600
      )
    rescue
      e ->
        deliver(
          owner,
          {:shell_done, self(),
           %{status: nil, reason: {:error, Exception.message(e)}, path: path, bytes: 0}},
          600
        )
    end
  end

  defp wait(port, os_pid) do
    receive do
      {^port, {:exit_status, status}} ->
        {status, :exited}

      {^port, {:data, _}} ->
        wait(port, os_pid)

      reason when reason in [:kill_command, :command_timeout] ->
        System.cmd("/bin/kill", ["-KILL", "--", "-#{os_pid}"])

        receive do
          {^port, {:exit_status, status}} -> {status, reason}
        after
          5000 ->
            Port.close(port)
            {nil, reason}
        end
    end
  end

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

  defp deliver(owner, message, _), do: send(owner, message)
end

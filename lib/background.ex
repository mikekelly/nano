defmodule Background do
  @moduledoc """
  Detached shell jobs with disk output, process-group cancellation and restart-safe delivery.
  `{:ok, job} = Background.start("mix test", cwd: "/app", timeout: 120000)` returns immediately.
  Completion: `{:background, job.id, %{status: integer | :timeout | :cancelled, path: path,
  bytes: integer, duration_ms: integer}}`. `cancel(job)` stops its OS process group.
  `Workspace.tail(job.path)` reads bounded output. `notify:` accepts an agent name or pid;
  by default the calling agent's name is used so a process restart does not lose delivery.
  Jobs survive agent restarts, not node restarts; output and completion metadata remain on disk.
  """
  def start(command, opts \\ []) when is_binary(command) do
    owner =
      case Process.get(:"$callers", []) do
        [p | _] -> p
        _ -> self()
      end

    name = Enum.find(NanoAgent.list(), &(NanoAgent.whereis(&1) == owner))
    notify = opts[:notify] || name || owner
    id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    root = opts[:output_dir] || "/data/background/#{name || "external"}"
    path = Path.join(root, id <> ".log")

    with :ok <- File.mkdir_p(root), true <- File.dir?(opts[:cwd] || "/app") do
      caller = self()

      pid =
        spawn(fn ->
          # Keep attribution without a link to the short-lived eval task.
          Process.put(:"$ancestors", [owner])
          run(caller, id, path, command, notify, opts)
        end)

      receive do
        {^pid, :started} -> {:ok, %{id: id, pid: pid, path: path}}
        {^pid, {:error, reason}} -> {:error, reason}
      after
        5000 -> {:error, :start_timeout}
      end
    else
      false -> {:error, :invalid_cwd}
      error -> error
    end
  end

  def cancel(%{pid: pid}), do: send(pid, :cancel)
  defp quote_sh(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp run(caller, id, path, command, notify, opts) do
    started = System.monotonic_time(:millisecond)

    try do
      exe = System.find_executable("setsid") || raise "setsid required"
      script = "exec /bin/sh -c " <> quote_sh(command) <> " > " <> quote_sh(path) <> " 2>&1"

      port =
        Port.open({:spawn_executable, exe}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, ["--fork", "--wait", "/bin/sh", "-c", script]},
          {:cd, opts[:cwd] || "/app"},
          {:env, Enum.map(opts[:env] || [], fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}
        ])

      send(caller, {self(), :started})
      timer = Process.send_after(self(), :timeout, opts[:timeout] || 30_000)
      status = wait(port, path)
      Process.cancel_timer(timer)

      size =
        case File.stat(path) do
          {:ok, s} -> s.size
          _ -> 0
        end

      result = %{
        status: status,
        path: path,
        bytes: size,
        duration_ms: System.monotonic_time(:millisecond) - started
      }

      File.write(path <> ".json", Jason.encode!(result))
      deliver(notify, {:background, id, result})
    rescue
      e ->
        send(caller, {self(), {:error, Exception.message(e)}})

        deliver(
          notify,
          {:background, id, %{status: :error, path: path, error: Exception.message(e)}}
        )
    end
  end

  defp wait(port, path) do
    receive do
      {^port, {:exit_status, status}} ->
        status

      {^port, {:data, _}} ->
        wait(port, path)

      reason when reason in [:timeout, :cancel] ->
        case File.read(path <> ".pid") do
          {:ok, pid} ->
            if String.trim(pid) =~ ~r/^\d+$/,
              do:
                System.cmd("/bin/kill", ["-KILL", "--", "-#{String.trim(pid)}"],
                  stderr_to_stdout: true
                )

          _ ->
            :ok
        end

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          1000 -> Port.close(port)
        end

        if reason == :cancel, do: :cancelled, else: :timeout
    end
  end

  defp deliver(name, message) when is_binary(name), do: NanoAgent.notify(name, message)
  defp deliver(pid, message), do: send(pid, message)
end

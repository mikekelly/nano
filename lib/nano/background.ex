defmodule Nano.Background do
  @moduledoc """
  Unlinked shell jobs, independent of eval tasks and agent lifetimes.
  `start("mix test", owner: "alice", cwd: "/tmp/alice")` returns `{:ok, handle}`.
  Owner defaults to the agent whose eval called it, but must be a stable name.
  Completion arrives as `{:background, id, result}` (metadata only, no output).
  If owner is absent delivery waits until that name reappears. Delivery is at-most-once
  per worker; use `status(handle)` to retrieve persisted results after a missed event.
  `stop(handle)` kills the entire OS process group; `tail(handle, opts)` reads output.
  `run(command, opts)` is synchronous (20s default timeout, below default eval timeout).
  Background default timeout is one hour. Both accept cwd, env (string pairs), timeout
  (positive milliseconds), dir (unique parent storage), max_bytes and limit (tail bounds).
  Each job has a unique directory under the configured spill directory/background.
  Results and output survive agent restarts. Jobs do not promise execution/delivery across
  BEAM or worker death: persisted running metadata detects dead workers as interrupted.
  Operators can kill the dashboard worker; an independent monitor kills its OS group.
  No output is sent through the port, so noisy commands do not grow BEAM mailboxes.
  """
  def start(command, opts \\ []) do
    Nano.Tools.protect(fn ->
      owner = Keyword.get(opts, :owner) || infer_owner()
      if not is_binary(owner), do: raise(ArgumentError, "give owner: a stable agent name")
      launch(command, Keyword.put_new(opts, :timeout, 3_600_000), owner)
    end)
  end

  def run(command, opts \\ []) do
    Nano.Tools.protect(fn ->
      {:ok, handle} = launch(command, Keyword.put_new(opts, :timeout, 20_000), nil)
      ref = Process.monitor(handle.pid)

      receive do
        {:DOWN, ^ref, :process, _, _} ->
          with {:ok, result} <- status(handle),
               {:ok, output} <- tail(handle, opts),
               do: {:ok, Map.merge(result, output)}
      end
    end)
  end

  def status(%{dir: dir}) do
    Nano.Tools.protect(fn ->
      result = dir |> Path.join("status.term") |> File.read!() |> :erlang.binary_to_term([:safe])

      if result.status == :running and not Process.alive?(result.pid),
        do: {:ok, %{result | status: :interrupted}},
        else: {:ok, result}
    end)
  end

  def tail(%{dir: dir}, opts \\ []), do: Nano.Tools.tail(Path.join(dir, "output.log"), opts)

  def stop(%{pid: pid}) do
    if Process.alive?(pid),
      do:
        (
          send(pid, :stop)
          :ok
        ),
      else: {:error, "job worker is no longer running; inspect status"}
  end

  defp launch(command, opts, owner) do
    timeout = Keyword.fetch!(opts, :timeout)
    if not is_binary(command), do: raise(ArgumentError, "command must be a string")

    if not is_integer(timeout) or timeout <= 0,
      do: raise(ArgumentError, "timeout must be positive milliseconds")

    cwd = Path.expand(Keyword.get(opts, :cwd, "."))
    if not File.dir?(cwd), do: raise(ArgumentError, "cwd is not a directory: #{cwd}")
    executable = System.find_executable("setsid") || raise "setsid is required"

    env =
      Enum.map(Keyword.get(opts, :env, []), fn
        {k, v} when is_binary(k) and is_binary(v) -> {to_charlist(k), to_charlist(v)}
        _ -> raise ArgumentError, "env must contain string key/value pairs"
      end)

    id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    parent =
      Keyword.get(
        opts,
        :dir,
        Path.join(Application.get_env(:nano, :spill_dir, "/tmp/nano"), "background")
      )

    dir = Path.expand(Path.join(parent, id))
    File.mkdir_p!(dir)
    output = Path.join(dir, "output.log")
    File.write!(output, "")

    caller = self()
    ready = make_ref()

    pid =
      spawn(fn ->
        Process.put(:nano_background_owner, owner)
        send(caller, {ready, self()})

        receive do
          {:launch, handle} ->
            result =
              Nano.Tools.protect(fn ->
                execute(command, cwd, env, executable, output, timeout, handle)
              end)

            result =
              case result do
                {:ok, r} -> r
                {:error, e} -> Map.merge(handle, %{status: :failed, error: e, exit_code: nil})
              end

            save(dir, result)
            if owner, do: deliver(owner, {:background, id, Map.drop(result, [:pid])})
        end
      end)

    receive do
      {^ready, ^pid} -> :ok
    end

    handle = %{id: id, dir: dir, pid: pid, owner: owner, status: :running, output_path: output}
    save(dir, handle)
    send(pid, {:launch, handle})
    {:ok, handle}
  end

  defp execute(command, cwd, env, executable, output, timeout, handle) do
    # setsid creates a killable process group. Redirection is established before user code.
    pidfile = Path.join(handle.dir, "os.pid")

    script =
      "echo $$ >" <>
        quote_shell(pidfile) <> "; exec >" <> quote_shell(output) <> " 2>&1; " <> command

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--wait", "/bin/sh", "-c", script],
        cd: cwd,
        env: env
      ])

    os_pid = pidfile
    worker = self()

    guard =
      spawn(fn ->
        Process.put(:nano_background_owner, handle.owner)
        ref = Process.monitor(worker)

        receive do
          :finished -> Process.demonitor(ref, [:flush])
          {:DOWN, ^ref, :process, ^worker, _} -> kill_group(os_pid)
        end
      end)

    started = System.monotonic_time(:millisecond)
    timer = Process.send_after(self(), :timeout, timeout)

    {code, status} =
      receive do
        {^port, {:exit_status, code}} ->
          {code, :completed}

        :timeout ->
          kill_group(os_pid)
          {nil, :timed_out}

        :stop ->
          kill_group(os_pid)
          {nil, :killed}
      end

    send(guard, :finished)
    Process.cancel_timer(timer)
    Nano.Tools.protect(fn -> Port.close(port) end)

    {:ok,
     Map.merge(handle, %{
       status: status,
       exit_code: code,
       duration_ms: System.monotonic_time(:millisecond) - started,
       bytes: File.stat!(output).size
     })}
  end

  defp kill_group(pidfile, attempts \\ 20) do
    case File.read(pidfile) do
      {:ok, pid} ->
        System.cmd("/bin/kill", ["-KILL", "--", "-#{String.trim(pid)}"], stderr_to_stdout: true)

      _ when attempts > 0 ->
        Process.sleep(10)
        kill_group(pidfile, attempts - 1)

      _ ->
        :ok
    end
  end

  defp quote_shell(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp save(dir, result) do
    path = Path.join(dir, "status.term")
    File.write!(path <> ".tmp", :erlang.term_to_binary(result))
    File.rename!(path <> ".tmp", path)
  end

  defp deliver(owner, message) do
    case NanoAgent.whereis(owner) do
      nil ->
        Process.sleep(100)
        deliver(owner, message)

      pid ->
        send(pid, message)
    end
  end

  defp infer_owner do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      Enum.find_value(Nano.Names.all(), fn
        {{:agent, name}, ^pid} -> name
        _ -> nil
      end)
    end)
  end
end

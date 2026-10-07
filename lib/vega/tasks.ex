defmodule Vega.Tasks do
  @moduledoc """
  Detached shell tasks, with durable output and completion records.

      {:ok, task} = Vega.Tasks.start("mix test", cwd: "/app", agent: "vega", timeout: 120_000)
      Vega.Tasks.status(task)
      Vega.Tasks.read(task) # bounded tail; offset: 0 for forward byte paging
      Vega.Tasks.stop(task)

  A `{:vega_task, completion}` event contains status, exit code, byte count and
  paths, never command output. `agent:` names are resolved at delivery time and
  retried while absent, surviving agent/eval restarts. Without an agent, events
  go to `notify:` (defaults to caller pid). Use a name for restart-safe delivery.
  `root:` defaults to /data/vega-tasks; each task has its own random directory.

  Linux `setsid` and `/bin/kill` are required. Stop, timeout, normal completion,
  and abrupt controller death kill the command's process group, including
  children still running after the shell exits. Children deliberately escaping
  the session (daemonizing/setsid) are outside this guarantee. Tasks survive
  agent restarts, not BEAM/container restarts. Records remain readable after
  either. Named delivery retries while absent; delivery uses a cast, not a
  transactional acknowledgment. Use replay/2 for a delivery/restart race.
  See docs/vega-background-tasks.md for controls and limitations.
  """

  @doc "Starts immediately; env is a list of {name, value} pairs, timeout is milliseconds or :infinity."
  def start(command, opts \\ []) do
    with :ok <- validate(command, opts),
         executable when is_binary(executable) <- System.find_executable("setsid"),
         dir = Path.join(Path.expand(Keyword.get(opts, :root, "/data/vega-tasks")), id()),
         :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, "output.log"), "") do
      agent = Keyword.get(opts, :agent, infer_agent())

      record = %{
        id: Path.basename(dir),
        dir: dir,
        output_path: Path.join(dir, "output.log"),
        status_path: Path.join(dir, "status.term"),
        status: :starting,
        agent: agent,
        started_at: System.system_time(:millisecond),
        exit_code: nil,
        bytes: 0,
        completed_at: nil,
        delivered_at: nil
      }

      # Unlinked and not under Nano.EvalSupervisor: kill_tasks/1 cannot take us down.
      opts = Keyword.put_new(opts, :notify, self())

      pid =
        spawn(fn ->
          receive do
            {:run, ready} -> run(ready, command, opts, executable)
          end
        end)

      record = Map.put(record, :pid, pid)
      persist(record)
      send(pid, {:run, record})
      {:ok, record}
    else
      nil -> {:error, :setsid_not_found}
      error -> error
    end
  end

  @doc "Reads the atomically persisted task record (map handle or task directory)."
  def status(task) do
    with {:ok, data} <- File.read(Path.join(dir(task), "status.term")) do
      {:ok, :erlang.binary_to_term(data, [:safe])}
    end
  rescue
    _ -> {:error, :invalid_record}
  end

  @doc "Replays a persisted completion. Useful after node restart or a delivery/restart race."
  def replay(task, opts \\ []) do
    with {:ok, record} <- status(task) do
      if record.status in [:starting, :running] do
        {:error, :not_completed}
      else
        record = %{record | agent: Keyword.get(opts, :agent, record.agent)}
        notify = Keyword.get(opts, :notify, self())

        pid =
          spawn(fn ->
            stable_io()
            deliver(record, notify)
          end)

        {:ok, pid}
      end
    end
  end

  @doc "Requests group cleanup. Completion is asynchronous and delivered as usual."

  def stop(task) do
    with {:ok, %{pid: pid, status: state}} <- status(task) do
      if state in [:starting, :running] and Process.alive?(pid) do
        send(pid, :stop)
        :ok
      else
        {:error, :not_running}
      end
    end
  end

  @doc "Bounded byte paging, default tail. Returns next offset, total bytes and truncation flag."
  def read(task, opts \\ []) do
    path = Path.join(dir(task), "output.log")
    limit = Keyword.get(opts, :limit, 16_000)

    if is_integer(limit) and limit > 0 and limit <= 50_000 do
      with {:ok, stat} <- File.stat(path),
           offset = Keyword.get(opts, :offset, max(0, stat.size - limit)),
           true <- is_integer(offset) and offset >= 0 and offset <= stat.size,
           {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
        result = :file.pread(file, offset, min(limit, stat.size - offset))
        :file.close(file)

        case result do
          {:ok, text} ->
            {:ok,
             %{
               text: text,
               offset: offset,
               next: offset + byte_size(text),
               bytes: stat.size,
               truncated: offset > 0 or offset + byte_size(text) < stat.size,
               path: path
             }}

          :eof ->
            {:ok,
             %{
               text: "",
               offset: offset,
               next: offset,
               bytes: stat.size,
               truncated: offset > 0,
               path: path
             }}

          error ->
            error
        end
      else
        false -> {:error, :invalid_offset}
        error -> error
      end
    else
      {:error, :limit_must_be_1_to_50000}
    end
  end

  defp run(record, command, opts, executable) do
    Process.flag(:trap_exit, true)
    stable_io()
    attribute(record.agent)
    record = Map.put(record, :pid, self())
    persist(record)
    worker = self()
    guardian = spawn(fn -> guard(worker, record, opts) end)
    pgfile = Path.join(record.dir, "pgid")

    script =
      "echo $$ > " <>
        quote_sh(pgfile) <>
        "; exec /bin/sh -c " <>
        quote_sh(command) <> " > " <> quote_sh(record.output_path) <> " 2>&1"

    try do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["--wait", "/bin/sh", "-c", script],
          cd: Keyword.get(opts, :cwd, File.cwd!()),
          env:
            Enum.map(Keyword.get(opts, :env, []), fn {k, v} ->
              {String.to_charlist(k), if(v == nil, do: false, else: String.to_charlist(v))}
            end)
        ])

      timeout = Keyword.get(opts, :timeout, :infinity)
      timer = if timeout != :infinity, do: Process.send_after(self(), :timeout, timeout)
      record = %{record | status: :running}
      persist(record)
      {state, code} = wait(port, record.agent)
      if timer, do: Process.cancel_timer(timer)
      cleanup(record.dir)

      try do
        Port.close(port)
      catch
        _, _ -> :ok
      end

      complete(record, state, code, opts)
    catch
      kind, reason ->
        cleanup(record.dir)

        complete(
          Map.put(record, :error, Exception.format_banner(kind, reason)),
          :failed,
          nil,
          opts
        )
    after
      send(guardian, :finished)
    end
  end

  defp wait(port, agent) do
    attribute(agent)

    receive do
      {^port, {:exit_status, code}} -> {:completed, code}
      {^port, {:data, _}} -> wait(port, agent)
      {:EXIT, ^port, :normal} -> wait(port, agent)
      {:EXIT, ^port, reason} -> {:failed, reason}
      :stop -> {:stopped, nil}
      :timeout -> {:timed_out, nil}
    after
      250 -> wait(port, agent)
    end
  end

  defp complete(record, state, code, opts) do
    bytes =
      case File.stat(record.output_path) do
        {:ok, s} -> s.size
        _ -> 0
      end

    record = %{
      record
      | status: state,
        exit_code: code,
        bytes: bytes,
        completed_at: System.system_time(:millisecond)
    }

    persist(record)
    deliver(record, Keyword.get(opts, :notify))
  end

  defp deliver(record, notify) do
    attribute(record.agent)
    target = if record.agent, do: NanoAgent.whereis(record.agent), else: notify

    cond do
      is_pid(target) and Process.alive?(target) ->
        event = {:vega_task, Map.drop(record, [:pid])}
        if record.agent, do: NanoAgent.notify(record.agent, event), else: send(target, event)
        persist(%{record | delivered_at: System.system_time(:millisecond)})

      record.agent ->
        receive do
          :stop -> :ok
        after
          250 -> deliver(record, notify)
        end

      true ->
        :ok
    end
  end

  defp guard(worker, record, opts) do
    stable_io()
    attribute(record.agent)
    ref = Process.monitor(worker)
    guard_wait(worker, record, opts, ref)
  end

  defp guard_wait(worker, record, opts, ref) do
    attribute(record.agent)

    receive do
      :finished ->
        :ok

      {:DOWN, ^ref, :process, ^worker, reason} ->
        # The child can write pgid just after its controller dies during startup.
        Process.sleep(100)
        cleanup(record.dir)

        case status(record) do
          {:ok, %{status: state} = saved} when state in [:starting, :running] ->
            complete(Map.put(saved, :error, inspect(reason)), :failed, nil, opts)

          _ ->
            :ok
        end
    after
      250 -> guard_wait(worker, record, opts, ref)
    end
  end

  defp cleanup(dir) do
    with {:ok, text} <- pgid(dir, 100),
         {pid, ""} when pid > 1 <- Integer.parse(String.trim(text)) do
      System.cmd("/bin/kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)
    end

    :ok
  end

  defp pgid(dir, tries) do
    case File.read(Path.join(dir, "pgid")) do
      {:error, :enoent} when tries > 0 ->
        Process.sleep(10)
        pgid(dir, tries - 1)

      result ->
        result
    end
  end

  defp persist(record) do
    path = record.status_path
    temp = path <> "." <> id()
    File.write!(temp, :erlang.term_to_binary(record))
    File.rename!(temp, path)
  end

  defp stable_io do
    if leader = Process.whereis(:user), do: Process.group_leader(self(), leader)
  end

  defp attribute(nil), do: :ok

  defp attribute(agent) do
    if pid = NanoAgent.whereis(agent), do: Process.put(:"$callers", [pid])
  end

  defp infer_agent do
    callers = [self() | Process.get(:"$callers", [])]
    Enum.find(NanoAgent.list(), fn name -> NanoAgent.whereis(name) in callers end)
  end

  defp validate(command, opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    agent = Keyword.get(opts, :agent)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    env = Keyword.get(opts, :env, [])

    cond do
      not is_binary(command) or command == "" ->
        {:error, :command_must_be_nonempty_string}

      timeout != :infinity and (not is_integer(timeout) or timeout < 1) ->
        {:error, :invalid_timeout}

      agent != nil and not is_binary(agent) ->
        {:error, :agent_must_be_name}

      not is_binary(cwd) or not File.dir?(cwd) ->
        {:error, :cwd_must_be_existing_directory}

      not is_list(env) or
          not Enum.all?(env, fn
            {k, v} -> is_binary(k) and (is_binary(v) or v == nil)
            _ -> false
          end) ->
        {:error, :invalid_env}

      true ->
        :ok
    end
  end

  defp dir(%{dir: dir}), do: dir
  defp dir(dir) when is_binary(dir), do: dir
  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  defp quote_sh(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end

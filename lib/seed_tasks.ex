defmodule SeedTasks do
  @moduledoc """
  Detached shell jobs, disk-backed status, bounded output, and completion events.

  `start("mix test", cwd: "/app", owner: "agent-name", timeout: 120_000)`
  returns `{:ok, handle}` immediately. Use `status(handle)`, `tail(handle)`,
  and `cancel(handle)`. Completion is `{:seed_task, id, result}`; result has
  status, exit_code, bytes and output_path, never command output.

  Owner may be a pid or an agent name. Names are resolved again on delivery;
  workers wait while an agent is restarting. Workers are unlinked from eval,
  with `$callers` attribution for the dashboard. Caller/agent death does not
  kill commands. State and full merged stdout/stderr live under `root`
  (default `/data/seed_tasks`). Handles contain that root and are portable
  across evals. Finished status survives VM restart; running commands do not
  survive VM/container restart: call `reconcile(root)` on boot to mark orphan
  records `:interrupted` and replay pending named-owner completions. Named
  recipients call `ack(handle)` after processing; delivery is at-least-once,
  deduplicate by task id. Unacknowledged delivery follows owner pid changes.

  Integration: SeedTools.sh may delegate to this API, but must not wrap it in
  a linked Task. No application supervisor or harness reload is required.
  Linux `setsid`, `/bin/sh`, and `/bin/kill` are required. Commands are trusted
  shell input; environment is inherited with supplied overrides. Output files
  are deliberately not capped on disk: operators must manage retention/disk.
  Orientation entry: “Background commands: SeedTasks (module docs).”
  """

  def start(command, opts \\ []) do
    with :ok <- validate(command, opts),
         root = Path.expand(Keyword.get(opts, :root, "/data/seed_tasks")),
         :ok <- File.mkdir_p(root) do
      id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      handle = %{id: id, root: root}
      owner = Keyword.get(opts, :owner, self())
      callers = Process.get(:"$callers", [self()])

      pid =
        spawn(fn ->
          Process.put(:"$callers", callers)

          receive do
            {:go, state} -> run(state, command, opts, owner)
          end
        end)

      state =
        Map.merge(handle, %{
          status: :starting,
          boot_id: boot_id(),
          owner: owner,
          pending: is_binary(owner),
          worker: pid,
          output_path: Path.join(root, id <> ".log"),
          exit_code: nil,
          bytes: 0
        })

      case save(state) do
        :ok ->
          send(pid, {:go, state})
          {:ok, handle}

        error ->
          Process.exit(pid, :kill)
          error
      end
    end
  end

  def status(%{id: id, root: root}) do
    with {:ok, data} <- File.read(Path.join(root, id <> ".state")) do
      {:ok, :erlang.binary_to_term(data, [:safe])}
    end
  rescue
    _ -> {:error, :invalid_state}
  end

  @doc "Page output by zero-based byte offset; limit defaults to 16000 (maximum 50000)."
  def read(handle, opts \\ []) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 16000)

    if not (is_integer(offset) and offset >= 0 and is_integer(limit) and limit > 0 and
              limit <= 50000) do
      {:error, :invalid_limits}
    else
      with {:ok, state} <- status(handle),
           {:ok, stat} <- File.stat(state.output_path),
           {:ok, file} <-
             :file.open(String.to_charlist(state.output_path), [:read, :binary, :raw]) do
        result = :file.pread(file, offset, limit)
        :file.close(file)

        case result do
          {:error, reason} ->
            {:error, reason}

          value ->
            output =
              case value do
                {:ok, output} -> output
                :eof -> ""
              end

            next = offset + byte_size(output)

            {:ok,
             %{
               output: output,
               next_offset: next,
               eof: next >= stat.size,
               bytes: stat.size,
               output_path: state.output_path
             }}
        end
      end
    end
  end

  def cancel(handle) do
    with {:ok, state} <- status(handle) do
      if state.status in [:starting, :running] and Process.alive?(state.worker) do
        send(state.worker, :cancel)
        :ok
      else
        {:error, :not_running}
      end
    end
  end

  @doc "Read at most max_bytes (default 16000) and max_lines (default 200) from the output tail. Every cut is reported; full output_path is included."
  def tail(handle, opts \\ []) do
    bytes = Keyword.get(opts, :max_bytes, 16_000)
    lines = Keyword.get(opts, :max_lines, 200)

    if not (is_integer(bytes) and bytes > 0 and bytes <= 50_000 and is_integer(lines) and
              lines > 0 and lines <= 2000) do
      {:error, :invalid_limits}
    else
      with {:ok, state} <- status(handle),
           {:ok, stat} <- File.stat(state.output_path),
           {:ok, file} <-
             :file.open(String.to_charlist(state.output_path), [:read, :binary, :raw]) do
        offset = max(stat.size - bytes, 0)
        result = :file.pread(file, offset, bytes)
        :file.close(file)

        case result do
          {:error, reason} ->
            {:error, reason}

          other ->
            data =
              case other do
                {:ok, data} -> data
                :eof -> ""
              end

            parts = :binary.split(data, "\n", [:global])
            text = parts |> Enum.take(-lines) |> Enum.join("\n")

            {:ok,
             %{
               output: text,
               bytes: stat.size,
               truncated: offset > 0 or length(parts) > lines,
               output_path: state.output_path
             }}
        end
      end
    end
  end

  defp validate(command, opts) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    env = Keyword.get(opts, :env, [])

    cond do
      not is_binary(command) or command == "" ->
        {:error, :invalid_command}

      not (is_integer(timeout) and timeout > 0) ->
        {:error, :invalid_timeout}

      not is_binary(Keyword.get(opts, :cwd, File.cwd!())) ->
        {:error, :invalid_cwd}

      not is_list(env) or
          not Enum.all?(env, fn
            {k, v} -> is_binary(k) and is_binary(v)
            _ -> false
          end) ->
        {:error, :invalid_env}

      not (is_pid(Keyword.get(opts, :owner, self())) or
               is_binary(Keyword.get(opts, :owner, self()))) ->
        {:error, :invalid_owner}

      true ->
        :ok
    end
  end

  defp run(state, command, opts, owner) do
    try do
      port =
        Port.open({:spawn_executable, System.find_executable("setsid")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args,
           [
             "--wait",
             "/bin/sh",
             "-c",
             "echo $$ >\"$1.pid\"; exec >\"$1\" 2>&1; eval \"$2\"",
             "seed-task",
             state.output_path,
             command
           ]},
          {:cd, Keyword.get(opts, :cwd, File.cwd!())},
          {:env,
           Enum.map(Keyword.get(opts, :env, []), fn {k, v} ->
             {String.to_charlist(k), String.to_charlist(v)}
           end)}
        ])

      os_pid = read_pid(state.output_path <> ".pid", 100)
      running = Map.merge(state, %{status: :running, os_pid: os_pid})
      :ok = save(running)
      timer = Process.send_after(self(), :timeout, Keyword.get(opts, :timeout, 300_000))
      {status, code} = wait(port, os_pid)
      Process.cancel_timer(timer)
      kill_group(os_pid)
      finish(running, status, code, owner)
    rescue
      error -> finish(Map.put(state, :error, Exception.message(error)), :failed, nil, owner)
    end
  end

  defp read_pid(path, attempts) do
    case File.read(path) do
      {:ok, text} when text != "" ->
        String.to_integer(String.trim(text))

      _ when attempts > 0 ->
        Process.sleep(10)
        read_pid(path, attempts - 1)

      _ ->
        raise "shell failed before startup"
    end
  end

  defp wait(port, pid) do
    receive do
      {^port, {:exit_status, code}} ->
        {:exited, code}

      {^port, {:data, _}} ->
        wait(port, pid)

      reason when reason in [:cancel, :timeout] ->
        kill_group(pid)

        try do
          Port.close(port)
        rescue
          _ -> :ok
        end

        {if(reason == :cancel, do: :cancelled, else: :timed_out), nil}
    end
  end

  defp kill_group(pid) do
    System.cmd("/bin/kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)
    :ok
  end

  defp finish(state, status, code, owner) do
    bytes =
      case File.stat(state.output_path) do
        {:ok, stat} -> stat.size
        _ -> 0
      end

    result = Map.merge(state, %{status: status, exit_code: code, bytes: bytes})

    case save(result) do
      :ok ->
        if is_binary(owner), do: deliver(state, nil), else: notify(owner, event(result))

      {:error, reason} ->
        notify(
          owner,
          {:seed_task, state.id,
           %{status: :state_error, error: reason, output_path: state.output_path}}
        )
    end
  end

  @doc "Acknowledge a named-owner completion after handling it. Delivery is at-least-once across restarts; deduplicate by task id."
  def ack(handle) do
    with {:ok, state} <- status(handle) do
      if state.status in [:starting, :running],
        do: {:error, :not_finished},
        else: save(Map.put(state, :pending, false))
    end
  end

  @doc "Reconcile a root on application boot. Marks orphan active records interrupted (never signals stale OS pids), and replays unacknowledged named-owner completions. Call once on boot for each root; replay can duplicate deliveries, so deduplicate by id."
  def reconcile(root \\ "/data/seed_tasks") do
    with {:ok, names} <- File.ls(root) do
      results =
        for name <- names, String.ends_with?(name, ".state") do
          handle = %{root: Path.expand(root), id: String.trim_trailing(name, ".state")}

          case status(handle) do
            {:ok, state} ->
              active = state.status in [:starting, :running]

              orphan =
                active and
                  (Map.get(state, :boot_id) != boot_id() or not Process.alive?(state.worker))

              if orphan do
                bytes =
                  case File.stat(state.output_path) do
                    {:ok, st} -> st.size
                    _ -> 0
                  end

                interrupted =
                  Map.merge(state, %{status: :interrupted, exit_code: nil, bytes: bytes})

                case save(interrupted) do
                  :ok ->
                    replay(interrupted)
                    {:ok, state.id, :interrupted}

                  error ->
                    error
                end
              else
                unless active, do: replay(state)
                {:ok, state.id, state.status}
              end

            error ->
              error
          end
        end

      {:ok, results}
    end
  end

  defp boot_id, do: {:erlang.system_info(:start_time), :erlang.time_offset()}

  defp event(state),
    do: {:seed_task, state.id, Map.drop(state, [:worker, :root, :boot_id, :owner, :pending])}

  defp replay(%{pending: true, owner: owner} = state) when is_binary(owner),
    do: spawn(fn -> deliver(state, nil) end)

  defp replay(_), do: :ok

  defp deliver(handle, previous) do
    case status(handle) do
      {:ok, %{pending: true, owner: owner} = state} ->
        pid = NanoAgent.whereis(owner)
        if is_pid(pid) and pid != previous, do: send(pid, event(state))
        Process.sleep(250)
        deliver(handle, pid)

      _ ->
        :ok
    end
  end

  defp notify(owner, message) when is_pid(owner), do: send(owner, message)

  defp notify(owner, message) do
    case NanoAgent.whereis(owner) do
      pid when is_pid(pid) ->
        send(pid, message)

      _ ->
        Process.sleep(250)
        notify(owner, message)
    end
  end

  defp save(state) do
    path = Path.join(state.root, state.id <> ".state")

    with :ok <- File.write(path <> ".tmp", :erlang.term_to_binary(state)),
         :ok <- File.rename(path <> ".tmp", path),
         do: :ok
  end
end

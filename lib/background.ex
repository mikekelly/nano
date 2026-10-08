defmodule Background do
  @moduledoc """
  Detached shell jobs, disk output and process-group cancellation (Linux `setsid` required).

      {:ok, job} = Background.start("mix test", cwd: "/app", timeout: 120_000)
      Background.cancel(job)
      Background.result(job) # persisted completion, including output path and byte count

  Completion is `{:background, id, %{status: integer | :timeout | :cancelled | :error,
  path: path, bytes: integer, duration_ms: integer}}`. `Workspace.tail(job.path)` pages
  output. `env:` is a list/map of string pairs (nil unsets); `output_dir:` selects storage.
  Output is streamed to disk, not kept in BEAM memory; callers must manage disk retention.

  `notify:` accepts an agent name or pid. By default the calling agent's name is used.
  Workers are unlinked from evals, refresh dashboard attribution after agent restarts,
  and retry delivery while a named recipient is absent (up to `delivery_timeout:`, default
  24 hours). `result/1` remains available if that expires. Delivery uses the harness's
  asynchronous cast: there is no acknowledgement or exactly-once guarantee if a recipient
  dies at the instant of dispatch. A pid recipient cannot follow a restart.

  Jobs survive agent restarts, not node death (there is no node-crash OS-process recovery). A monitor guard kills the OS group and
  reports an error if the worker itself is killed (including by dashboard stop). Cancellation kills the entire session's
  initial process group, including grandchildren; a program deliberately escaping with
  `setsid`/`setpgid` is not contained. Successful shell exit also cleans up that group.
  No application supervisor startup changes are required.
  """

  def start(command, opts \\ [])

  def start(command, opts) when is_binary(command) and is_list(opts) do
    owner = caller()
    name = owner_name(owner)
    notify = Keyword.get(opts, :notify, name || owner)
    id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    root = opts[:output_dir] || "/data/background"
    path = Path.join(Path.expand(root), id <> ".log")

    with :ok <- validate(opts, notify),
         :ok <- File.mkdir_p(root),
         {:ok, exe} <- executable("setsid") do
      caller = self()
      ref = make_ref()

      {pid, monitor} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, true)
          Process.put(:background_owner, name)
          refresh_owner(name, owner)
          run(caller, ref, id, path, command, notify, {name, owner}, exe, opts)
        end)

      receive do
        {^ref, :started} ->
          Process.demonitor(monitor, [:flush])
          {:ok, %{id: id, pid: pid, path: path}}

        {^ref, {:error, reason}} ->
          Process.demonitor(monitor, [:flush])
          {:error, reason}

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          {:error, {:worker_down, reason}}
      after
        6_000 ->
          send(pid, :cancel)
          Process.demonitor(monitor, [:flush])
          {:error, :start_timeout}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def start(_, _), do: {:error, :invalid_command_or_options}

  @doc "Requests cancellation. Completion reports :cancelled; already finished jobs are unchanged."
  def cancel(%{pid: pid}) when is_pid(pid) do
    send(pid, :cancel)
    :ok
  end

  @doc "Reads persisted completion metadata (JSON string keys); :enoent means not yet completed."
  def result(%{path: path}) do
    with {:ok, text} <- File.read(path <> ".json"), do: Jason.decode(text)
  end

  defp validate(opts, notify) do
    cond do
      not File.dir?(opts[:cwd] || "/app") ->
        {:error, :invalid_cwd}

      not (is_pid(notify) or is_binary(notify)) ->
        {:error, :invalid_notify}

      not positive?(Keyword.get(opts, :timeout, 30_000)) ->
        {:error, :invalid_timeout}

      not positive?(Keyword.get(opts, :delivery_timeout, 86_400_000)) ->
        {:error, :invalid_delivery_timeout}

      true ->
        :ok
    end
  end

  defp positive?(n), do: is_integer(n) and n > 0 and n <= 4_294_967_295
  defp caller, do: List.first(Process.get(:"$callers", [])) || self()
  defp owner_name(pid), do: Enum.find(NanoAgent.list(), &(NanoAgent.whereis(&1) == pid))
  defp quote_sh(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp executable(name) do
    case System.find_executable(name) do
      nil -> {:error, "#{name} is required"}
      exe -> {:ok, exe}
    end
  end

  defp refresh_owner(name, fallback) do
    owner = if name, do: NanoAgent.whereis(name) || fallback, else: fallback
    Process.put(:"$ancestors", [owner])
  end

  defp run(caller, ref, id, path, command, notify, owner, exe, opts) do
    started = System.monotonic_time(:millisecond)
    # The pid printed *inside* setsid is the group leader, not setsid's waiting parent.
    script =
      "printf '%s\\n' \"$$\"; IFS= read -r start && exec /bin/sh -c " <>
        quote_sh(command) <>
        " > " <> quote_sh(path) <> " 2>&1"

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, ["--fork", "--wait", "/bin/sh", "-c", script]},
        {:cd, opts[:cwd] || "/app"},
        {:env,
         Enum.map(opts[:env] || [], fn {k, v} ->
           {to_charlist(k), if(is_nil(v), do: false, else: to_charlist(v))}
         end)}
      ])

    try do
      case handshake(port, "") do
        {:ok, pgid} ->
          Process.put(:background_pgid, pgid)
          worker = self()
          guard = spawn(fn -> guard(worker, pgid, id, path, notify, owner, started, opts) end)
          Process.put(:background_guard, guard)
          File.write!(path <> ".pid", Integer.to_string(pgid))
          Port.command(port, "go\n")
          Process.put(:background_started, true)
          send(caller, {ref, :started})
          timer = Process.send_after(self(), :timeout, opts[:timeout] || 30_000)

          status =
            try do
              wait(port, owner)
            after
              Process.cancel_timer(timer)
              kill_group(Process.delete(:background_pgid))
              if guard = Process.delete(:background_guard), do: send(guard, {:finished, self()})
            end

          await_stopped(port, status)

          result = %{
            status: status,
            path: path,
            bytes: file_size(path),
            duration_ms: System.monotonic_time(:millisecond) - started
          }

          result =
            case persist(path, result) do
              :ok -> result
              {:error, reason} -> Map.put(result, :metadata_error, inspect(reason))
            end

          deadline = System.monotonic_time(:millisecond) + (opts[:delivery_timeout] || 86_400_000)
          deliver(notify, {:background, id, result}, deadline, owner)

        {:error, reason} ->
          send(caller, {ref, {:error, reason}})
      end
    after
      if pgid = Process.delete(:background_pgid), do: kill_group(pgid)
      if guard = Process.delete(:background_guard), do: send(guard, {:finished, self()})
      if Port.info(port), do: Port.close(port)
    end
  rescue
    e ->
      if Process.get(:background_started) do
        result = %{
          status: :error,
          path: path,
          error: Exception.message(e),
          bytes: file_size(path)
        }

        persist(path, result)

        deliver(
          notify,
          {:background, id, result},
          System.monotonic_time(:millisecond) + (opts[:delivery_timeout] || 86_400_000),
          owner
        )
      else
        send(caller, {ref, {:error, Exception.message(e)}})
      end
  end

  defp guard(worker, pgid, id, path, notify, owner, started, opts) do
    ref = Process.monitor(worker)
    guard_wait(worker, ref, pgid, id, path, notify, owner, started, opts)
  end

  defp guard_wait(worker, ref, pgid, id, path, notify, {name, fallback} = owner, started, opts) do
    refresh_owner(name, fallback)

    receive do
      {:finished, ^worker} ->
        Process.demonitor(ref, [:flush])

      {:DOWN, ^ref, :process, ^worker, reason} ->
        kill_group(pgid)

        result = %{
          status: :error,
          error: "worker exited: #{inspect(reason)}",
          path: path,
          bytes: file_size(path),
          duration_ms: System.monotonic_time(:millisecond) - started
        }

        persist(path, result)

        deliver(
          notify,
          {:background, id, result},
          System.monotonic_time(:millisecond) + (opts[:delivery_timeout] || 86_400_000),
          owner
        )
    after
      100 -> guard_wait(worker, ref, pgid, id, path, notify, owner, started, opts)
    end
  end

  defp handshake(port, data) do
    receive do
      {^port, {:data, chunk}} ->
        data = data <> chunk

        cond do
          byte_size(data) > 64 ->
            {:error, :invalid_group_handshake}

          String.ends_with?(data, "\n") ->
            case Integer.parse(String.trim(data)) do
              {pid, ""} when pid > 1 -> {:ok, pid}
              _ -> {:error, :invalid_group_handshake}
            end

          true ->
            handshake(port, data)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:start_exit, status}}

      {:EXIT, ^port, reason} ->
        {:error, {:port_exit, reason}}
    after
      5_000 -> {:error, :group_handshake_timeout}
    end
  end

  defp wait(port, {name, fallback} = owner) do
    receive do
      {^port, {:exit_status, status}} -> status
      {^port, {:data, _}} -> wait(port, owner)
      {:EXIT, ^port, reason} -> {:port_exit, reason}
      :timeout -> :timeout
      :cancel -> :cancelled
    after
      100 ->
        refresh_owner(name, fallback)
        wait(port, owner)
    end
  end

  defp await_stopped(port, status) when status in [:timeout, :cancelled] do
    receive do
      {^port, {:exit_status, _}} -> :ok
      {:EXIT, ^port, _} -> :ok
    after
      1_000 -> :ok
    end
  end

  defp await_stopped(_, _), do: :ok

  defp kill_group(pgid) do
    System.cmd("/bin/kill", ["-KILL", "--", "-#{pgid}"], stderr_to_stdout: true)
    :ok
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end

  defp persist(path, result) do
    # Readers never see a partially written result.
    with :ok <- File.write(path <> ".json.tmp", Jason.encode!(result)),
         :ok <- File.rename(path <> ".json.tmp", path <> ".json"),
         do: :ok
  end

  defp deliver(pid, message, _, _) when is_pid(pid), do: send(pid, message)

  defp deliver(name, message, deadline, {owner_name, fallback} = owner) do
    refresh_owner(owner_name, fallback)

    case NanoAgent.whereis(name) do
      pid when is_pid(pid) ->
        NanoAgent.notify(pid, message)

      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          deliver(name, message, deadline, owner)
        end
    end
  end
end

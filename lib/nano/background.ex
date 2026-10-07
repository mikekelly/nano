defmodule Nano.Background do
  @moduledoc """
  Unlinked background shell jobs. `start(cmd, cwd: dir, env: [{"KEY", "value"}],
  timeout: 30000, notify: pid_or_agent_name)` returns `{:ok, %{id: id, path: path}}`.
  Completion: `{:nano_background, id, result}` (metadata only). Use an agent name
  as notify target to survive its restart. `status/1`, `kill/1`, `await/2`, `tail/2`.
  Jobs survive caller/eval death, not node/container death. Output files persist.
  """
  use GenServer

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, Keyword.put(opts, :name, __MODULE__))

  def start(command, opts \\ []) do
    try do
      unless is_binary(command) and is_list(opts),
        do: raise("command must be a string and opts a keyword list")

      timeout = Keyword.get(opts, :timeout, 30_000)
      unless is_integer(timeout) and timeout > 0, do: raise("timeout must be a positive integer")

      for key <- [:cwd, :output_dir] do
        value = Keyword.get(opts, key)
        unless is_nil(value) or is_binary(value), do: raise("#{key} must be a path string")
      end

      target = Keyword.get(opts, :notify)

      unless is_nil(target) or is_binary(target) or is_pid(target),
        do: raise("notify must be a pid, agent name or nil")

      env = Keyword.get(opts, :env, [])

      unless is_list(env) and
               Enum.all?(env, fn
                 {k, v} when is_binary(k) and is_binary(v) -> true
                 _ -> false
               end),
             do: raise("env must be a list of string pairs")

      ensure_started()
      callers = [self() | List.wrap(Process.get(:"$callers"))]

      owner =
        Enum.find_value(callers, fn pid ->
          try do
            case Registry.keys(Nano.Registry, pid) do
              [{:agent, name}] -> name
              _ -> nil
            end
          rescue
            _ -> nil
          end
        end)

      opts = Keyword.put_new(opts, :notify, owner || self())
      GenServer.call(__MODULE__, {:start, command, opts, callers})
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc "Delete finished metadata (not log files); running jobs are never pruned."
  def prune, do: call(:prune)
  def prune(id), do: call({:prune, id})
  @doc "Retry a completed job's notification after the automatic one-minute retry window."
  def notify_again(id, target), do: call({:notify_again, id, target})

  def status(id), do: call({:status, id})
  def kill(id), do: call({:kill, id})

  def tail(id, opts \\ []) do
    with {:ok, job} <- status(id), do: Nano.Tools.tail(job.path, opts)
  end

  def await(id, timeout \\ 35_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(id, deadline)
  end

  defp poll(id, deadline) do
    case status(id) do
      {:ok, %{state: :running}} ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: {:error, :await_timeout},
          else:
            (
              Process.sleep(20)
              poll(id, deadline)
            )

      other ->
        other
    end
  end

  defp call(message) do
    ensure_started()
    GenServer.call(__MODULE__, message)
  catch
    :exit, reason -> {:error, reason}
  end

  defp ensure_started do
    case GenServer.start(__MODULE__, %{}, name: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  def init(state), do: {:ok, state}

  def handle_call({:start, command, opts, callers}, _, state) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Keyword.get(opts, :output_dir, Path.join(System.tmp_dir!(), "nano-background"))

    with :ok <- File.mkdir_p(dir) do
      path = Path.join(dir, "#{id}.log")
      manager = self()

      worker =
        spawn(fn ->
          Process.put(:"$ancestors", callers)
          Process.put(:"$callers", callers)
          run(manager, id, command, path, opts)
        end)

      ref = Process.monitor(worker)

      job = %{
        id: id,
        path: path,
        pid: worker,
        ref: ref,
        state: :running,
        notify: Keyword.get(opts, :notify),
        started_at: System.monotonic_time(:millisecond)
      }

      {:reply, {:ok, Map.take(job, [:id, :path, :pid, :state])}, Map.put(state, id, job)}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:prune, id}, _, state) do
    case Map.get(state, id) do
      nil -> {:reply, {:error, :not_found}, state}
      %{state: :running} -> {:reply, {:error, :still_running}, state}
      _ -> {:reply, :ok, Map.delete(state, id)}
    end
  end

  def handle_call(:prune, _, state) do
    kept = Map.filter(state, fn {_, j} -> j.state == :running end)
    {:reply, {:ok, %{pruned: map_size(state) - map_size(kept)}}, kept}
  end

  def handle_call({:notify_again, id, target}, _, state) do
    case Map.get(state, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{state: :running} ->
        {:reply, {:error, :still_running}, state}

      job ->
        if is_pid(target) or is_binary(target) do
          notify(target, id, Map.drop(job, [:ref, :notify, :started_at, :pid]))
          {:reply, :ok, state}
        else
          {:reply, {:error, :invalid_target}, state}
        end
    end
  end

  def handle_call({:status, id}, _, state), do: {:reply, lookup(state, id), state}

  def handle_call({:kill, id}, _, state) do
    case Map.get(state, id) do
      %{state: :running, pid: pid} ->
        send(pid, :kill)
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :not_found}, state}

      _ ->
        {:reply, {:error, :already_finished}, state}
    end
  end

  def handle_info({:done, id, result}, state) do
    job = Map.fetch!(state, id)
    Process.demonitor(job.ref, [:flush])

    result =
      Map.merge(Map.take(job, [:id, :path]), result)
      |> Map.put(:duration_ms, System.monotonic_time(:millisecond) - job.started_at)

    notify(job.notify, id, result)
    {:noreply, Map.put(state, id, Map.merge(job, result))}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    case Enum.find(state, fn {_, j} -> j.ref == ref end) do
      {id, _} ->
        handle_info(
          {:done, id, %{state: :failed, error: inspect(reason), exit_status: nil}},
          state
        )

      nil ->
        {:noreply, state}
    end
  end

  defp lookup(state, id) do
    case Map.get(state, id) do
      nil -> {:error, :not_found}
      job -> {:ok, Map.drop(job, [:ref, :notify, :started_at])}
    end
  end

  defp notify(nil, _, _), do: :ok

  defp notify(target, id, result) when is_binary(target) do
    spawn(fn -> deliver(target, id, result, 120) end)
  end

  defp notify(pid, id, result), do: send(pid, {:nano_background, id, result})

  defp deliver(_, _, _, 0), do: :ok

  defp deliver(target, id, result, attempts) do
    case NanoAgent.whereis(target) do
      pid when is_pid(pid) ->
        send(pid, {:nano_background, id, result})

      _ ->
        Process.sleep(500)
        deliver(target, id, result, attempts - 1)
    end
  end

  defp run(manager, id, command, path, opts) do
    result =
      try do
        if not File.dir?(Keyword.get(opts, :cwd, File.cwd!())),
          do: raise("cwd must be an existing directory")

        executable = System.find_executable("setsid") || raise "setsid is required"

        env =
          Enum.map(Keyword.get(opts, :env, []), fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

        # Output redirection is passed as a positional parameter, never interpolated.
        port =
          Port.open({:spawn_executable, to_charlist(executable)}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args,
             [
               "--wait",
               "/bin/sh",
               "-c",
               "echo $$ > \"$2.pid\"; exec /bin/sh -c \"$1\" >\"$2\" 2>&1",
               "nano-background",
               command,
               path
             ]},
            {:cd, to_charlist(Keyword.get(opts, :cwd, File.cwd!()))},
            {:env, env}
          ])

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            nil -> nil
          end

        timer = Process.send_after(self(), :timeout, Keyword.get(opts, :timeout, 30_000))
        result = wait(port, os_pid, path)
        Process.cancel_timer(timer)
        result
      rescue
        e -> %{state: :failed, exit_status: nil, error: Exception.message(e)}
      end

    bytes =
      case File.stat(path) do
        {:ok, s} -> s.size
        _ -> 0
      end

    send(manager, {:done, id, Map.put(result, :bytes, bytes)})
  end

  defp wait(port, os_pid, path) do
    receive do
      {^port, {:exit_status, status}} ->
        %{state: :finished, exit_status: status}

      {^port, {:data, _}} ->
        wait(port, os_pid, path)

      reason when reason in [:kill, :timeout] ->
        group =
          case File.read(path <> ".pid") do
            {:ok, p} -> String.trim(p)
            _ -> if(os_pid, do: Integer.to_string(os_pid), else: nil)
          end

        if group,
          do: System.cmd("/bin/kill", ["-KILL", "--", "-#{group}"], stderr_to_stdout: true)

        try do
          Port.close(port)
        rescue
          _ -> :ok
        end

        %{state: if(reason == :kill, do: :killed, else: :timed_out), exit_status: nil}
    end
  end
end

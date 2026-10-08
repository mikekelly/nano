defmodule Seedling.Shell.Worker do
  @moduledoc false
  use GenServer

  @impl true
  def init({task, command, opts, caller, manager}) do
    # Attribution for Nano.Ops without linking lifetime to the eval task.
    Process.put(:"$callers", [caller])
    Process.flag(:trap_exit, true)

    with {:ok, io} <- File.open(task.output_path, [:write, :binary]) do
      env =
        Enum.map(Keyword.get(opts, :env, []), fn {k, v} ->
          {String.to_charlist(to_string(k)),
           if(is_nil(v), do: false, else: String.to_charlist(v))}
        end)

      port =
        Port.open({:spawn_executable, System.find_executable("setsid")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          :hide,
          {:cd, Keyword.get(opts, :cwd, File.cwd!())},
          {:env, env},
          {:args,
           [
             "--wait",
             "/bin/sh",
             "-c",
             "printf '%s' \"$$\" > \"$1\"; exec /bin/sh -c \"$2\"",
             "seedling-shell",
             task.group_path,
             command
           ]}
        ])

      task = Map.put(task, :pid, self())

      timer =
        case Keyword.get(opts, :timeout, 30_000) do
          :infinity -> nil
          ms -> Process.send_after(self(), :timeout, ms)
        end

      {:ok,
       %{
         task: task,
         port: port,
         io: io,
         manager: manager,
         timer: timer,
         started: System.monotonic_time(:millisecond),
         status: :exited,
         bytes: 0
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_cast(:cancel, state), do: stop_command(:cancelled, state)

  @impl true
  def handle_info(:timeout, state), do: stop_command(:timeout, state)

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case :file.write(state.io, data) do
      :ok ->
        {:noreply, %{state | bytes: state.bytes + byte_size(data)}}

      {:error, reason} ->
        kill_group(state.task)
        finish(nil, %{state | status: :error, reason: reason})
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state), do: finish(code, state)
  def handle_info({:EXIT, port, :normal}, %{port: port} = state), do: {:noreply, state}

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: finish(nil, Map.merge(state, %{status: :error, reason: reason}))

  def handle_info(:force_finish, state), do: finish(nil, state)
  def handle_info({:EXIT, _other, :normal}, state), do: {:noreply, state}

  defp stop_command(status, %{status: :exited} = state) do
    kill_group(state.task)
    Process.send_after(self(), :force_finish, 1_000)
    {:noreply, %{state | status: status}}
  end

  defp stop_command(_status, state), do: {:noreply, state}

  defp finish(code, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    File.close(state.io)
    # Clean up descendants even when the shell exits normally without waiting for them.
    kill_group(state.task)

    result = %{
      id: state.task.id,
      status: state.status,
      exit_code: code,
      bytes: state.bytes,
      output_path: state.task.output_path,
      result_path: state.task.result_path,
      duration_ms: System.monotonic_time(:millisecond) - state.started
    }

    result = if state[:reason], do: Map.put(result, :reason, inspect(state.reason)), else: result
    persist(state.task, result)
    send(state.manager, {:completed, self(), result})
    {:stop, :normal, state}
  end

  def persist(task, result) do
    temp = task.result_path <> ".tmp"

    with :ok <- File.write(temp, :erlang.term_to_binary(result)),
         do: File.rename(temp, task.result_path)
  end

  def kill_group(task) do
    case File.read(task.group_path) do
      {:ok, pid_text} ->
        case Integer.parse(pid_text) do
          {pid, ""} when pid > 1 ->
            System.cmd("/bin/kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end
end

defmodule Seedling.Shell.Tasks do
  @moduledoc false
  use GenServer
  alias Seedling.Shell
  alias Seedling.Shell.Worker

  def ensure_started do
    case GenServer.start(__MODULE__, nil, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> Shell.error(reason, "Cannot start shell manager: #{inspect(reason)}")
    end
  end

  def tracked?(id) when is_binary(id) do
    case Process.whereis(__MODULE__) do
      nil ->
        false

      pid ->
        try do
          GenServer.call(pid, {:tracked, id})
        catch
          :exit, _ -> false
        end
    end
  end

  def tracked?(_), do: false

  @impl true
  def init(_), do: {:ok, %{tasks: %{}, pending: []}}

  @impl true
  def handle_call({:tracked, id}, _from, state) do
    {:reply, Enum.any?(state.tasks, fn {_ref, info} -> info.task.id == id end), state}
  end

  def handle_call({:start, command, opts, caller}, _from, state) do
    id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    dir =
      Path.join(
        Path.expand(
          Keyword.get(opts, :spool_dir, Path.join(System.tmp_dir!(), "seedling-shell"))
        ),
        id
      )

    task = %{
      id: id,
      output_path: Path.join(dir, "output.log"),
      result_path: Path.join(dir, "result.term"),
      group_path: Path.join(dir, "group.pid")
    }

    notify = Keyword.get(opts, :notify, Worker.notification_target(caller))

    with :ok <- File.mkdir_p(dir),
         {:ok, pid} <- GenServer.start(Worker, {task, command, opts, caller, self()}) do
      task = Map.put(task, :pid, pid)
      ref = Process.monitor(pid)
      info = %{task: task, notify: notify}
      {:reply, {:ok, task}, put_in(state.tasks[ref], info)}
    else
      {:error, reason} ->
        {:reply, Shell.error(reason, "Cannot start command in #{dir}: #{inspect(reason)}"), state}
    end
  end

  @impl true
  def handle_info({:completed, pid, result}, state) do
    case Enum.find(state.tasks, fn {_ref, info} -> info.task.pid == pid end) do
      {ref, info} ->
        Process.demonitor(ref, [:flush])
        state = %{state | tasks: Map.delete(state.tasks, ref)}
        {:noreply, deliver(info.notify, result, state)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {info, tasks} ->
        Worker.kill_group(info.task)

        result = %{
          id: info.task.id,
          status: :error,
          exit_code: nil,
          reason: inspect(reason, limit: 20, printable_limit: 500),
          output_path: info.task.output_path,
          result_path: info.task.result_path,
          bytes: size(info.task.output_path),
          duration_ms: nil
        }

        Worker.persist(info.task, result)
        {:noreply, deliver(info.notify, result, %{state | tasks: tasks})}
    end
  end

  def handle_info(:retry, state) do
    pending = Enum.reject(state.pending, fn {target, result} -> send_to(target, result) end)
    if pending != [], do: Process.send_after(self(), :retry, 100)
    {:noreply, %{state | pending: pending}}
  end

  defp deliver(nil, _result, state), do: state

  defp deliver(target, result, state) do
    if send_to(target, result) do
      state
    else
      if state.pending == [], do: Process.send_after(self(), :retry, 100)
      %{state | pending: [{target, result} | state.pending]}
    end
  end

  defp send_to(target, result) do
    pid =
      case target do
        {:agent, name} -> if :ets.whereis(Nano.Names) != :undefined, do: NanoAgent.whereis(name)
        pid when is_pid(pid) -> pid
        name when is_atom(name) -> Process.whereis(name)
        _ -> nil
      end

    if is_pid(pid) and Process.alive?(pid) do
      send(pid, {:seedling_task, result.id, result})
      true
    else
      # Pids cannot come back. Retrying is only meaningful for stable names.
      is_pid(target)
    end
  end

  defp size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end
end

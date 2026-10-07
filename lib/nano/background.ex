defmodule Nano.Background do
  @moduledoc """
  Long shell commands without holding an eval open: start one, carry on, and be told by a
  mailbox message when it finishes (the seeding in `/app/seedings/background-tasks.md`).

      {:ok, id} = Nano.Background.start("mix test", timeout: 600_000)   # returns at once
      Nano.Background.status(id)     # %{state: :running | :exited | :killed, exit_status:, ...}
      Nano.Background.tail(id, 40)   # last 40 lines of its output
      Nano.Background.kill(id)
      Nano.Background.list()         # this agent's tasks (or all: Nano.Background.list(:all))

  When the command exits, is killed, or hits its timeout, the agent that started it gets

      {:nano_task, %{id: "b7", agent: "alice", command: "mix test", exit_status: 0,
                     timed_out: false, ms: 4213, output: "/data/tasks/b7.log",
                     bytes: 1024, state: :exited}}

  as an ordinary mailbox event, which wakes an idle agent. The event carries a size and a
  path, never the output, so a long build cannot flood the context; read it with `tail/2`
  or `Nano.Util.read(path, tail: true, max: 4000)`.

  The OS process is started by a port owned by a supervised process of this module, so it
  keeps running if the agent restarts; the handle and the completion message still work, and
  `recover/1` re-sends a completion event that was missed across a node restart.
  Data: one `.log` and one `.meta` file per task under `/data/tasks` (`NANO_DATA_DIR`).
  """

  use GenServer

  @registry __MODULE__.Registry
  @limits %{timeout: 3_600_000, tail_lines: 200, tail_bytes: 8_000, list_max: 100}

  @doc "The defaults this module applies: `timeout`, `tail_lines`, `tail_bytes`, `list_max`."
  def limits, do: @limits

  ## API

  @doc """
  Starts `command` with `sh -c` and returns `{:ok, id}` at once. Options:

    * `dir:` — working directory (default `/app`)
    * `env:` — extra environment as `[{"KEY", "value"}]`
    * `timeout:` — milliseconds after which the process is killed (default one hour)
    * `agent:` — the agent to notify (default: the agent whose eval is calling, else nil)
    * `name:` — a label for listings
    * `output:` — where to append stdout+stderr (default `<data>/tasks/<id>.log`)
  """
  def start(command, opts \\ []) when is_binary(command) do
    with {:ok, pid} <-
           DynamicSupervisor.start_child(Nano.Background.Tasks, {__MODULE__, {command, opts}}) do
      {:ok, GenServer.call(pid, :id)}
    end
  end

  @doc "`start/2`, returning the id or raising."
  def start!(command, opts \\ []) do
    {:ok, id} = start(command, opts)
    id
  end

  @doc """
  A task's state: `%{id:, agent:, command:, dir:, name:, started_at:, output:, state:
  (:running | :exited | :killed), exit_status:, ms:, bytes:}` or nil when unknown.
  `:killed` covers `kill/1` and a timeout (`timed_out: true` in the completion event).
  """
  def status(id) do
    case whereis(id) do
      nil ->
        from_disk(id)

      pid ->
        # The process may be finishing as we call (its `:stop` reply is sent before it
        # exits, but the registry entry can outlive it by a moment); fall back to the file.
        try do
          GenServer.call(pid, :info)
        catch
          :exit, _ -> from_disk(id)
        end
    end
  end

  @doc "The last `lines` lines of a task's output (default `limits().tail_lines`, ~8 KB cap)."
  def tail(id, lines \\ nil) do
    lines = lines || @limits.tail_lines

    case status(id) do
      %{output: path} when is_binary(path) ->
        case File.read(path) do
          {:ok, text} ->
            text
            |> String.split("\n")
            |> Enum.take(-lines)
            |> Enum.join("\n")
            |> Nano.Util.clip_tail(@limits.tail_bytes)

          {:error, reason} ->
            "unreadable output #{path}: #{inspect(reason)}"
        end

      _ ->
        "no such task: #{inspect(id)}"
    end
  end

  @doc "Kills a task (its whole process tree). `:ok`, or `{:error, :not_found}`."
  def kill(id) do
    case whereis(id) do
      nil ->
        {:error, :not_found}

      pid ->
        GenServer.cast(pid, :kill)
        :ok
    end
  end

  @doc """
  Tasks as status maps, newest first. `:mine` (default) is the calling agent's tasks and
  tasks with no agent; `:all` is every task on the node. Option `limit:`.
  """
  def list(scope \\ :mine, opts \\ []) do
    (disk_ids() ++ live_ids())
    |> Enum.uniq()
    |> Enum.map(&status/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(&in_scope?(&1, scope))
    |> Enum.sort_by(& &1.started_at, :desc)
    |> Enum.take(Keyword.get(opts, :limit, @limits.list_max))
  end

  defp in_scope?(_task, :all), do: true
  defp in_scope?(task, :mine), do: task.agent in [nil, Nano.Util.calling_agent()]

  @doc """
  Re-sends the completion event for finished tasks of `agent` that it never saw (its process
  or the node died between the exit and the message). Safe any time; returns how many were
  sent.
  """
  def recover(agent) do
    agent = to_string(agent)

    disk_tasks()
    |> Enum.filter(&(&1.agent == agent and &1.state != :running))
    |> Enum.map(fn task ->
      notify(task)
      :sent
    end)
    |> Enum.count()
  end

  @doc "Where task logs and meta files live (`<data>/tasks`)."
  def dir, do: Path.join(Nano.Util.data_dir(), "tasks")

  ## GenServer

  @doc false
  def start_link({command, opts}), do: GenServer.start_link(__MODULE__, {command, opts})

  @impl true
  def init({command, opts}) do
    dir = Keyword.get(opts, :dir, Nano.Util.app_dir())
    id = Keyword.get(opts, :id) || new_id()
    output = Keyword.get(opts, :output) || Path.join(dir(), id <> ".log")

    File.mkdir_p!(dir())
    File.touch!(output)

    state = %{
      id: id,
      command: command,
      dir: dir,
      env: Keyword.get(opts, :env, []),
      name: Keyword.get(opts, :name),
      agent: Keyword.get(opts, :agent) || Nano.Util.calling_agent(),
      output: output,
      timeout: Keyword.get(opts, :timeout, @limits.timeout),
      started_at: System.system_time(:millisecond),
      state: :running,
      exit_status: nil,
      drainer: nil,
      os_pid: nil
    }

    {:ok, state, {:continue, :spawn}}
  end

  # The port must be opened by, and its messages read by, one and the same process: a port
  # sends its data to its owner. So a dedicated drainer opens it, writes to the log file and
  # reports the exit back here. This GenServer stays responsive to :info and :kill meanwhile.
  @impl true
  def handle_continue(:spawn, state) do
    parent = self()
    ref = make_ref()

    drainer =
      spawn(fn -> drain(state.command, state.dir, state.env, state.output, parent, ref) end)

    receive do
      {^ref, :started, os_pid} ->
        Registry.register(@registry, state.id, %{})
        state = %{state | drainer: drainer, os_pid: os_pid}
        write_meta(state)
        if state.timeout > 0, do: Process.send_after(self(), :timeout, state.timeout)
        {:noreply, state}
    after
      5_000 ->
        Process.exit(drainer, :kill)
        {:stop, :normal, finish(%{state | state: :killed}, :killed, nil)}
    end
  end

  defp drain(command, dir, env, path, parent, ref) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        args: ["-c", command],
        cd: dir,
        env: Enum.map(env, &{to_charlist(elem(&1, 0)), to_charlist(elem(&1, 1))})
      ])

    os_pid = with {:os_pid, pid} <- Port.info(port, :os_pid), do: pid
    send(parent, {ref, :started, os_pid})
    loop(port, path, parent)
  end

  defp loop(port, path, parent) do
    receive do
      {^port, {:data, data}} ->
        # A best-effort append: the tasks directory may have been removed (a data reset).
        with :ok <- File.mkdir_p(Path.dirname(path)) do
          File.write(path, data, [:append])
        end

        loop(port, path, parent)

      {^port, {:exit_status, status}} ->
        send(parent, {:exit_status, status})
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    state = kill_drainer(state)
    {:stop, :normal, finish(state, :killed, nil)}
  end

  def handle_info({:exit_status, status}, state) do
    {:stop, :normal, finish(state, :exited, status)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:kill, state) do
    state = kill_drainer(state)
    {:stop, :normal, finish(state, :killed, nil)}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, info(state), state}
  def handle_call(:id, _from, state), do: {:reply, state.id, state}

  @impl true
  def terminate(_reason, state) do
    kill_drainer(state)
    :ok
  end

  # Kill the shell and everything it started (`sh -c` may spawn children of its own).
  defp kill_drainer(state) do
    if state.os_pid do
      System.cmd(
        "sh",
        ["-c", "kill -9 -#{state.os_pid} 2>/dev/null; kill -9 #{state.os_pid} 2>/dev/null"],
        stderr_to_stdout: true
      )
    end

    if state.drainer, do: Process.exit(state.drainer, :kill)
    %{state | drainer: nil}
  end

  # Once only: record how it ended, write the meta file, send the event.
  defp finish(state, state_name, status) do
    if state.state == :running do
      task = %{state | state: state_name, exit_status: status}
      write_meta(task)
      notify(task)
      task
    else
      state
    end
  end

  defp notify(task) do
    if task.agent do
      NanoAgent.notify(
        task.agent,
        {:nano_task,
         %{
           id: task.id,
           agent: task.agent,
           command: task.command,
           name: task.name,
           exit_status: task.exit_status,
           timed_out: task.state == :killed and task.exit_status == nil,
           ms: System.system_time(:millisecond) - task.started_at,
           output: task.output,
           bytes: file_size(task.output),
           state: task.state
         }}
      )
    end

    :ok
  end

  defp info(state) do
    state
    |> Map.take([
      :id,
      :agent,
      :command,
      :name,
      :dir,
      :output,
      :state,
      :exit_status,
      :started_at,
      :os_pid
    ])
    |> Map.put(:ms, System.system_time(:millisecond) - state.started_at)
    |> Map.put(:bytes, file_size(state.output))
  end

  defp whereis(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  defp live_ids, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  defp disk_ids,
    do: Enum.map(Path.wildcard(Path.join(dir(), "*.meta")), &Path.basename(&1, ".meta"))

  defp disk_tasks, do: disk_ids() |> Enum.map(&from_disk/1) |> Enum.reject(&is_nil/1)

  # A task whose process is gone: its meta file says how it ended.
  defp from_disk(id) do
    with {:ok, text} <- File.read(Path.join(dir(), id <> ".meta")),
         {:ok, map} <- Jason.decode(text),
         {:ok, state} <- safe_atom(map["state"]) do
      ended = map["ended_at"] || System.system_time(:millisecond)

      %{
        id: map["id"],
        agent: map["agent"],
        command: map["command"],
        name: map["name"],
        dir: map["dir"],
        output: map["output"],
        state: state,
        exit_status: map["exit_status"],
        started_at: map["started_at"],
        ms: ended - map["started_at"],
        bytes: file_size(map["output"])
      }
    else
      _ -> nil
    end
  end

  defp safe_atom(text) do
    {:ok, String.to_existing_atom(text)}
  rescue
    ArgumentError -> :error
  end

  defp write_meta(state) do
    File.write(
      Path.join(dir(), state.id <> ".meta"),
      Jason.encode!(%{
        id: state.id,
        agent: state.agent,
        command: state.command,
        name: state.name,
        dir: state.dir,
        output: state.output,
        state: to_string(state.state),
        exit_status: state.exit_status,
        started_at: state.started_at,
        ended_at: if(state.state == :running, do: nil, else: System.system_time(:millisecond))
      })
    )
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp new_id, do: Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
end

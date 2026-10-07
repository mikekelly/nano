defmodule Nano.Ops do
  @moduledoc """
  The one surface the dashboard, the HTTP API and the shell share: plain functions over
  `NanoAgent`, `Nano.User` and the process table. Nothing here calls into an agent process,
  because a suspended or busy agent cannot answer; agent state is read from `NanoAgent.info/1`.

      Nano.Ops.agents()
      Nano.Ops.start_agent("alice", model: "openai/gpt-4o-mini")
      Nano.Ops.tail("alice")
  """

  @inspect [pretty: true, limit: :infinity, printable_limit: :infinity]

  @doc """
  What an agent beyond the seed is pursuing and running, for the dashboard or a fresh agent:
  its open goals and its live background tasks. Reads plain modules (`Nano.Goals`,
  `Nano.Background`); present only on a seedling where those exist.
  """
  def agent_extras(name) do
    %{
      goals: best_effort(fn -> Nano.Goals.list(agent: name) |> Enum.take(20) end, []),
      tasks: best_effort(fn -> Nano.Background.list(:all) |> Enum.filter(&(&1.agent == name)) |> Enum.take(20) end, [])
    }
  end

  defp best_effort(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  ## Agents

  @doc "Info maps for all agents."
  def agents, do: for(name <- NanoAgent.list(), info = NanoAgent.info(name), do: info)

  @doc "One agent's info map, or nil."
  def agent(name), do: NanoAgent.info(name)

  @doc "An agent's pid, or nil."
  def whereis(name), do: NanoAgent.whereis(name)

  @doc "Starts an agent. `opts` as for `NanoAgent.start/1`, without `name`."
  def start_agent(name, opts \\ []), do: NanoAgent.start([name: name] ++ opts)

  @doc "Stops an agent for good: terminates its process, if running, and deletes its stored state."
  def stop_agent(name) do
    if agent(name) do
      with {:ok, pid} <- find(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        # Its evals and model requests run in tasks that would outlive it.
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(name)
    else
      {:error, :not_found}
    end
  end

  @doc "Kills an agent with reason `:operator_restart`; its supervisor restarts it with history."
  def restart_agent(name) do
    with {:ok, pid} <- find(name) do
      Process.exit(pid, :operator_restart)
      :ok
    end
  end

  @doc "Resumes an agent suspended with `:sys.suspend/1`."
  def resume(name) do
    with {:ok, pid} <- find(name) do
      :sys.resume(pid)
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Clears an agent's halt, whatever its reason (see `NanoAgent.info/1`)."
  def unhalt(name), do: with({:ok, _} <- find(name), do: NanoAgent.unhalt(name))

  @doc "An agent's log entries with seq > since, as read back from its JSONL file."
  def log(name, since \\ 0) do
    case agent(name) do
      %{id: id} -> Nano.Log.read(id, since)
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Prints an agent's last ten log entries in the calling shell, then each new one as it
  arrives. Returns `{:ok, pid}` of the printing process; it stops when the shell process
  exits, or with `Process.exit(pid, :kill)`.
  """
  def tail(name) do
    case agent(name) do
      %{id: id} ->
        {shell, out} = {self(), Process.group_leader()}

        {:ok,
         spawn(fn ->
           ref = Process.monitor(shell)
           Nano.Log.subscribe(id)
           backlog = id |> Nano.Log.read() |> Enum.take(-10)
           Enum.each(backlog, &IO.puts(out, format_entry(&1)))
           follow(ref, out, backlog |> Enum.map(&seq/1) |> Enum.max(fn -> 0 end))
         end)}

      nil ->
        {:error, :not_found}
    end
  end

  defp follow(ref, out, last) do
    receive do
      {:nano_log, entry} ->
        if seq(entry) > last, do: IO.puts(out, format_entry(entry))
        follow(ref, out, max(last, seq(entry)))

      {:DOWN, ^ref, _, _, _} ->
        :ok
    end
  end

  # Live entries have atom keys, entries read back from disk have string keys.
  defp seq(entry), do: entry[:seq] || entry["seq"]

  defp format_entry(entry) do
    e = Map.new(entry, fn {k, v} -> {to_string(k), v} end)
    rest = Map.drop(e, ~w(seq at agent_id agent type))
    "[#{e["seq"]}] #{e["at"]} #{e["agent"]} #{e["type"]} #{inspect(rest, @inspect)}"
  end

  defp find(name) do
    case whereis(name) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  ## Processes

  @doc """
  Live processes outside the standard set, agents first. Each is a map with `pid`, `name`
  (agent or user name, or registered name), `kind` (`:agent`, `:user`, `{:spawned_by, agent_name}`
  or `:other`), `current_function`, `message_queue_len`, `memory`, `reductions`, and `agent`
  (the agent's info map, for agents). The caller computes reductions per second from deltas.

  A process is spawned by an agent if the agent's evals started it (the `spawned` pids the
  agent records), or if its parent, `$callers` or `$ancestors` chain reaches the agent, its
  running eval, or one of those pids. The standard set is the processes alive at boot, the
  agents' own model requests, processes of other OTP applications (Finch pools, kernel
  helpers: their group leader is that application's master), and anything under
  `NanoWeb.Endpoint` (connection handlers, LiveViews, channels).
  """
  def processes do
    ctx = context()

    Process.list()
    |> Enum.map(&{&1, kind(&1, ctx)})
    |> Enum.reject(fn {_, kind} -> kind == :standard end)
    |> Enum.flat_map(fn {pid, kind} -> List.wrap(row(pid, kind, ctx)) end)
    |> Enum.sort_by(&if(&1.kind == :agent, do: {0, &1.name}, else: {1, nil}))
  end

  @doc "`Process.info/1` for a target (see `resolve/1`) as a map, plus `pid` and `kind`; nil if not alive."
  def process(target) do
    with pid when is_pid(pid) <- resolve(target),
         info when is_list(info) <- Process.info(pid) do
      info |> Map.new() |> Map.merge(%{pid: pid, kind: kind(pid, context())})
    end
  end

  defp row(pid, kind, ctx) do
    keys = [:registered_name, :current_function, :message_queue_len, :memory, :reductions]

    with info when is_list(info) <- Process.info(pid, keys) do
      name = with {_, name} <- ctx.names[pid], do: name
      registered = if info[:registered_name] != [], do: info[:registered_name]

      info
      |> Map.new()
      |> Map.delete(:registered_name)
      |> Map.merge(%{
        pid: pid,
        name: name || registered,
        kind: kind,
        agent: if(kind == :agent, do: NanoAgent.info(name))
      })
    end
  end

  defp context do
    # pid => {:agent, name} | {:user, name}
    names =
      Map.new(Registry.select(Nano.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$2", :"$1"}}]}]))

    agents = Nano.StateStore.all()

    %{
      boot: Nano.Application.boot_set(),
      endpoint: Process.whereis(NanoWeb.Endpoint),
      names: names,
      model_requests: for(%{task: %{kind: :model, task: %{pid: pid}}} <- agents, do: pid),
      # pid => agent name: each agent, its running eval, and what its evals started.
      owned:
        Map.new(
          for({pid, {:agent, name}} <- names, do: {pid, name}) ++
            for(
              %{name: name, spawned: spawned} = s <- agents,
              pid <- spawned ++ for(%{kind: :eval, task: %{pid: p}} <- [s.task], do: p),
              do: {pid, name}
            )
        )
    }
  end

  defp kind(pid, ctx) do
    case ctx.names[pid] do
      {:agent, _} -> :agent
      {:user, _} -> :user
      _ -> unnamed_kind(pid, ctx)
    end
  end

  defp unnamed_kind(pid, ctx) do
    chain = [pid | chain(pid)]

    cond do
      MapSet.member?(ctx.boot, pid) or pid in ctx.model_requests -> :standard
      agent = Enum.find_value(chain, &ctx.owned[&1]) -> {:spawned_by, agent}
      ctx.endpoint in chain -> :standard
      :application.get_application(pid) not in [:undefined, {:ok, :nano}] -> :standard
      true -> :other
    end
  end

  # Who started the process: its parent, then the `$callers` (Task) and `$ancestors`
  # (proc_lib) chains from its dictionary, registered names resolved to pids.
  defp chain(pid) do
    case Process.info(pid, [:parent, {:dictionary, :"$callers"}, {:dictionary, :"$ancestors"}]) do
      [{:parent, parent}, {_, callers}, {_, ancestors}] ->
        for link <- [parent | List.wrap(callers) ++ List.wrap(ancestors)],
            do: if(is_atom(link), do: Process.whereis(link), else: link)

      nil ->
        []
    end
  end

  ## Targets and evaluation

  @doc """
  Resolves a target to a live local pid, or nil: a pid, an agent name, a user name, a
  registered name (`"Nano.StateStore"`, `":logger"`, or an atom), or a pid string (`"#PID<0.231.0>"`).
  """
  def resolve(pid) when is_pid(pid), do: if(node(pid) == node() and Process.alive?(pid), do: pid)

  def resolve(name) when is_atom(name),
    do: with(pid when is_pid(pid) <- Process.whereis(name), do: pid)

  def resolve(target) when is_binary(target) do
    NanoAgent.whereis(target) || Nano.User.pid(target) || pid_string(target) || registered(target)
  end

  def resolve(_), do: nil

  defp pid_string(string) do
    case Regex.run(~r/^(?:#PID)?<0\.(\d+)\.(\d+)>$/, string) do
      [_, a, b] -> resolve(:c.pid(0, String.to_integer(a), String.to_integer(b)))
      nil -> nil
    end
  end

  defp registered(string) do
    Enum.find_value([string, String.trim_leading(string, ":"), "Elixir." <> string], fn s ->
      try do
        resolve(String.to_existing_atom(s))
      rescue
        ArgumentError -> nil
      end
    end)
  end

  @doc """
  Evaluates Elixir source on the node, like `bin/rpc`, the way an agent's eval tool does
  (`NanoAgent.run_eval/2`, in a task killed after `EVAL_TIMEOUT_MS`): `{:ok, inspected_result,
  output}` or `{:error, message, output}`, where output is what the code printed.
  """
  def eval(code) do
    timeout = Application.fetch_env!(:nano, :eval_timeout_ms)
    task = Task.Supervisor.async_nolink(Nano.EvalSupervisor, NanoAgent, :run_eval, [code, []])

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {{:ok, result, _bindings}, output, _spawned}} -> {:ok, result, output}
      {:ok, {{:error, message}, output, _spawned}} -> {:error, message, output}
      {:exit, reason} -> {:error, Exception.format_banner(:exit, reason), ""}
      nil -> {:error, "timed out after #{timeout} ms", ""}
    end
  end

  @doc "Parses and evaluates Elixir source to a term, as the send forms do: `{:ok, term}` or `{:error, message}`."
  def term(code) do
    {value, _binding} = code |> Code.string_to_quoted!() |> Code.eval_quoted()
    {:ok, value}
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason, __STACKTRACE__)}
  end
end

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
      with {:ok, pid} <- find(name),
           do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

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

  @doc "Clears an agent's halt (budget or restart brake)."
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

  The standard set is the processes alive at boot, plus those started since by other OTP
  applications (Finch pools, kernel helpers: their group leader is that application's master)
  and anything under `NanoWeb.Endpoint` (connection handlers, LiveViews, channels).
  """
  def processes do
    ctx = context()

    Process.list()
    |> Enum.map(&{&1, kind(&1, ctx, [])})
    |> Enum.reject(fn {_, kind} -> kind == :standard end)
    |> Enum.flat_map(fn {pid, kind} -> List.wrap(row(pid, kind, ctx)) end)
    |> Enum.sort_by(&if(&1.kind == :agent, do: {0, &1.name}, else: {1, nil}))
  end

  @doc "`Process.info/1` for a target (see `resolve/1`) as a map, plus `pid` and `kind`; nil if not alive."
  def process(target) do
    with pid when is_pid(pid) <- resolve(target),
         info when is_list(info) <- Process.info(pid) do
      info |> Map.new() |> Map.merge(%{pid: pid, kind: kind(pid, context(), [])})
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
    %{
      boot: Nano.Application.boot_set(),
      endpoint: Process.whereis(NanoWeb.Endpoint),
      # pid => {:agent, name} | {:user, name}
      names:
        Map.new(Registry.select(Nano.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$2", :"$1"}}]}]))
    }
  end

  # Who a process belongs to, judged from who started it: its parent, then the `$callers`
  # (Task) and `$ancestors` (proc_lib) chains in its process dictionary. Any agent in the
  # chain makes it the agent's; otherwise the nearest live process in the chain decides.
  defp kind(pid, ctx, seen) do
    case ctx.names[pid] do
      {:agent, _} -> :agent
      {:user, _} -> :user
      _ -> if MapSet.member?(ctx.boot, pid), do: :standard, else: started_by(pid, ctx, seen)
    end
  end

  defp started_by(pid, ctx, seen) do
    links = links(pid)

    cond do
      agent =
          Enum.find_value(
            links,
            &with({:agent, name} <- ctx.names[&1], do: name, else: (_ -> nil))
          ) ->
        {:spawned_by, agent}

      ctx.endpoint in [pid | links] or
          :application.get_application(pid) not in [:undefined, {:ok, :nano}] ->
        :standard

      true ->
        nearest(links, ctx, [pid | seen])
    end
  end

  # The nearest live process it came from: a boot-time process (e.g. a supervisor of ours)
  # tells us nothing more, so the process is "other"; a later one passes on its own kind.
  defp nearest([link | _], ctx, seen) do
    if link in seen or MapSet.member?(ctx.boot, link) do
      :other
    else
      case kind(link, ctx, seen) do
        :user -> :other
        kind -> kind
      end
    end
  end

  defp nearest([], _ctx, _seen), do: :other

  defp links(pid) do
    case Process.info(pid, [:parent, {:dictionary, :"$callers"}, {:dictionary, :"$ancestors"}]) do
      [{:parent, parent}, {_, callers}, {_, ancestors}] ->
        for link <- [parent | List.wrap(callers) ++ List.wrap(ancestors)],
            link <- [if(is_atom(link), do: Process.whereis(link), else: link)],
            is_pid(link) and node(link) == node() and Process.alive?(link),
            uniq: true,
            do: link

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
  Evaluates Elixir source on the node, like `bin/rpc`: `{:ok, inspected_result, output}` or
  `{:error, message, output}`, where output is anything the code printed. Runs in a task under
  `Nano.EvalSupervisor`, killed after `EVAL_TIMEOUT_MS`.
  """
  def eval(code) do
    with {:ok, value, output} <- run(code), do: {:ok, inspect(value, @inspect), output}
  end

  @doc "Parses and evaluates Elixir source to a term, as the send forms do: `{:ok, term}` or `{:error, message}`."
  def term(code) do
    case run(code) do
      {:ok, value, _} -> {:ok, value}
      {:error, message, _} -> {:error, message}
    end
  end

  defp run(code) do
    {:ok, io} = StringIO.open("")
    timeout = Application.get_env(:nano, :eval_timeout_ms, 30_000)

    task =
      Task.Supervisor.async_nolink(Nano.EvalSupervisor, fn ->
        Process.group_leader(self(), io)

        try do
          {value, _binding} = code |> Code.string_to_quoted!() |> Code.eval_quoted()
          {:ok, value}
        catch
          kind, reason -> {:error, Exception.format_banner(kind, reason, __STACKTRACE__)}
        end
      end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, reason} -> {:error, Exception.format_banner(:exit, reason)}
        nil -> {:error, "timed out after #{timeout} ms"}
      end

    # Processes the code spawned inherited the capture device; give them the caller's instead.
    for pid <- Process.list(), Process.info(pid, :group_leader) == {:group_leader, io} do
      try do
        Process.group_leader(pid, Process.group_leader())
      rescue
        ArgumentError -> :exited
      end
    end

    {:ok, {_, output}} = StringIO.close(io)
    {tag, value} = result
    {tag, value, output}
  end
end

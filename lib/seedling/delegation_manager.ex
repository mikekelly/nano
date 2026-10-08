defmodule Seedling.Delegation.Manager do
  @moduledoc """
  Durable delegation watches; start after Nano.StateStore. Use Seedling.Delegation's API.
  Pending reports wait for a named parent to return. Delivery is at-least-once across
  manager/node crashes; parents can deduplicate by the event's `report_id`.
  """
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case Supervisor.start_child(Nano.Supervisor, {__MODULE__, []}) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, :already_present} -> Supervisor.restart_child(Nano.Supervisor, __MODULE__)
          result -> result
        end

      pid ->
        {:ok, pid}
    end
  end

  def report(child, summary, status, opts \\ [])
      when is_binary(summary) and status in [:ok, :error] do
    with {:ok, pid} <- ensure_started(),
         do: GenServer.call(pid, {:report, child, summary, status, opts[:child_id]})
  end

  def result(child) do
    with {:ok, pid} <- ensure_started(), do: GenServer.call(pid, {:result, child})
  end

  @impl true
  def init(opts) do
    dir =
      opts[:dir] ||
        Application.get_env(
          :nano,
          :delegation_dir,
          Path.join(Application.fetch_env!(:nano, :state_dir), "seedling-delegation")
        )

    path = Path.join(dir, "watches.term")
    records = load(path)
    send(self(), :check)
    {:ok, %{path: path, records: records, monitors: %{}}}
  end

  @impl true
  def handle_call(msg, from, s), do: do_call(msg, from, upgrade(s))

  @impl true
  def handle_info(msg, s), do: do_info(msg, upgrade(s))

  defp upgrade(s),
    do: %{s | records: Map.new(s.records, fn {n, r} -> {n, Map.put_new(r, :outbox, [])} end)}

  defp do_call({:track, name, id, pid, parent, worktree}, _, s) do
    record = %{
      child: name,
      child_id: id,
      parent: parent,
      worktree: worktree,
      done: false,
      halt: nil,
      result: nil,
      last_pid: pid,
      outbox: []
    }

    Nano.Log.subscribe(id)

    monitors =
      Enum.reduce(s.monitors, %{}, fn {ref, watched}, acc ->
        if watched == name do
          Process.demonitor(ref, [:flush])
          acc
        else
          Map.put(acc, ref, watched)
        end
      end)

    s = %{s | monitors: monitors}

    s = %{
      s
      | records: Map.put(s.records, name, record),
        monitors: Map.put(s.monitors, Process.monitor(pid), name)
    }

    {:reply, persist(s), s}
  end

  defp do_call({:report, name, summary, status}, from, s),
    do: do_call({:report, name, summary, status, nil}, from, s)

  defp do_call({:report, name, summary, status, expected_id}, _, s) do
    case s.records[name] do
      nil ->
        {:reply, {:error, :unknown_child}, s}

      %{child_id: id} when expected_id != nil and expected_id != id ->
        {:reply, {:error, :replaced_child}, s}

      %{done: true} ->
        {:reply, {:error, :already_reported}, s}

      record ->
        summary =
          if byte_size(summary) > 8000,
            do: String.slice(summary, 0, 1900) <> "\n[report capped; put detail in a file]",
            else: summary

        event = event(record, status, summary)
        record = %{record | done: true, result: event, outbox: record.outbox ++ [event]}
        next = %{s | records: Map.put(s.records, name, record)}

        case persist(next) do
          :ok -> {:reply, :ok, flush(next, name)}
          error -> {:reply, error, s}
        end
    end
  end

  defp do_call({:result, name}, _, s),
    do: {:reply, s.records[name] && s.records[name].result, s}

  defp do_info({:nano_log, %{agent: name}}, s), do: {:noreply, check_child(s, name)}

  defp do_info({:DOWN, ref, :process, pid, reason}, s) do
    {name, monitors} = Map.pop(s.monitors, ref)
    s = %{s | monitors: monitors}

    s =
      case s.records[name] do
        %{done: false} ->
          queue(
            s,
            name,
            :exited,
            "Child process #{inspect(pid)} exited: #{inspect(reason)}. The harness may restart it; address by name."
          )

        _ ->
          s
      end

    {:noreply, s}
  end

  defp do_info(:check, s) do
    s = Enum.reduce(Map.keys(s.records), s, &check_child(&2, &1))
    Process.send_after(self(), :check, 1000)
    {:noreply, s}
  end

  defp do_info(_, s), do: {:noreply, s}

  defp check_child(s, name) do
    s = flush(s, name)

    with %{done: false} = record <- s.records[name],
         %{id: id} = info <- NanoAgent.info(name) do
      if id != record.child_id do
        s =
          queue(
            s,
            name,
            :error,
            "Child name was replaced by another agent id #{id}; original job is no longer running."
          )

        record = %{s.records[name] | done: true}
        s = %{s | records: Map.put(s.records, name, record)}
        persist(s)
        s
      else
        pid = info.pid

        s =
          if is_nil(pid) and is_pid(record.last_pid),
            do:
              queue(
                s,
                name,
                :exited,
                "Child has no live process; its exit occurred while the delegation watcher was unavailable."
              ),
            else: s

        # A code-side timer is the correctness path, including after PubSub restart.
        s =
          if is_pid(pid) and not Enum.any?(s.monitors, fn {_, n} -> n == name end) do
            Nano.Log.subscribe(id)

            s =
              if record.last_pid != pid,
                do: queue(s, name, :restarted, "Child restarted; new pid #{inspect(pid)}"),
                else: s

            %{s | monitors: Map.put(s.monitors, Process.monitor(pid), name)}
          else
            s
          end

        halt = info.halted

        s =
          if halt && halt != record.halt,
            do: queue(s, name, :halted, "Child halted: #{halt}; budget #{inspect(info.budget)}"),
            else: s

        updated = %{s.records[name] | halt: halt, last_pid: pid}
        changed = updated != s.records[name]
        s = %{s | records: Map.put(s.records, name, updated)}
        if changed, do: persist(s)
        s
      end
    else
      _ -> s
    end
  end

  defp queue(s, name, status, summary) do
    r = s.records[name]
    event = event(r, status, summary)
    r = %{r | outbox: r.outbox ++ [event], result: event}
    s = %{s | records: Map.put(s.records, name, r)}

    case persist(s) do
      :ok -> flush(s, name)
      _ -> s
    end
  end

  defp event(r, status, summary),
    do: %{
      type: :delegation,
      child: r.child,
      child_id: r.child_id,
      status: status,
      summary: summary,
      sender_name: r.child,
      sender_pid: NanoAgent.whereis(r.child),
      report_id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    }

  defp flush(s, name) do
    case s.records[name] do
      %{outbox: [_ | _]} = r ->
        pid = if is_pid(r.parent), do: r.parent, else: NanoAgent.whereis(r.parent)

        if is_pid(pid) and Process.alive?(pid) do
          Enum.each(r.outbox, &send(pid, &1))
          s = %{s | records: Map.put(s.records, name, %{r | outbox: []})}
          persist(s)
          s
        else
          s
        end

      _ ->
        s
    end
  end

  defp persist(s), do: Nano.StateStore.write_file("delegation", s.path, s.records)

  defp load(path) do
    case File.read(path) do
      {:ok, bin} ->
        :erlang.binary_to_term(bin) |> Map.new(fn {n, r} -> {n, Map.put_new(r, :outbox, [])} end)

      _ ->
        %{}
    end
  rescue
    e ->
      Logger.error("Delegation watches unreadable at #{path}: #{Exception.message(e)}")
      %{}
  end
end

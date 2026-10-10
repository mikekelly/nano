defmodule Delegation.Monitor do
  @moduledoc """
  Durable delegation registry and outbox. Supervised independently of agents. Polling saved
  info detects halts even while a child is busy; process monitors detect death. Each new pid
  is reattached by stable name. Records persist under state_dir/delegation, including pending
  events and deduplication state. Acknowledgements persist before returning. No pid is stored
  as a reply address. On boot missing children are reported once as :death, then reattached.
  Test instances accept isolated `dir`, `name`, and an adapter implementing info/1,
  whereis/1 and notify/2; production uses NanoAgent. Events retry every sixty seconds by default until
  acked; consumers should deduplicate event_id. `retry_interval_ms:` (minimum 1,000 ms)
  overrides the default application env `:delegation_retry_interval_ms` (60,000). A changed
  parent pid retries immediately. Quiet ticks do not rewrite the durable registry. This is not an exactly-once protocol.
  """
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  def reserve(child, parent, server \\ __MODULE__),
    do: GenServer.call(server, {:reserve, child, parent})

  def activate(child, server \\ __MODULE__), do: GenServer.call(server, {:active, child})
  def cancel(child, server \\ __MODULE__), do: GenServer.call(server, {:cancel, child})

  def emit(child, type, data, server \\ __MODULE__),
    do: GenServer.call(server, {:emit, child, type, data})

  def ack(id, server \\ __MODULE__), do: GenServer.call(server, {:ack, id})
  def events(child, server \\ __MODULE__), do: GenServer.call(server, {:events, child})
  @impl true
  def init(opts) do
    dir = opts[:dir] || Path.join(Application.fetch_env!(:nano, :state_dir), "delegation")
    File.mkdir_p!(dir)
    path = Path.join(dir, "registry.term")

    records =
      case File.read(path) do
        {:ok, bytes} -> :erlang.binary_to_term(bytes)
        {:error, :enoent} -> %{}
      end

    retry_interval_ms =
      opts[:retry_interval_ms] ||
        Application.get_env(:nano, :delegation_retry_interval_ms, 60_000)

    true = is_integer(retry_interval_ms) and retry_interval_ms >= 1_000
    send(self(), :tick)

    {:ok,
     %{
       path: path,
       records: records,
       refs: %{},
       adapter: opts[:adapter] || NanoAgent,
       retry_interval_ms: retry_interval_ms
     }}
  end

  @impl true
  def handle_call({:reserve, child, parent}, _, s) do
    if Map.has_key?(s.records, child) do
      {:reply, {:error, "delegation name already registered"}, s}
    else
      record = %{parent: parent, active: false, seen_pid: nil, halt: nil, dead: false, events: []}
      commit(s, Map.put(s.records, child, record))
    end
  end

  def handle_call({:active, child}, _, s), do: update(s, child, &%{&1 | active: true})
  def handle_call({:cancel, child}, _, s), do: commit(s, Map.delete(s.records, child))

  def handle_call({:emit, child, type, data}, _, s) do
    cond do
      :erlang.external_size(data) > 16_384 ->
        {:reply, {:error, "result exceeds 16 KiB; save details to a file and report its path"}, s}

      not Map.has_key?(s.records, child) ->
        {:reply, {:error, :unknown_child}, s}

      true ->
        update(s, child, &add_event(&1, child, type, data))
    end
  end

  def handle_call({:ack, id}, _, s) do
    records =
      Map.new(s.records, fn {name, r} ->
        {name, %{r | events: Enum.reject(r.events, &(&1.event_id == id))}}
      end)

    commit(s, records)
  end

  def handle_call({:events, child}, _, s) do
    {:reply,
     case s.records[child] do
       nil -> []
       r -> r.events
     end, s}
  end

  defp update(s, child, fun) do
    case s.records[child] do
      nil -> {:reply, {:error, :unknown_child}, s}
      r -> commit(s, Map.put(s.records, child, fun.(r)))
    end
  end

  defp commit(s, records) do
    case persist(s.path, records) do
      :ok ->
        send(self(), :deliver)
        {:reply, :ok, %{s | records: records}}

      {:error, why} ->
        {:reply, {:error, {:persistence_failed, why}}, s}
    end
  end

  defp persist(path, records) do
    with :ok <- File.write(path <> ".tmp", :erlang.term_to_binary(records)),
         :ok <- File.rename(path <> ".tmp", path),
         do: :ok
  end

  defp add_event(r, child, type, data) do
    event =
      Map.merge(data, %{
        delegation: type,
        from: child,
        child: child,
        parent: r.parent,
        event_id: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      })

    %{r | events: r.events ++ [event]}
  end

  @impl true
  def handle_info(:tick, s) do
    before_records = s.records

    s =
      Enum.reduce(s.records, s, fn {child, r}, s ->
        if r.active or s.adapter.whereis(child) != nil do
          pid = s.adapter.whereis(child)
          info = s.adapter.info(child)

          r =
            cond do
              pid == nil and not r.dead ->
                %{add_event(r, child, :death, %{reason: :not_running}) | dead: true}

              pid != nil and r.seen_pid != nil and pid != r.seen_pid ->
                %{add_event(r, child, :restarted, %{}) | dead: false, seen_pid: pid}

              pid != nil ->
                %{r | dead: false, seen_pid: pid}

              true ->
                r
            end

          halt = if info, do: info.halted

          r =
            if halt != nil and halt != r.halt,
              do: add_event(r, child, :halted, %{reason: halt}),
              else: r

          r = %{r | halt: halt, active: true}

          refs =
            if is_pid(pid) and not Enum.any?(s.refs, fn {_, {_, p}} -> p == pid end),
              do: Map.put(s.refs, Process.monitor(pid), {child, pid}),
              else: s.refs

          %{s | records: Map.put(s.records, child, r), refs: refs}
        else
          s
        end
      end)

    if s.records != before_records, do: :ok = persist(s.path, s.records)
    send(self(), :deliver)
    Process.send_after(self(), :tick, 1_000)
    {:noreply, s}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, s) do
    case Map.pop(s.refs, ref) do
      {nil, _} ->
        {:noreply, s}

      {{child, _}, refs} ->
        r = s.records[child]

        records =
          if r,
            do:
              Map.put(s.records, child, %{
                add_event(r, child, :death, %{
                  reason: inspect(reason, limit: 10, printable_limit: 500)
                })
                | dead: true
              }),
            else: s.records

        :ok = persist(s.path, records)
        send(self(), :deliver)
        {:noreply, %{s | refs: refs, records: records}}
    end
  end

  def handle_info(:deliver, s) do
    now = System.monotonic_time(:millisecond)
    last = Map.get(s, :last_delivery, %{})

    last =
      Enum.reduce(s.records, last, fn {_, r}, last ->
        if parent_pid = s.adapter.whereis(r.parent) do
          Enum.reduce(r.events, last, fn event, last ->
            previous = Map.get(last, event.event_id)

            if previous == nil or is_integer(previous) or elem(previous, 0) != parent_pid or
                 now - elem(previous, 1) >=
                   Map.get(
                     s,
                     :retry_interval_ms,
                     Application.get_env(:nano, :delegation_retry_interval_ms, 60_000)
                   ) do
              s.adapter.notify(r.parent, event)
              Map.put(last, event.event_id, {parent_pid, now})
            else
              last
            end
          end)
        else
          last
        end
      end)

    ids = for {_, r} <- s.records, e <- r.events, do: e.event_id
    {:noreply, Map.put(s, :last_delivery, Map.take(last, ids))}
  end

  def handle_info(_, s), do: {:noreply, s}
end

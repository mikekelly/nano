defmodule Seedling.Delegation.Watch do
  @moduledoc false
  use GenServer
  alias Seedling.Delegation, as: D
  alias Seedling.Files

  def prepare(child, parent, opts, workspace, prompt, pre) do
    id = child <> "-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    dir = opts[:state_dir] || "/data/seedling/delegation"
    interval = opts[:poll_ms] || 500

    if is_binary(dir) and is_integer(interval) and interval >= 10 do
      path = Path.join(Path.expand(dir), id <> ".term")

      record = %{
        id: id,
        child: child,
        parent: parent,
        state_path: path,
        workspace: workspace,
        prompt_bytes: prompt.bytes,
        approx_prompt_tokens: prompt.approx_tokens,
        prereads: Enum.map(pre, &Map.delete(&1, :text)),
        poll_ms: interval,
        seq: 0,
        pending: [],
        completed: false,
        halted: nil,
        seen_child: false
      }

      with {:ok, _} <- save(record),
           do:
             {:ok,
              Map.take(record, [
                :id,
                :child,
                :parent,
                :state_path,
                :workspace,
                :prompt_bytes,
                :approx_prompt_tokens,
                :prereads
              ])}
    else
      D.error(:invalid_journal, "Give a state_dir path and poll_ms >= 10 milliseconds.")
    end
  end

  def child_spec(path),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [path]}, restart: :transient}

  def start_link(path) do
    with {:ok, record} <- read(path),
         do: GenServer.start_link(__MODULE__, path, name: address(record.child))
  end

  def attach(%{state_path: path}) do
    with {:ok, supervisor} <- Seedling.Delegation.Supervisor.ensure_started() do
      case DynamicSupervisor.start_child(supervisor, {__MODULE__, path}) do
        {:ok, _} ->
          :ok

        {:error, {:already_started, _}} ->
          D.error(:watch_in_use, "A watcher already owns this child; choose a fresh name.")

        {:error, reason} ->
          D.error(:watch_failed, "Cannot start watcher: #{inspect(reason)}.")
      end
    end
  end

  def report(child, summary) do
    if byte_size(summary) > 1_000_000 do
      D.error(:summary_too_large, "Summary exceeds 1 MB; report findings, not a transcript.")
    else
      call(child, {:report, summary})
    end
  end

  defp call(child, message) do
    try do
      GenServer.call(address(child), message)
    catch
      :exit, _ ->
        D.error(:watch_absent, "No live watcher for #{child}; call resume(state_dir) and retry.")
    end
  end

  def ack(child, id, seq) when is_binary(id) and is_integer(seq) and seq > 0,
    do: call(child, {:ack, id, seq})

  def ack(_, _, _),
    do: D.error(:invalid_ack, "Give a delegation handle and positive event sequence.")

  def status(path) do
    with {:ok, record} <- read(path) do
      pending =
        record.pending
        |> Enum.take(10)
        |> Enum.map(fn item ->
          event =
            case item.event do
              %{summary: text} = event ->
                event |> Map.delete(:summary) |> Map.put(:summary_bytes, byte_size(text))

              event ->
                event
            end

          %{item | event: event}
        end)

      metadata =
        Map.take(record, [
          :id,
          :child,
          :parent,
          :workspace,
          :prereads,
          :completed,
          :halted,
          :seq,
          :prompt_bytes,
          :approx_prompt_tokens,
          :result_path
        ])

      {:ok,
       Map.merge(metadata, %{
         pending: pending,
         pending_count: length(record.pending),
         notice:
           if(length(record.pending) > 10,
             do:
               "Pending metadata limited to 10 events; resume delivery and ack events, or read the journal directly.",
             else: nil
           )
       })}
    end
  end

  def resume(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        results =
          for file <- Enum.sort(files), String.ends_with?(file, ".term") do
            path = Path.join(dir, file)

            case read(path) do
              {:ok, %{completed: true, pending: []}} ->
                {file, :complete}

              {:ok, r} ->
                case :global.whereis_name({__MODULE__, r.child}) do
                  :undefined -> {file, attach(%{state_path: path})}
                  _ -> {file, :already_running}
                end

              error ->
                {file, error}
            end
          end

        {:ok, results}

      {:error, reason} ->
        D.error(:journal_unreadable, "Cannot list #{dir}: #{inspect(reason)}.")
    end
  end

  @impl true
  def init(path) do
    with {:ok, record} <- read(path) do
      send(self(), :poll)
      state = %{record: record, child_pid: nil, child_ref: nil, delivered: %{}}
      {:ok, if(record.completed, do: state, else: observe(state))}
    end
  end

  @impl true
  def handle_call({:report, summary}, _, s) do
    if s.record.completed do
      {:reply,
       D.error(
         :already_reported,
         "A result is already recorded; inspect status rather than reporting twice."
       ), s}
    else
      path = s.record.state_path <> ".result.txt"

      case Files.write(path, summary) do
        {:ok, _} ->
          head = utf8_head(summary, 4_000)
          event = %{kind: :result, summary: head, truncated: head != summary, result_path: path}

          record = s.record |> Map.put(:completed, true) |> Map.put(:result_path, path)

          case queue(%{s | record: record}, event) do
            {:ok, next} -> {:reply, :ok, deliver(next)}
            error -> {:reply, error, s}
          end

        error ->
          {:reply, error, s}
      end
    end
  end

  def handle_call({:ack, id, seq}, _, %{record: %{id: id}} = s) do
    record = %{s.record | pending: Enum.reject(s.record.pending, &(&1.seq == seq))}

    case save(record) do
      {:ok, _} ->
        next = %{s | record: record, delivered: Map.delete(s.delivered, seq)}

        if record.completed and record.pending == [],
          do: {:stop, :normal, :ok, next},
          else: {:reply, :ok, next}

      error ->
        {:reply, error, s}
    end
  end

  def handle_call({:ack, _, _}, _, s), do: {:reply, :not_this_watch, s}

  @impl true
  def handle_info(:poll, s) do
    next = if s.record.completed, do: s, else: observe(s)
    Process.send_after(self(), :poll, next.record.poll_ms)
    {:noreply, deliver(next)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{child_ref: ref, child_pid: pid} = s) do
    next = %{s | child_ref: nil, child_pid: nil}

    next =
      if s.record.completed,
        do: next,
        else:
          queue_or_fail(next, %{
            kind: :down,
            reason: inspect(reason, limit: 10, printable_limit: 500)
          })

    {:noreply, deliver(next)}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp observe(s) do
    pid = NanoAgent.whereis(s.record.child)
    info = NanoAgent.info(s.record.child)
    epoch = if info, do: {info.id, info.restart_count}

    s =
      if pid != nil and pid != s.child_pid do
        # If the poll beats DOWN in the mailbox, report death before replacing
        # the monitor; flushing the old ref must not lose the parent's notice.
        s =
          if s.child_pid && not Process.alive?(s.child_pid),
            do:
              queue_or_fail(s, %{kind: :down, reason: "process replaced before monitor delivery"}),
            else: s

        if s.child_ref, do: Process.demonitor(s.child_ref, [:flush])
        next = %{s | child_pid: pid, child_ref: Process.monitor(pid)}

        next =
          if s.record.seen_child and Map.get(s.record, :child_epoch) != epoch,
            do:
              queue_or_fail(next, %{kind: :restarted, restart_count: info && info.restart_count}),
            else: next

        record = next.record |> Map.put(:seen_child, true) |> Map.put(:child_epoch, epoch)
        persist_or_fail(%{next | record: record})
      else
        s
      end

    halted = if info, do: info.halted

    if halted != s.record.halted do
      next = %{s | record: %{s.record | halted: halted}}

      if halted,
        do: queue_or_fail(next, %{kind: :halted, reason: halted, budget: info.budget}),
        else: persist_or_fail(next)
    else
      s
    end
  end

  defp queue(s, event) do
    record = s.record
    seq = record.seq + 1
    event = Map.merge(event, %{child: record.child, parent: record.parent})
    record = %{record | seq: seq, pending: record.pending ++ [%{seq: seq, event: event}]}

    case save(record) do
      {:ok, _} -> {:ok, %{s | record: record}}
      error -> error
    end
  end

  defp queue_or_fail(s, event) do
    case queue(s, event) do
      {:ok, next} -> next
      error -> exit({:journal_failed, error})
    end
  end

  defp persist_or_fail(s) do
    case save(s.record) do
      {:ok, _} -> s
      error -> exit({:journal_failed, error})
    end
  end

  defp deliver(s) do
    case NanoAgent.whereis(s.record.parent) do
      nil ->
        s

      pid ->
        delivered =
          Enum.reduce(s.record.pending, s.delivered, fn item, acc ->
            if acc[item.seq] == pid do
              acc
            else
              send(pid, {:seedling_delegation, s.record.id, item.seq, item.event})
              Map.put(acc, item.seq, pid)
            end
          end)

        %{s | delivered: delivered}
    end
  end

  defp save(record), do: Files.write(record.state_path, :erlang.term_to_binary(record))

  defp read(path) do
    with {:ok, bytes} <- File.read(path) do
      try do
        case :erlang.binary_to_term(bytes, [:safe]) do
          %{id: _, child: _, parent: _, state_path: ^path, pending: _} = r -> {:ok, r}
          _ -> D.error(:journal_invalid, "Invalid delegation journal #{path}.")
        end
      rescue
        _ -> D.error(:journal_invalid, "Corrupt delegation journal #{path}.")
      end
    else
      {:error, reason} -> D.error(:journal_unreadable, "Cannot read #{path}: #{inspect(reason)}.")
    end
  end

  defp utf8_head(text, cap) when byte_size(text) <= cap, do: text

  defp utf8_head(text, cap) do
    head = binary_part(text, 0, cap)
    if String.valid?(head), do: head, else: utf8_head(text, cap - 1)
  end

  defp address(child), do: {:global, {__MODULE__, child}}
end

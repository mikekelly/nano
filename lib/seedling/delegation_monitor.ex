defmodule Seedling.Delegation.Monitor do
  @moduledoc false
  use GenServer, restart: :transient
  alias Seedling.Delegation.Supervisor, as: Store

  def start_link(arg) do
    name = if is_map(arg), do: arg.name, else: elem(arg, 0)
    GenServer.start_link(__MODULE__, arg, name: {:global, {__MODULE__, name}})
  end

  def init({name, parent, interval}) do
    record =
      with {:ok, raw} <- File.read(Store.file(name)) do
        try do
          :erlang.binary_to_term(raw, [:safe])
        rescue
          _ -> nil
        end
      else
        _ -> nil
      end

    init(record || %{name: name, parent: parent, interval: interval, pending: [], done: false})
  end

  def init(record) do
    record =
      case File.read(Store.file(record.name)) do
        {:ok, raw} ->
          try do
            :erlang.binary_to_term(raw, [:safe])
          rescue
            _ -> record
          end

        _ ->
          record
      end

    pid = NanoAgent.whereis(record.name)
    ref = if pid, do: Process.monitor(pid)
    s = Map.merge(record, %{pid: pid, ref: ref, halt: nil})

    case Store.save(s) do
      :ok ->
        Process.send_after(self(), :poll, s.interval)
        {:ok, s}

      error ->
        {:stop, {:persist_failed, error}}
    end
  end

  def handle_call({:report, result}, _from, s) do
    if :erlang.external_size(result) > 16000 do
      {:reply, {:error, :result_too_large_keep_under_16000_bytes}, s}
    else
      s = queue(%{s | done: true}, :result, %{result: result, info: usage(s.name)}) |> flush()

      if s.pending == [] do
        File.rm(Store.file(s.name))
        {:stop, :normal, :ok, s}
      else
        {:reply, :ok, s}
      end
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{ref: ref} = s) do
    s = queue(s, :down, %{pid: pid, reason: reason})
    {:noreply, %{s | pid: nil, ref: nil}}
  end

  def handle_info(:poll, s) do
    pid = NanoAgent.whereis(s.name)

    s =
      if pid && pid != s.pid && not s.done do
        if s.ref, do: Process.demonitor(s.ref, [:flush])
        queue(%{s | pid: pid, ref: Process.monitor(pid)}, :restarted, %{pid: pid})
      else
        s
      end

    info = NanoAgent.info(s.name)
    halt = if info, do: info.halted, else: :missing

    s =
      if halt && halt != s.halt && not s.done,
        do: queue(s, :halted, %{reason: halt, info: usage(s.name)}),
        else: s

    s = flush(%{s | halt: halt})

    if s.done && s.pending == [] do
      File.rm(Store.file(s.name))
      {:stop, :normal, s}
    else
      Process.send_after(self(), :poll, s.interval)
      {:noreply, s}
    end
  end

  defp queue(s, kind, payload) do
    s = %{s | pending: Enum.take(s.pending ++ [{:delegation, s.name, kind, payload}], -100)}
    :ok = Store.save(s)
    s
  end

  defp flush(s) do
    pid = if is_pid(s.parent), do: s.parent, else: NanoAgent.whereis(s.parent)

    if pid && Process.alive?(pid) do
      Enum.each(s.pending, &send(pid, &1))
      s = %{s | pending: []}
      :ok = Store.save(s)
      s
    else
      s
    end
  end

  defp usage(name) do
    case NanoAgent.info(name) do
      nil -> nil
      info -> Map.take(info, [:budget, :cost, :model, :reasoning, :halted])
    end
  end
end

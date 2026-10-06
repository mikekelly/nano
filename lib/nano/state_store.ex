defmodule Nano.StateStore do
  @moduledoc """
  Long-lived owner of the public ETS table that holds agent state, so an agent's history
  outlives its process and can be read without calling the agent (which may be busy or
  suspended).

  Rows: `{name, state_map}` per agent, `{{:exit, name}, pid, reason}` for the last watched
  exit, `{{:seq, id}, n}` log sequence counters, and `{{:node_tokens, minute}, n}` buckets
  for the node-wide hourly token cap. Every function but `watch/2` is a direct ETS access.
  """
  use GenServer

  @table __MODULE__

  @doc "Started by Nano.Application."
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The stored map for an agent name, or nil."
  def get(name) do
    case :ets.lookup(@table, name) do
      [{_, map}] -> map
      [] -> nil
    end
  end

  @doc "Stores the map for an agent name."
  def put(name, map) do
    :ets.insert(@table, {name, map})
    :ok
  end

  @doc "Deletes an agent's entry, its recorded exit and its log sequence counter."
  def delete(name) do
    with %{id: id} <- get(name), do: :ets.delete(@table, {:seq, id})
    :ets.delete(@table, {:exit, name})
    :ets.delete(@table, name)
    :ok
  end

  @doc "All stored agent maps."
  def all, do: :ets.select(@table, [{{:"$1", :"$2"}, [{:is_binary, :"$1"}], [:"$2"]}])

  @doc """
  Monitors pid and records its exit reason for the agent's next init (see `exit_reason/2`).
  If an earlier pid for the same name is still watched because its `:DOWN` has not been
  handled yet, waits for that `:DOWN` first, so a restarted agent that calls `watch/2` in
  init always finds its predecessor's exit reason.
  """
  def watch(name, pid), do: GenServer.call(__MODULE__, {:watch, name, pid})

  @doc "The exit reason recorded by `watch/2` for pid under name, or nil."
  def exit_reason(name, pid) do
    case :ets.lookup(@table, {:exit, name}) do
      [{_, ^pid, reason}] -> reason
      _ -> nil
    end
  end

  @doc """
  Next per-agent log sequence number. A missing counter (a new agent, or this store was
  restarted) starts from the last seq in the agent's log file, so seq never goes back.
  """
  def next_seq(id) do
    key = {:seq, id}

    unless :ets.member(@table, key) do
      last = id |> Nano.Log.read() |> List.last()
      :ets.insert_new(@table, {key, if(last, do: last["seq"], else: 0)})
    end

    :ets.update_counter(@table, key, 1)
  end

  @doc "Adds tokens to the node-wide rolling-hour counter."
  def add_node_tokens(n) do
    minute = minute()

    :ets.select_delete(@table, [
      {{{:node_tokens, :"$1"}, :_}, [{:"=<", :"$1", minute - 60}], [true]}
    ])

    :ets.update_counter(@table, {:node_tokens, minute}, n, {{:node_tokens, minute}, 0})
    :ok
  end

  @doc "Tokens used on the node in the last 60 minutes."
  def node_tokens_last_hour do
    since = minute() - 60

    @table
    |> :ets.select([{{{:node_tokens, :"$1"}, :"$2"}, [{:>, :"$1", since}], [:"$2"]}])
    |> Enum.sum()
  end

  defp minute, do: div(System.system_time(:second), 60)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    # name => {monitor_ref, pid}
    {:ok, %{}}
  end

  @impl true
  def handle_call({:watch, name, pid}, _from, watched) do
    with %{^name => {ref, old}} <- watched do
      receive do
        {:DOWN, ^ref, :process, _, reason} -> record(name, old, reason)
      after
        5_000 -> Process.demonitor(ref, [:flush])
      end
    end

    {:reply, :ok, Map.put(watched, name, {Process.monitor(pid), pid})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, watched) do
    case Enum.find(watched, fn {_, {r, _}} -> r == ref end) do
      {name, _} ->
        record(name, pid, reason)
        {:noreply, Map.delete(watched, name)}

      nil ->
        {:noreply, watched}
    end
  end

  # Only for the process the entry belongs to: a stand-in that came up after a failed restore
  # (halted :start_failed) keeps the entry as it was, so the exit it stands in for is kept.
  defp record(name, pid, reason) do
    if match?(%{pid: ^pid}, get(name)), do: :ets.insert(@table, {{:exit, name}, pid, reason})
  end
end

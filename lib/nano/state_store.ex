defmodule Nano.StateStore do
  @moduledoc """
  Long-lived owner of the public ETS table that holds agent state, so an agent's history
  outlives its process and can be read without calling the agent (which may be busy or
  suspended).

  Rows: `{name, state_map}` per agent, `{{:exit, name}, pid, reason}` for the last watched
  exit, `{{:seq, id}, n}` log sequence counters, and `{{:node_tokens, minute}, n}` buckets
  for the node-wide hourly token cap. Every function but `watch/2` is a direct ETS access.

  The table dies with this process. When it is restarted (someone killed it), it asks every
  live agent to save its entry again; exit reasons, log seq counters (re-seeded from the log
  files) and the hourly token counter start over.

  Each agent's entry is also written to `<state_dir>/<name>.term` whenever it changes, so it
  survives node death: at boot, `load/0` reads the files back and the agents are revived.

  An agent's eval bindings are kept apart from its entry (row `{{:bindings, name}, kept,
  dropped}`, file `<name>.bindings`) and saved only when they change, so a large variable costs
  nothing at each save, and reads of the entry (`get/1`, `all/0`) never copy them.
  """
  use GenServer
  require Logger

  @table __MODULE__

  @doc "Started by Nano.Application."
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The stored map for an agent name, or nil (also while the table is being recreated)."
  def get(name) do
    case :ets.lookup(@table, name) do
      [{_, map}] -> map
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Stores the map for an agent name and, if it changed, writes it to the agent's state file.
  A failed write is logged, not raised: the table still holds the entry. A no-op in the moment
  while the table is being recreated.
  """
  def put(name, map) do
    # Unchanged entries are not rewritten, unless the file is missing (e.g. an agent started
    # before this module wrote files).
    changed? = :ets.lookup(@table, name) != [{name, map}]
    :ets.insert(@table, {name, map})
    if changed? or not File.exists?(file(name)), do: write(name, file(name), map)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Saves an agent's eval bindings if they changed. If together they would take more than
  the `max_bindings_bytes` setting (default 16 MB), the largest variables are left out of what is saved
  (they stay bound in the running process); a warning is logged when a variable is first left
  out. Returns the names left out.
  """
  def put_bindings(name, bindings) do
    max = Nano.Settings.get(:max_bindings_bytes)

    {kept, dropped, _} =
      bindings
      |> Enum.map(fn {k, v} -> {k, v, :erlang.external_size(v)} end)
      |> Enum.sort_by(&elem(&1, 2))
      |> Enum.reduce({[], [], 0}, fn {k, v, size}, {kept, dropped, total} ->
        if total + size <= max,
          do: {[{k, v} | kept], dropped, total + size},
          else: {kept, [{k, size} | dropped], total}
      end)

    {kept, names} = {Enum.sort(kept), dropped |> Enum.map(&elem(&1, 0)) |> Enum.sort()}
    {old_kept, old_names} = bindings(name)

    if names -- old_names != [] do
      sizes = Enum.map_join(Enum.sort(dropped), ", ", fn {k, size} -> "#{k} (#{size} bytes)" end)

      Logger.warning(
        "#{name}: not saving eval variables #{sizes}: together over #{max} bytes; " <>
          "they stay bound in the running process but will not survive a restart"
      )
    end

    if {kept, names} != {old_kept, old_names} do
      :ets.insert(@table, {{:bindings, name}, kept, names})
      write(name, bindings_file(name), {kept, names})
    end

    names
  rescue
    ArgumentError -> []
  end

  @doc "An agent's saved bindings and the names left out of them: `{bindings, names}`."
  def bindings(name) do
    case :ets.lookup(@table, {:bindings, name}) do
      [{_, kept, names}] -> {kept, names}
      [] -> {[], []}
    end
  rescue
    ArgumentError -> {[], []}
  end

  @doc "Deletes an agent's entry, its state file, its recorded exit and its log sequence counter."
  def delete(name) do
    with %{id: id} <- get(name), do: :ets.delete(@table, {:seq, id})
    :ets.delete(@table, {:exit, name})
    :ets.delete(@table, {:bindings, name})
    :ets.delete(@table, name)
    File.rm(file(name))
    File.rm(bindings_file(name))
    :ok
  end

  @doc """
  Loads every agent state file into the table, for agents not already in it, recording each
  one's exit as `:node_restart` (the process that saved it belonged to a node that has since
  stopped). Unreadable files are skipped and logged. Called once, at boot.
  """
  def load do
    dir = Application.fetch_env!(:nano, :state_dir)

    for file <- with({:ok, files} <- File.ls(dir), do: files, else: (_ -> [])),
        Path.extname(file) in [".term", ".bindings"] do
      path = Path.join(dir, file)

      try do
        case path |> File.read!() |> :erlang.binary_to_term() do
          %{name: name, pid: pid} = entry ->
            if :ets.insert_new(@table, {name, entry}),
              do: :ets.insert(@table, {{:exit, name}, pid, :node_restart})

          {kept, names} when is_list(kept) and is_list(names) ->
            :ets.insert_new(@table, {{:bindings, Path.rootname(file)}, kept, names})
        end
      rescue
        e -> Logger.error("Nano.StateStore: skipped #{path}: #{Exception.message(e)}")
      end
    end

    :ok
  end

  defp file(name), do: Path.join(Application.fetch_env!(:nano, :state_dir), name <> ".term")

  defp bindings_file(name),
    do: Path.join(Application.fetch_env!(:nano, :state_dir), name <> ".bindings")

  # Atomically: a node that dies mid-write leaves the previous file, not half of this one.
  defp write(name, path, term) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, :erlang.term_to_binary(term)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.error("#{name}: could not save state to #{path}: #{inspect(reason)}")
    end
  end

  @doc "All stored agent maps."
  def all do
    :ets.select(@table, [{{:"$1", :"$2"}, [{:is_binary, :"$1"}], [:"$2"]}])
  rescue
    ArgumentError -> []
  end

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
    {:ok, %{}, {:continue, :resave}}
  end

  @impl true
  def handle_continue(:resave, watched) do
    for {{:agent, _}, pid} <- Nano.Names.all(), do: GenServer.cast(pid, :resave)
    {:noreply, watched}
  catch
    _, _ -> {:noreply, watched}
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

  def handle_call(msg, _from, watched) do
    Logger.info("Nano.StateStore ignored call #{inspect(msg, limit: 10, printable_limit: 200)}")
    {:reply, {:error, :unknown_call}, watched}
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

  # Anyone may send this process anything (the dashboard can); a crash would lose the table.
  def handle_info(msg, watched), do: ignore(msg, watched)

  @impl true
  def handle_cast(msg, watched), do: ignore(msg, watched)

  defp ignore(msg, watched) do
    Logger.info("Nano.StateStore ignored #{inspect(msg, limit: 10, printable_limit: 200)}")
    {:noreply, watched}
  end

  # Only for the process the entry belongs to: a stand-in that came up after a failed restore
  # (halted :start_failed) keeps the entry as it was, so the exit it stands in for is kept.
  defp record(name, pid, reason) do
    if match?(%{pid: ^pid}, get(name)), do: :ets.insert(@table, {{:exit, name}, pid, reason})
  end
end

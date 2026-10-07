defmodule Nano.Names do
  @moduledoc """
  The names agents and users are registered under (`{:agent, name}`, `{:user, name}`), used
  as `{:via, Nano.Names, key}`.

  Not `Registry`: a `Registry` links to every process it names, so a stray message that
  crashes it takes every named process down too. This process monitors them instead and
  ignores what it does not expect, so nothing sent to it reaches an agent.

  Names are rows `{key, pid}` in a public ETS table. Registering inserts the row from the
  registering process and asks this process to monitor it; lookups read the table and never
  call this process. On a monitored process's exit its rows are removed. The table belongs to
  the application's start process (`create_table/0`), so it outlives this process: restarted,
  it monitors every pid in the table again, and the rows of any that died meanwhile go.
  """
  use GenServer

  @table __MODULE__

  @doc "Creates the table; called once by `Nano.Application.start/2`, whose process owns it."
  def create_table, do: :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Registers `pid` under `key`: `:yes`, or `:no` if a live process already has it."
  def register_name(key, pid) when is_pid(pid) do
    if :ets.insert_new(@table, {key, pid}) do
      # Lost if this process is down, but then its init finds the row.
      GenServer.cast(__MODULE__, {:monitor, pid})
      :yes
    else
      case :ets.lookup(@table, key) do
        [{_, old}] ->
          if alive?(old) do
            :no
          else
            # A dead holder whose exit is not processed yet (its supervisor is restarting it).
            :ets.select_delete(@table, [{{key, old}, [], [true]}])
            register_name(key, pid)
          end

        [] ->
          register_name(key, pid)
      end
    end
  end

  @doc "Removes `key`."
  def unregister_name(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc "The live pid registered under `key`, or `:undefined`."
  def whereis_name(key) do
    case :ets.lookup(@table, key) do
      [{_, pid}] -> if alive?(pid), do: pid, else: :undefined
      [] -> :undefined
    end
  end

  @doc false
  def send(key, msg) do
    case whereis_name(key) do
      :undefined -> :erlang.error(:badarg, [key, msg])
      pid -> Kernel.send(pid, msg)
    end
  end

  @doc "Every `{key, pid}` whose process is alive."
  def all, do: for({_, pid} = row <- :ets.tab2list(@table), alive?(pid), do: row)

  defp alive?(pid), do: node(pid) == node() and Process.alive?(pid)

  @impl true
  def init(nil) do
    {:ok, Enum.reduce(:ets.tab2list(@table), %{}, fn {_, pid}, m -> monitor(m, pid) end)}
  end

  @impl true
  def handle_cast({:monitor, pid}, monitored) when is_pid(pid),
    do: {:noreply, monitor(monitored, pid)}

  def handle_cast(_msg, monitored), do: {:noreply, monitored}

  @impl true
  def handle_call(_msg, _from, monitored), do: {:reply, {:error, :unknown_call}, monitored}

  # Only a DOWN for a monitor of ours: a forged one must not remove a live process's name.
  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, monitored)
      when :erlang.map_get(pid, monitored) == ref do
    :ets.match_delete(@table, {:_, pid})
    {:noreply, Map.delete(monitored, pid)}
  end

  def handle_info(_msg, monitored), do: {:noreply, monitored}

  # pid => monitor ref; monitoring a pid that is already dead sends DOWN at once.
  defp monitor(monitored, pid) when is_map_key(monitored, pid), do: monitored
  defp monitor(monitored, pid), do: Map.put(monitored, pid, Process.monitor(pid))
end

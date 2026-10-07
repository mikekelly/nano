defmodule Nano.Delegation.Watcher do
  @moduledoc """
  Watches sub-agents on behalf of the parent that started them: when a sub-agent halts
  (budget, context, node budget or brake), exits, or ends a turn without reporting, the
  parent gets a `{:report, …}` for it anyway — running out of budget must be reported to the
  parent, not just logged in the child's own log.

  Started under `Nano.Supervisor`. It polls the agents every 5 s (cheap: it reads
  `NanoAgent.info/1` from ETS) and keeps one entry per sub-agent in `state`. An entry is
  removed once a report for that sub-agent was seen going past, or the child is gone and the
  parent was told.

  A child is not disturbed by this: it only reads. A child that already reported
  (`Nano.Delegation.report_to/3`) is not reported again.
  """

  use GenServer

  @every 5_000
  @statuses %{budget: :budget, context: :error, node_budget: :error, restart_brake: :error}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Registers a child to watch; usually called from `Nano.Delegation.subagent/2`."
  def watch(child, parent),
    do: GenServer.cast(__MODULE__, {:watch, to_string(child), to_string(parent)})

  @doc "The children this watcher is tracking."
  def watching, do: GenServer.call(__MODULE__, :watching)

  @doc "Marks `child` as having reported; the watcher stops following up on it."
  def reported(child), do: GenServer.cast(__MODULE__, {:reported, to_string(child)})

  @impl true
  def init(nil) do
    Process.send_after(self(), :tick, @every)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:reported, child}, state) do
    case state[child] do
      nil -> {:noreply, state}
      entry -> {:noreply, %{state | child => %{entry | told: true}}}
    end
  end

  def handle_cast({:watch, child, parent}, state) do
    {:noreply,
     Map.put(state, child, %{parent: parent, told: false, last_status: nil, idle_since: nil})}
  end

  @impl true
  def handle_call(:watching, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @every)

    state =
      Enum.reduce(state, %{}, fn {child, entry}, acc ->
        case check(child, entry) do
          {:keep, entry} -> Map.put(acc, child, entry)
          :drop -> acc
        end
      end)

    {:noreply, state}
  end

  defp check(child, %{told: true} = entry) do
    if alive?(child), do: {:keep, entry}, else: :drop
  end

  defp check(child, entry) do
    parent = entry.parent
    info = Nano.Ops.agent(child)
    pid = NanoAgent.whereis(child)

    cond do
      # Gone: the parent still deserves a report.
      pid == nil and info == nil ->
        report(
          parent,
          child,
          :error,
          "the sub-agent is gone (no state; it may have been stopped)"
        )

        :drop

      pid == nil ->
        report(parent, child, :error, "the sub-agent's process exited")
        {:keep, %{entry | told: true}}

      info.halted != nil ->
        report(parent, child, Map.get(@statuses, info.halted, :error), halt_text(child, info))
        {:keep, %{entry | told: true}}

      # Idle for two ticks with no report and no pending work: it stopped without reporting.
      info.status == :idle ->
        idle = entry.idle_since || System.monotonic_time(:millisecond)

        if System.monotonic_time(:millisecond) - idle > 2 * @every do
          report(
            parent,
            child,
            :no_tool_call,
            "the sub-agent went idle without reporting; ask it for a report with Nano.Delegation.report/2"
          )

          {:keep, %{entry | told: true, idle_since: idle}}
        else
          {:keep, %{entry | idle_since: idle}}
        end

      true ->
        {:keep, %{entry | idle_since: nil}}
    end
  end

  defp halt_text(child, info) do
    case info.halted do
      :budget ->
        "#{child} ran out of its own budget: #{info.budget.turns_used}/#{info.budget.max_turns} turns, #{info.budget.tokens_used}/#{info.budget.max_tokens} tokens"

      :context ->
        "#{child} reached its context limit (#{info.budget.context_used} tokens)"

      :node_budget ->
        "#{child} was halted by the node-wide hourly token cap"

      :restart_brake ->
        "#{child} restarted too often and was halted"

      other ->
        "#{child} was halted: #{inspect(other)}"
    end
  end

  defp report(parent, child, status, message) do
    case NanoAgent.whereis(parent) do
      nil -> :ok
      pid -> send(pid, {:report, Nano.Delegation.report_map(child, status, message)})
    end
  end

  defp alive?(child), do: NanoAgent.whereis(child) != nil or Nano.Ops.agent(child) != nil
end

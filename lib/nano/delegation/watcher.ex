defmodule Nano.Delegation.Watcher do
  @moduledoc """
  Watches sub-agents on behalf of the parent that started them, so a parent is never left waiting
  for a report that will not come. This is the failure `RUNS.md` records twice: `reviewer`'s three
  sub-agents all ran out of their 50 turns and never reported, and the parent recovered their work
  only from `git diff`.

  Every 5 s it reads each child's info from ETS (cheap; it never disturbs the child) and sends the
  parent a `{:nano_report, …}` for it when the child:

    * halts — `:budget`, `:context`, `:node_budget` or `:restart_brake`
    * dies or is stopped
    * goes idle for two ticks without ever reporting (a sub-agent that ends a turn with no tool
      call is waiting for instructions, which is not a report)

  The message recovers the child's last assistant text, so what the child found before it ran out
  reaches the parent even though it never sent a report itself. A child that reported normally is
  left alone.
  """

  use GenServer

  @every 5_000
  @halt_status %{budget: :budget, context: :error, node_budget: :error, restart_brake: :error}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Registers `child` for `parent`; called by `Nano.Delegation.subagent/2`."
  def watch(child, parent), do: GenServer.cast(__MODULE__, {:watch, to_string(child), to_string(parent)})

  @doc "Marks `child` as having reported; the watcher stops following up."
  def reported(child), do: GenServer.cast(__MODULE__, {:reported, to_string(child)})

  @doc "The children being tracked."
  def watching, do: GenServer.call(__MODULE__, :watching)

  @impl true
  def init(nil) do
    Process.send_after(self(), :tick, @every)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:watch, child, parent}, state),
    do: {:noreply, Map.put(state, child, %{parent: parent, told: false, idle_since: nil})}

  def handle_cast({:reported, child}, state) do
    case state[child] do
      nil -> {:noreply, state}
      entry -> {:noreply, %{state | child => %{entry | told: true}}}
    end
  end

  @impl true
  def handle_call(:watching, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @every)

    state =
      Enum.reduce(state, %{}, fn {child, entry}, acc ->
        case check(child, entry) do
          {:keep, e} -> Map.put(acc, child, e)
          :drop -> acc
        end
      end)

    {:noreply, state}
  end

  defp check(child, %{told: true} = entry),
    do: if(Nano.Ops.agent(child) != nil, do: {:keep, entry}, else: :drop)

  defp check(child, entry) do
    info = Nano.Ops.agent(child)
    now = System.monotonic_time(:millisecond)

    cond do
      info == nil ->
        report(entry.parent, child, :error, "the sub-agent is gone (stopped, or never started)")
        :drop

      info.halted != nil ->
        report(entry.parent, child, Map.get(@halt_status, info.halted, :error), halted_text(info))
        {:keep, %{entry | told: true}}

      info.status == :idle ->
        idle = entry.idle_since || now

        if now - idle > 2 * @every do
          report(
            entry.parent,
            child,
            :no_report,
            "the sub-agent went idle without reporting. Ask it with " <>
              "Nano.Delegation.task(" <> inspect(child) <> ", :report); its last text: " <> last_text(child)
          )

          {:keep, %{entry | told: true, idle_since: idle}}
        else
          {:keep, %{entry | idle_since: idle}}
        end

      true ->
        {:keep, %{entry | idle_since: nil}}
    end
  end

  defp halted_text(info) do
    b = info.budget

    "#{info.name} was halted (#{info.halted}) after #{b.turns_used} turns and " <>
      "#{b.tokens_used} tokens, without reporting. Its last text: " <> last_text(info.name)
  end

  # The child's last assistant message, from its own log: what it found before it stopped.
  defp last_text(name) do
    name
    |> Nano.Util.log(last: 40)
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"type" => "model_response", "text" => text} when is_binary(text) and text != "" ->
        String.slice(text, 0, 600)

      _ ->
        nil
    end)
    |> Kernel.||("(none)")
  end

  defp report(parent, child, status, message) do
    case NanoAgent.whereis(parent) do
      nil -> :ok
      pid -> send(pid, {:nano_report, Nano.Delegation.report(child, status, message)})
    end
  end
end

defmodule Seedling.Bots.Queue do
  @moduledoc "Session-ordered delivery outside durable store lock. One queue per session, atomic registration; replay is at least once using message IDs."
  use GenServer

  def enqueue(session, message) do
    key = {:global, {__MODULE__, session.id}}

    pid =
      case GenServer.start(__MODULE__, nil, name: key) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    GenServer.cast(pid, {:deliver, session, message})
    pid
  end

  def init(_), do: {:ok, nil, 60000}

  def handle_cast({:deliver, session, message}, s) do
    data = Seedling.Bots.snapshot()

    for bot <- Map.get(message, :pending, []) do
      Seedling.Bots.Agent.deliver(data.bots[bot], session, message)
      Seedling.Bots.delivered(session.id, message.id, bot)
    end

    {:noreply, s, 60000}
  end

  def handle_info(:timeout, s), do: {:stop, :normal, s}
end

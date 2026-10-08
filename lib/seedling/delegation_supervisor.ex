defmodule Seedling.Delegation.Supervisor do
  @moduledoc false
  use DynamicSupervisor

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case DynamicSupervisor.start_link(__MODULE__, nil, name: __MODULE__) do
          {:ok, pid} ->
            Process.unlink(pid)
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, reason} ->
            Seedling.Delegation.error(
              :supervisor_failed,
              "Cannot start delegation supervisor: #{inspect(reason)}"
            )
        end

      pid ->
        {:ok, pid}
    end
  end

  @impl true
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)
end

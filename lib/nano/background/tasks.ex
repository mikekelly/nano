defmodule Nano.Background.Tasks do
  @moduledoc "DynamicSupervisor for `Nano.Background` tasks; started by `Nano.Application`."
  use DynamicSupervisor

  def start_link(_opts), do: DynamicSupervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil), do: DynamicSupervisor.init(strategy: :one_for_one)
end

defmodule Nano.MCP.Supervisor do
  @moduledoc "Supervises MCP sessions and their durable stable-name subscription intent."
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_),
    do:
      Supervisor.init(
        [
          {DynamicSupervisor, name: Nano.MCP.SessionSupervisor, strategy: :one_for_one},
          Nano.MCP.Manager
        ],
        strategy: :one_for_all
      )
end

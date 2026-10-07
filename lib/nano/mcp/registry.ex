defmodule Nano.MCP.Registry do
  @moduledoc "The unique Registry of connected MCP servers (server id => connection pid)."
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: __MODULE__)
end

defmodule Nano.MCP.Supervisor do
  @moduledoc "DynamicSupervisor for MCP server connections; started by `Nano.Application`."
  use DynamicSupervisor

  def start_link(_opts), do: DynamicSupervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil),
    do: DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 100, max_seconds: 10)
end

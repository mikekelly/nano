defmodule Seedling.MCP.Supervisor do
  @moduledoc """
  Start as `{Seedling.MCP.Supervisor, []}` in the application tree.
  `instance:`, `config_path:`, `state_dir:` and `resolver:` isolate a test instance.
  A manager crash restarts its connections and reloads durable intent.
  """
  use Supervisor

  def start_link(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: name(opts[:instance] || :default))

  def name(instance), do: {:global, {__MODULE__, instance}}
  def connections(instance), do: {:global, {__MODULE__, :connections, instance}}
  @impl true
  def init(opts) do
    instance = opts[:instance] || :default

    Supervisor.init(
      [
        {DynamicSupervisor,
         strategy: :one_for_one, name: connections(instance), max_restarts: 100, max_seconds: 10},
        {Seedling.MCP.Manager, opts}
      ],
      strategy: :one_for_all,
      max_restarts: 100,
      max_seconds: 10
    )
  end
end

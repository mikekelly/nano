defmodule Seedling.MCP.Supervisor do
  @moduledoc """
  Start configured connections under supervision:
  `{:ok, sup} = Seedling.MCP.Supervisor.start_link(config: "config/mcp.json")`
  `Seedling.MCP.Supervisor.connections(sup)` returns server-name => client-pid.
  Add this supervisor to the application's children for automatic boot/recovery.
  Do not start two clients for the same server/state_dir (subscription file is single-writer).
  """
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def init(opts) do
    path = Keyword.get(opts, :config, "config/mcp.json")
    servers = File.read!(path) |> Jason.decode!() |> Map.fetch!("mcpServers")

    children =
      Enum.map(servers, fn {name, server} ->
        client_opts =
          opts
          |> Keyword.drop([:name, :config])
          |> Keyword.merge(server_name: name, server: server)

        Supervisor.child_spec({Seedling.MCP.Client, client_opts}, id: name)
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  def connections(sup),
    do: Supervisor.which_children(sup) |> Map.new(fn {name, pid, _, _} -> {name, pid} end)
end

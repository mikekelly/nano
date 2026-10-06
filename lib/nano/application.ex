defmodule Nano.Application do
  @moduledoc "Starts the node's supervision tree, records the boot set, and starts the dashboard user."
  use Application

  @boot_set {__MODULE__, :boot_set}

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Nano.PubSub},
      {Registry, keys: :unique, name: Nano.Registry},
      Nano.StateStore,
      {Task.Supervisor, name: Nano.EvalSupervisor},
      # Generous limits: the per-agent restart brake is the real limit (PLAN.md decision 11).
      {DynamicSupervisor,
       name: Nano.AgentSupervisor, strategy: :one_for_one, max_restarts: 1000, max_seconds: 60},
      {DynamicSupervisor, name: Nano.UserSupervisor, strategy: :one_for_one},
      NanoWeb.Endpoint
    ]

    with {:ok, sup} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Nano.Supervisor) do
      :persistent_term.put(@boot_set, MapSet.new(Process.list()))
      # After the snapshot, so the dashboard user is listed as a process of kind "user".
      Nano.User.start("dashboard")
      {:ok, sup}
    end
  end

  @doc "The processes alive when the tree came up, as a `MapSet` of pids: the process view's standard set."
  def boot_set, do: :persistent_term.get(@boot_set, MapSet.new())
end

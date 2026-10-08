defmodule Nano.Application do
  @moduledoc """
  Starts the node's supervision tree, records the boot set, and brings back the users and
  agents saved before the node last stopped.

  Agents may kill anything here (the spec allows it); the tree is built so that each such kill
  is recovered from without ending the node: every child's restart is retried for a while
  rather than failing at once, the top supervisor tolerates many restarts, and a restarted
  agent or user supervisor brings back what it held.
  """
  use Application
  require Logger

  @boot_set {__MODULE__, :boot_set}

  @impl true
  def start(_type, _args) do
    # Owned by this process, which lives as long as the application, so names outlive Nano.Names.
    Nano.Names.create_table()
    Nano.User.create_table()

    children =
      Enum.map(
        [
          {Phoenix.PubSub, name: Nano.PubSub},
          Nano.Names,
          # The node's settings; its init cannot fail either.
          Nano.Settings,
          Nano.StateStore,
          {Task.Supervisor, name: Nano.EvalSupervisor},
          # Holds the ChatGPT subscription's tokens; its init cannot fail, so it cannot stop the boot.
          Nano.ChatGPT.Auth,
          # OpenRouter logins under way (its OAuth PKCE flow).
          Nano.OpenRouter.Auth,
          %{id: Nano.AgentSupervisor, start: {__MODULE__, :start_agents, []}, type: :supervisor},
          %{id: Nano.UserSupervisor, start: {__MODULE__, :start_users, []}, type: :supervisor},
          {Seedling.Background.Recovery, []},
          {Seedling.MCP.Supervisor, [config: "/app/config/mcp.json", name: Seedling.MCP.Connections]},
          NanoWeb.Endpoint
        ],
        &retrying/1
      )

    # Each kill of a child costs one restart; the default limit (3 in 5 s) would let a few
    # kills of the dashboard end the whole node.
    opts = [strategy: :one_for_one, name: Nano.Supervisor, max_restarts: 100, max_seconds: 10]

    with {:ok, sup} <- Supervisor.start_link(children, opts) do
      :persistent_term.put(@boot_set, MapSet.new(Process.list()))
      # After the snapshot, so users are listed as processes of kind "user". Users come back
      # with their messages, before the agents (with their history) who may send to them.
      best_effort(&Nano.User.revive/0)

      best_effort(fn ->
        Nano.StateStore.load()
        NanoAgent.revive(Nano.AgentSupervisor)
      end)

      {:ok, sup}
    end
  end

  # A killed child's old tree shuts down asynchronously: until it has, its names (and, for the
  # endpoint, its port) are still taken and an immediate restart fails. Failing would make the
  # supervisor retry in a tight loop until it gave up, ending the node; so wait and retry.
  defp retrying(spec) do
    %{start: start} = spec = Supervisor.child_spec(spec, [])
    %{spec | start: {__MODULE__, :start_retrying, [start]}}
  end

  @doc false
  # Calls the child's own start function, retrying every 50 ms for up to 5 s while it fails.
  def start_retrying({m, f, a} = start, attempt \\ 1) do
    case apply(m, f, a) do
      {:error, _} when attempt < 100 ->
        Process.sleep(50)
        start_retrying(start, attempt + 1)

      result ->
        result
    end
  end

  @doc """
  Starts `Nano.AgentSupervisor`, with generous limits: the per-agent restart brake is the
  real limit. If it was killed, its agents died with it; they are
  brought back from `Nano.StateStore`, history and all.
  """
  def start_agents do
    opts = [
      name: Nano.AgentSupervisor,
      strategy: :one_for_one,
      max_restarts: 1000,
      max_seconds: 60
    ]

    with {:ok, sup} <- DynamicSupervisor.start_link(opts) do
      best_effort(fn -> NanoAgent.revive(sup) end)
      {:ok, sup}
    end
  end

  @doc """
  Starts `Nano.UserSupervisor`. If it was killed, its users died with it; they are started
  again with their messages (`Nano.User.revive/0`).
  """
  def start_users do
    with {:ok, sup} <-
           DynamicSupervisor.start_link(name: Nano.UserSupervisor, strategy: :one_for_one) do
      # The boot set exists only once the tree has come up the first time.
      if :persistent_term.get(@boot_set, nil),
        do: best_effort(&Nano.User.revive/0)

      {:ok, sup}
    end
  end

  # Extra work in a start function must not fail the child it starts.
  defp best_effort(fun) do
    fun.()
  catch
    kind, reason -> Logger.error("Nano.Application: " <> Exception.format_banner(kind, reason))
  end

  @doc "The processes alive when the tree came up, as a `MapSet` of pids: the process view's standard set."
  def boot_set, do: :persistent_term.get(@boot_set, MapSet.new())
end

defmodule Vega.Boot do
  @moduledoc """
  Seedling services start after durable agent state is loaded/revived, so a bot
  outbox cannot create a fresh agent over a saved one. Nano.Application calls
  start_services/1; defaults are eager in normal environments, disabled in tests.
  Lazy services already running are safely adopted by the root supervisor.
  """
  def start_services(supervisor) do
    if Application.get_env(:nano, :vega_autostart, true) do
      root = Application.get_env(:nano, :vega_root, "/data/vega")

      results =
        for spec <- [
              {Vega.Delegation.Supervisor, []},
              {Vega.MCP.Supervisor, []},
              {Vega.Bots.Server, [root: root]}
            ],
            do: ensure_child(supervisor, spec)

      restored = Vega.Delegation.restore()
      {:ok, %{services: results, delegation: restored}}
    else
      {:ok, :disabled}
    end
  end

  def ensure_child(supervisor, {module, opts}) do
    spec = Supervisor.child_spec({module, opts}, [])
    spec = %{spec | start: {__MODULE__, :start_or_adopt, [module, opts]}}

    case Supervisor.start_child(supervisor, spec) do
      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, :already_present} ->
        case Supervisor.restart_child(supervisor, spec.id) do
          {:error, :running} -> {:ok, :running}
          other -> other
        end

      other ->
        other
    end
  end

  @doc false
  def start_or_adopt(module, opts) do
    case module.start_link(opts) do
      {:error, {:already_started, pid}} ->
        Process.link(pid)
        {:ok, pid}

      other ->
        other
    end
  end
end

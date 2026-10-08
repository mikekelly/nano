defmodule Seedling.Delegation.SetupGuard do
  @moduledoc false

  # A constructor runs in a disposable eval task. MCP delivery is held during setup,
  # so losing that task must not leave a silent, half-configured child forever.
  def run(child, id, servers, mcp_opts, fun) do
    guard = start(self(), child, id, servers, mcp_opts)

    result =
      try do
        fun.()
      rescue
        e -> {:error, Exception.message(e)}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    if result != :ok,
      do: fail(child, id, servers, mcp_opts, "Child setup failed: #{inspect(result)}")

    send(guard, :release)
    result
  end

  def start(constructor, child, id, servers \\ [], mcp_opts \\ []) do
    spawn(fn ->
      ref = Process.monitor(constructor)

      receive do
        :release ->
          Process.demonitor(ref, [:flush])

        {:DOWN, ^ref, :process, _, reason} ->
          fail(
            child,
            id,
            servers,
            mcp_opts,
            "Delegation constructor exited during setup: #{inspect(reason)}. Half-setup child terminated."
          )
      end
    end)
  end

  def fail(child, id, servers, mcp_opts, summary) do
    # Do not terminate a different job which has since reused this name.
    safe(fn ->
      with %{id: ^id, pid: pid} when is_pid(pid) <- NanoAgent.info(child),
           do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
    end)

    safe(fn -> Seedling.Delegation.Manager.report(child, summary, :error, child_id: id) end)

    cleanup =
      case NanoAgent.info(child) do
        %{id: ^id} -> true
        nil -> NanoAgent.whereis(child) == nil
        _ -> false
      end

    Enum.each(if(cleanup, do: servers, else: []), fn server ->
      safe(fn ->
        apply(Seedling.MCP, :disconnect, [server, Keyword.put(mcp_opts, :agent, child)])
      end)
    end)

    :ok
  end

  defp safe(fun) do
    try do
      fun.()
    catch
      _, _ -> :ignored
    end
  end
end

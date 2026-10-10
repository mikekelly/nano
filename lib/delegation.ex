defmodule Delegation do
  @moduledoc """
  Named, restart-aware delegation. Starts happen in the caller, preserving `started_by`.

      Delegation.subagent("scout", level: :engineering, job: "Review the parser",
        parent: "altair", pre: ["lib/parser.ex"], message: %{task: "Find defects"})

  Editing jobs must supply `worktree: [revision: "<commit>", path: "/tmp/scout",
  branch: "seedling/scout"]`; repository defaults to `/app`. No revision default.
  Read-only jobs omit worktree. Returned map is compact (name, pid, model, pre hashes,
  worktree); no transcript. Start idle unless `message:` is supplied.

  Parent gets `%{delegation: :result | :halted | :death | :restarted, child: name,
  parent: name, from: child_name, event_id: id, ...}` via NanoAgent.notify. Delivery is at-least-once:
  call `ack(event_id)` after handling. Pending events retry after parent restart.
  `events(child)` retrieves durable unacknowledged events without spending turns;
  use the idle tool to wait, not polling model calls. `report(child, result)` sends a
  bounded result (16 KiB external term maximum). Events never include transcripts.
  Halts are detected within one second; deaths are monitored and restart pids reattached.

  `level:` or `stratum:` accepts exec/lead/worker/grunt and the legacy engineering alias.
  `model:` accepts the same stratum atoms or an explicit slug; `reasoning:` defaults
  to low (strata cannot override operator effort). Nano.Staffing validates before
  worktree creation and startup validates again. Job levels use guidance's model/effort pairs. Limits are always whole model window,
  zero turns and zero token budget. NanoAgent validates the operator allowlist.
  Optional `mcp: servers` requires an initializer configured as application env
  `:nano, :delegation_mcp_initializer` MFA; called with `[child_name, servers | args]`
  while child is idle. Missing integration errors before starting. It must return :ok
  or {:error, reason}, cleaning up any servers it created on failure. Startup failures
  remove the new child, state, registry entry and any new worktree/branch. This hook does not pretend MCP is implemented.
  """
  def subagent(name, opts) do
    opts = Keyword.put(opts, :name, name)

    with :ok <- validate(opts),
         {:ok, parent} <- parent(opts),
         :ok <- mcp_available(opts[:mcp]),
         {:ok, staffing} <-
           Nano.Staffing.select(opts[:model] || opts[:stratum] || opts[:level],
             effort: opts[:reasoning] || "low"
           ),
         model = staffing.model,
         {:ok, entry} <- Nano.Model.lookup(model),
         {:ok, _} <- Nano.Model.check(model, staffing.effort, entry.context_length),
         {:ok, worktree} <- worktree(opts[:worktree]) do
      prepared =
        opts
        |> Keyword.put_new(
          :level,
          if(staffing.stratum, do: String.to_existing_atom(staffing.stratum), else: :engineering)
        )
        |> Keyword.put(:staffing, staffing)
        |> Keyword.put(:parent, parent)
        |> Keyword.put(:worktree, worktree)
        |> Keyword.put_new(:cwd, if(worktree, do: worktree.path, else: "/app"))

      result = launch(prepared, model, entry)

      case result do
        {:ok, _} ->
          result

        {:error, _} ->
          rollback_worktree(worktree, opts[:worktree])
          result
      end
    end
  end

  defp launch(opts, model, entry) do
    name = opts[:name]

    with {:ok, composed} <- Delegation.Prompt.compose(opts),
         :ok <- Delegation.Monitor.reserve(name, opts[:parent]) do
      case start(name, model, entry, composed.prompt, opts[:staffing].effort) do
        {:ok, pid} ->
          case initialize_mcp(name, opts[:mcp]) do
            :ok ->
              :ok = Delegation.Monitor.activate(name)

              if Keyword.has_key?(opts, :message),
                do:
                  NanoAgent.notify(
                    name,
                    %{
                      delegation: :task,
                      from: opts[:parent],
                      parent: opts[:parent],
                      task: opts[:message]
                    }
                  )

              {:ok,
               %{
                 name: name,
                 pid: pid,
                 parent: opts[:parent],
                 model: model,
                 pre: composed.pre,
                 worktree: opts[:worktree],
                 prompt_provenance: composed.provenance,
                 staffing: opts[:staffing]
               }}

            {:error, why} ->
              DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
              NanoAgent.kill_tasks(pid)
              Nano.StateStore.delete(name)
              Delegation.Monitor.cancel(name)
              {:error, {:mcp_initialization_failed, why}}
          end

        error ->
          error
      end
    end
  end

  defp rollback_worktree(nil, _), do: :ok

  defp rollback_worktree(w, opts) do
    repo = opts[:repo] || "/app"

    System.cmd("git", ["worktree", "remove", "--force", "--", w.path],
      cd: repo,
      stderr_to_stdout: true
    )

    System.cmd("git", ["branch", "-D", "--", w.branch], cd: repo, stderr_to_stdout: true)
    :ok
  end

  defp validate(opts) do
    cond do
      not (is_binary(opts[:name]) and opts[:name] =~ ~r/^[\w.-]+$/) ->
        {:error, "invalid agent name"}

      not (is_binary(opts[:job]) and byte_size(opts[:job]) > 0) ->
        {:error, "job must be nonempty text"}

      NanoAgent.whereis(opts[:name]) != nil ->
        {:error, "agent name already live"}

      true ->
        :ok
    end
  end

  defp parent(opts) do
    inferred =
      with [pid | _] <- Process.get(:"$callers"),
           [name | _] <- for({{:agent, name}, ^pid} <- Nano.Names.all(), do: name),
           do: name

    case opts[:parent] || if(is_binary(inferred), do: inferred) do
      p when is_binary(p) and byte_size(p) > 0 -> {:ok, p}
      _ -> {:error, "parent must be a stable agent name (or call from an agent eval)"}
    end
  end

  def model(choice) do
    with {:ok, pair} <- Nano.Staffing.mapping(choice), do: {:ok, pair.model}
  end

  defp start(name, model, entry, prompt, effort) do
    case NanoAgent.start(
           name: name,
           model: model,
           reasoning: effort,
           max_context: entry.context_length,
           max_turns: 0,
           max_tokens: 0,
           start_idle: true,
           system_prompt: prompt
         ) do
      {:ok, _} = ok ->
        ok

      error ->
        Delegation.Monitor.cancel(name)
        error
    end
  end

  defp mcp_available(nil), do: :ok
  defp mcp_available([]), do: :ok

  defp mcp_available(_) do
    case Application.get_env(:nano, :delegation_mcp_initializer) do
      {m, f, a} when is_atom(m) and is_atom(f) and is_list(a) ->
        if Code.ensure_loaded?(m) and function_exported?(m, f, length(a) + 2),
          do: :ok,
          else: {:error, "MCP initializer unavailable"}

      _ ->
        {:error,
         "MCP is not integrated: configure :delegation_mcp_initializer before requesting servers"}
    end
  end

  defp initialize_mcp(_, servers) when servers in [nil, []], do: :ok

  defp initialize_mcp(name, servers) do
    {m, f, a} = Application.fetch_env!(:nano, :delegation_mcp_initializer)

    case apply(m, f, [name, servers | a]) do
      :ok -> :ok
      {:error, _} = e -> e
      other -> {:error, {:unexpected_initializer_result, other}}
    end
  catch
    kind, why -> {:error, {kind, why}}
  end

  def worktree(nil), do: {:ok, nil}

  def worktree(opts) when is_list(opts) do
    repo = opts[:repo] || "/app"

    with true <- Enum.all?([:revision, :path, :branch], &(is_binary(opts[&1]) and opts[&1] != "")),
         false <- File.exists?(opts[:path]),
         {hash, 0} <-
           System.cmd(
             "git",
             ["rev-parse", "--verify", "--end-of-options", opts[:revision] <> "^{commit}"],
             cd: repo,
             stderr_to_stdout: true
           ),
         {_, 0} <-
           System.cmd(
             "git",
             [
               "worktree",
               "add",
               "-b",
               opts[:branch],
               "--",
               Path.expand(opts[:path]),
               String.trim(hash)
             ],
             cd: repo,
             stderr_to_stdout: true
           ) do
      {:ok, %{path: Path.expand(opts[:path]), branch: opts[:branch], revision: String.trim(hash)}}
    else
      why -> {:error, {:worktree_failed, why}}
    end
  rescue
    e -> {:error, {:worktree_failed, Exception.message(e)}}
  end

  def worktree(_), do: {:error, "worktree must be keyword options with revision, path, branch"}
  def report(child, result), do: Delegation.Monitor.emit(child, :result, %{result: result})
  def ack(id), do: Delegation.Monitor.ack(id)
  def events(child), do: Delegation.Monitor.events(child)
end

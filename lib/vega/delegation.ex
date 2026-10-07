defmodule Vega.Delegation do
  @moduledoc """
  Starts agents from eval, preserving harness started_by. Required options: model,
  reasoning, max_turns, max_tokens, max_context. Options: parent (name or pid), job,
  pre (paths), worktree (repo/revision/path/branch), message, start_idle, mcp_hook (MFA).
  `tell(name, term)` addresses by name. `report(child_name, map)` delivers a compact
  result. Events: %{delegation: :result | :halted | :down, child: name, result: map}.
  Wait with the harness idle tool, never a blocking eval. See docs/vega-delegation.md.
  """
  @shared """
  You are a delegated agent. Defend context at your assigned level; delegate large
  independent tasks. Build abstractions and use them. Read /app/seedings/guidance.md.
  Share the machine safely: edit only assigned files in your worktree; use unique tmp
  directories, MIX_ENV=test and isolated MIX_BUILD_ROOT. Never reload Nano modules,
  change node settings or touch others' processes. Parent integrates your commits.
  Compact before exhaustion if available; otherwise report an early checkpoint and ask
  for a successor. Budget halts are not compaction. Report tests actually run and limits.
  """
  def subagent(name, opts) do
    parent = opts[:parent] || caller_name()

    with :ok <- validate(name, parent, opts),
         {:ok, pre} <- preread(opts[:pre] || [], opts[:pre_max_bytes] || 64_000),
         {:ok, hook} <- hook(opts[:mcp_hook]),
         {:ok, workspace} <- workspace(name, opts[:worktree]) do
      case launch(name, parent, opts, pre, workspace, hook) do
        {:ok, _} = ok ->
          ok

        error ->
          cleanup(workspace)
          error
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp launch(name, parent, opts, pre, workspace, hook) do
    with {:ok, prompt} <- compose(name, parent, opts, pre, workspace, hook),
         {:ok, pid} <-
           NanoAgent.start(
             Keyword.take(opts, [:model, :reasoning, :max_turns, :max_tokens, :max_context]) ++
               [name: name, system_prompt: prompt, start_idle: true]
           ),
         {:ok, _} <- Vega.Delegation.Watcher.start(name, parent, pid, opts[:poll_ms] || 250) do
      if opts[:message], do: tell(name, opts[:message])

      if not Keyword.get(opts, :start_idle, true) and not opts[:message],
        do: tell(name, %{message: "Begin the assigned job.", sender: parent})

      {:ok,
       %{
         name: name,
         parent: parent,
         workspace: workspace,
         pre: Enum.map(pre, &Map.drop(&1, [:text])),
         prompt_bytes: byte_size(prompt)
       }}
    end
  end

  def compose(name, parent, opts, pre \\ [], workspace \\ nil, hook \\ nil) do
    with {:ok, facts} <- File.read(opts[:facts_file] || "/app/priv/system_prompt.txt") do
      reading =
        Enum.map_join(pre, "\n", fn p ->
          "PRE-READ #{p.path} SHA256=#{p.sha256}\n#{p.text}\nEND PRE-READ"
        end)

      identity =
        "Child: #{name}; parent: #{inspect(parent)}. Report with Vega.Delegation.report(#{inspect(name)}, %{summary: ..., tests: ..., commit: ...})."

      job =
        "Assigned job:\n#{opts[:job] || "Await instructions."}\nWorkspace: #{inspect(workspace)}\nMCP startup: #{inspect(hook)}"

      {:ok, Enum.join([facts, @shared, identity, job, reading], "\n\n")}
    end
  end

  def preread(paths, cap \\ 64_000) do
    Enum.reduce_while(paths, {:ok, [], 0}, fn path, {:ok, acc, used} ->
      case File.stat(path) do
        {:ok, %{size: size}} when size + used <= cap ->
          case File.read(path) do
            {:ok, text} when byte_size(text) + used <= cap ->
              p = %{
                path: Path.expand(path),
                sha256: hash(text),
                bytes: byte_size(text),
                text: text
              }

              {:cont, {:ok, [p | acc], used + byte_size(text)}}

            error ->
              {:halt, {:error, {:pre_read, path, error}}}
          end

        {:ok, _} ->
          {:halt, {:error, {:pre_read_too_large, path, cap}}}

        error ->
          {:halt, {:error, {:pre_read, path, error}}}
      end
    end)
    |> case do
      {:ok, acc, _} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  def changed?(%{path: path, sha256: digest}) do
    with {:ok, text} <- File.read(path), do: {:ok, hash(text) != digest}
  end

  defp hash(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)

  def tell(name, term) do
    if NanoAgent.whereis(name),
      do:
        (
          NanoAgent.notify(name, term)
          :ok
        ),
      else: {:error, :not_found}
  end

  def report(name, result) when is_map(result) do
    case :global.whereis_name({Vega.Delegation.Watcher, name}) do
      :undefined -> {:error, :not_watched}
      pid -> GenServer.call(pid, {:result, result})
    end
  end

  defp caller_name do
    callers = Process.get(:"$callers", [])

    Enum.find_value(Nano.Names.all(), fn
      {{:agent, name}, pid} -> if pid in [self() | callers], do: name
      _ -> nil
    end)
  end

  defp validate(name, parent, opts) do
    cond do
      not is_binary(name) or not Regex.match?(~r/^[\w.-]+$/, name) ->
        {:error, :invalid_name}

      not (is_binary(parent) or is_pid(parent)) ->
        {:error, :parent_required}

      Enum.any?([:model, :reasoning, :max_turns, :max_tokens, :max_context], &is_nil(opts[&1])) ->
        {:error, :explicit_model_and_limits_required}

      NanoAgent.whereis(name) != nil ->
        {:error, :already_started}

      true ->
        :ok
    end
  end

  defp workspace(_, nil), do: {:ok, nil}

  defp workspace(name, opts) do
    repo = opts[:repo] || "/app"
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    path = opts[:path] || "/tmp/vega-delegation/#{name}-#{suffix}"
    branch = opts[:branch] || "seedling/vega-#{name}-#{suffix}"
    File.mkdir_p(Path.dirname(path))

    case System.cmd(
           "git",
           ["-C", repo, "worktree", "add", "-b", branch, path, opts[:revision] || "HEAD"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        {:ok, %{path: path, repo: repo, branch: branch, build_root: Path.join(path, "_build")}}

      {output, code} ->
        {:error, {:worktree, code, output}}
    end
  end

  defp cleanup(nil), do: :ok

  defp cleanup(w),
    do: System.cmd("git", ["-C", w.repo, "worktree", "remove", w.path], stderr_to_stdout: true)

  defp hook(nil), do: {:ok, nil}

  defp hook({m, f, args}) do
    case apply(m, f, args) do
      {:ok, value} -> {:ok, value}
      {:error, _} = error -> error
      value -> {:ok, value}
    end
  end
end

defmodule Vega.Delegation.Watcher do
  @moduledoc false
  use GenServer

  def start(name, parent, pid, interval),
    do:
      GenServer.start(__MODULE__, {name, parent, pid, interval},
        name: {:global, {__MODULE__, name}}
      )

  def init({name, parent, pid, interval}) do
    Process.send_after(self(), :poll, interval)

    {:ok,
     %{
       name: name,
       parent: parent,
       ref: Process.monitor(pid),
       interval: interval,
       halt: nil,
       done: false
     }}
  end

  def handle_call({:result, result}, _from, s) do
    if s.done do
      {:reply, {:error, :already_reported}, s}
    else
      emit(s, :result, result)
      {:reply, :ok, %{s | done: true}}
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{ref: ref} = s) do
    unless s.done, do: emit(s, :down, %{reason: reason})
    {:noreply, %{s | ref: nil}}
  end

  def handle_info(:poll, s) do
    info = NanoAgent.info(s.name)
    s = if s.ref == nil && info && info.pid, do: %{s | ref: Process.monitor(info.pid)}, else: s
    halted = info && info.halted

    if halted && halted != s.halt && not s.done,
      do: emit(s, :halted, %{reason: halted, budget: info.budget})

    Process.send_after(self(), :poll, s.interval)
    {:noreply, %{s | halt: halted}}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp emit(s, kind, result) do
    event = %{delegation: kind, child: s.name, result: result}
    if is_pid(s.parent), do: send(s.parent, event), else: NanoAgent.notify(s.parent, event)
  end
end

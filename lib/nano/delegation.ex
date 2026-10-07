defmodule Nano.Delegation do
  @moduledoc """
  One-eval delegation. See `docs/nova-delegation.md` for options and protocol.
  `subagent(name, opts)` returns a compact handle; `reply(handle, summary)` sends
  a named result, not a transcript. Parents call idle, not a polling model turn.
  Model/reasoning/limits are explicit; starts occur in the caller to preserve started_by.
  """
  @shared """
  Defend your context: build reusable functions, delegate large subtasks, stay at your
  assigned level. Hand over before half your context is used, with current notes.
  You share this machine. Own only assigned files; never edit /app for an isolated job.
  Use unique task directories and test resources. Never change global env or expose keys.
  Commit changes, report hashes and tests honestly; do not merge. Your textual response
  is only a log: report through Nano.Delegation.reply/2 from eval, then idle.
  """

  def subagent(name, opts) do
    adapter = opts[:adapter] || NanoAgent
    parent = opts[:parent] || caller_name()

    with :ok <- validate(name, parent, opts),
         {:ok, pre} <- pre_read(opts[:pre] || [], opts[:pre_max_bytes] || 65_536),
         {:ok, workspace} <- workspace(name, opts[:worktree]),
         {:ok, mcp} <- setup_mcp(name, opts[:mcp] || [], opts) do
      id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

      handle = %{
        id: id,
        name: name,
        parent: parent,
        workspace: workspace,
        storage_dir: opts[:storage_dir] || default_storage(),
        pre: Enum.map(pre, &Map.delete(&1, :content)),
        mcp: mcp
      }

      prompt = compose(name, handle, opts, pre)

      start_opts =
        Keyword.take(opts, [:model, :reasoning, :max_turns, :max_tokens, :max_context]) ++
          [name: name, system_prompt: prompt, start_idle: true]

      case adapter.start(start_opts) do
        {:ok, pid} ->
          with {:ok, watcher} <- watch(handle, Keyword.put(opts, :adapter, adapter)) do
            handle =
              Map.merge(handle, %{pid: pid, watcher: watcher, prompt_bytes: byte_size(prompt)})

            if Keyword.has_key?(opts, :message),
              do:
                adapter.notify(name, %{
                  delegation: :task,
                  id: id,
                  from: parent,
                  reply_to: parent,
                  child: name,
                  message: opts[:message],
                  handle: handle
                })

            {:ok, handle}
          else
            error ->
              {:error, %{stage: :watch, reason: error, child: name, pid: pid, handle: handle}}
          end

        error ->
          adapter.notify(parent, %{
            delegation: :failure,
            id: id,
            from: name,
            reply_to: parent,
            kind: :start,
            reason: inspect(error)
          })

          # Preserve failed worktrees for inspection; never delete someone else's work.
          {:error, %{stage: :start, reason: error, workspace: workspace}}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp validate(name, parent, opts) do
    missing =
      Enum.filter([:model, :reasoning, :max_turns, :max_tokens, :max_context], &is_nil(opts[&1]))

    cond do
      not is_binary(name) or not Regex.match?(~r/^[\w.-]+$/, name) ->
        {:error, "invalid agent name"}

      not is_binary(parent) ->
        {:error, "give parent: registered agent name (or call from agent eval)"}

      missing != [] ->
        {:error, "missing explicit options: #{Enum.join(missing, ", ")}"}

      not is_integer(opts[:max_context]) or opts[:max_context] < 8192 ->
        {:error, "max_context must leave reporting room (at least 8192)"}

      true ->
        :ok
    end
  end

  defp caller_name do
    with [pid | _] <- Process.get(:"$callers", []),
         [{:agent, name}] <- Registry.keys(Nano.Registry, pid),
         do: name,
         else: (_ -> nil)
  end

  @doc "Read complete UTF-8 snapshots, capped in total; never silently truncate pre-reading."
  def pre_read(paths, max_bytes \\ 65_536) do
    Enum.reduce_while(paths, {:ok, [], 0}, fn path, {:ok, acc, used} ->
      path = Path.expand(path)

      case File.read(path) do
        {:ok, text} when byte_size(text) + used <= max_bytes ->
          if String.valid?(text),
            do:
              {:cont,
               {:ok, acc ++ [%{path: path, sha256: hash(text), content: text}],
                used + byte_size(text)}},
            else: {:halt, {:error, "pre-reading must be UTF-8: #{path}"}}

        {:ok, _} ->
          {:halt, {:error, "pre-reading exceeds #{max_bytes} bytes; select smaller files"}}

        {:error, reason} ->
          {:halt, {:error, {path, reason}}}
      end
    end)
    |> case do
      {:ok, files, _} -> {:ok, files}
      error -> error
    end
  end

  def changed?(%{path: path, sha256: sha}) do
    with {:ok, text} <- File.read(path), do: {:ok, hash(text) != sha}
  end

  defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  @doc "Reusable identity, harness facts, shared operating rules, role, job and hashed snapshots."
  def compose(name, handle, opts, pre \\ []) do
    facts = opts[:facts] || File.read!(Application.app_dir(:nano, "priv/system_prompt.txt"))

    identity =
      opts[:identity] || "You are delegated agent #{name}, reporting to #{handle.parent}."

    readings =
      Enum.map_join(pre, "\n", fn f ->
        "PRE-READ #{f.path} SHA256 #{f.sha256}\n#{f.content}\nEND PRE-READ"
      end)

    Enum.join(
      [
        facts,
        identity,
        @shared,
        "Role/level: #{opts[:role] || "implementation"}",
        "Reply with Nano.Delegation.reply(#{inspect(Map.take(handle, [:id, :name, :parent, :storage_dir]))}, summary).",
        "Workspace: #{inspect(handle.workspace)}. MCP: #{inspect(handle.mcp)}.",
        opts[:prompt] || "",
        readings
      ],
      "\n\n"
    )
  end

  @doc "Create a new branch/worktree at revision. Refuses existing path/branch; keeps commits for parent."
  def workspace(_name, nil), do: {:ok, nil}

  def workspace(name, opts) when is_list(opts) do
    repo = Path.expand(opts[:repo] || "/app")

    path =
      Path.expand(
        opts[:path] ||
          Path.join(System.tmp_dir!(), "delegation-#{name}-#{System.unique_integer([:positive])}")
      )

    branch = opts[:branch] || "delegation/#{name}-#{System.unique_integer([:positive])}"
    revision = opts[:revision] || "HEAD"

    with false <- File.exists?(path),
         {sha, 0} <-
           System.cmd("git", ["-C", repo, "rev-parse", "--verify", "#{revision}^{commit}"],
             stderr_to_stdout: true
           ),
         {_, 0} <-
           System.cmd(
             "git",
             ["-C", repo, "worktree", "add", "-b", branch, path, String.trim(sha)],
             stderr_to_stdout: true
           ) do
      {:ok,
       %{
         path: path,
         repo: repo,
         branch: branch,
         revision: String.trim(sha),
         env: [{"MIX_ENV", "test"}, {"MIX_BUILD_ROOT", Path.join(path, "_build-isolated")}]
       }}
    else
      true -> {:error, "worktree path exists: #{path}"}
      result -> {:error, {:worktree, result}}
    end
  end

  @doc "Send a task by registered name, even after restart."
  def send_task(handle, message),
    do:
      NanoAgent.notify(
        handle.name,
        %{
          delegation: :task,
          id: handle.id,
          from: handle.parent,
          reply_to: handle.parent,
          child: handle.name,
          message: message
        }
      )

  @doc "Compact terminal result. Required handle keys: id, name, parent."
  def reply(handle, summary) do
    term = %{
      delegation: :result,
      id: handle.id,
      from: handle.name,
      reply_to: handle.parent,
      result: summary
    }

    NanoAgent.notify(handle.parent, term)
    File.rm(manifest_path(handle.id, handle[:storage_dir]))

    case Registry.lookup(Nano.Registry, {:delegation, handle.id}) do
      [{pid, _}] -> send(pid, :complete)
      [] -> :ok
    end

    :ok
  end

  @doc "Persist and watch a handle; restart watchers after node restart with restore/1."
  def watch(handle, opts \\ []) do
    adapter = opts[:adapter] || NanoAgent
    path = manifest_path(handle.id, handle[:storage_dir])

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, :erlang.term_to_binary(Map.drop(handle, [:pid, :watcher]))) do
      case Nano.Delegation.Watcher.start(handle, adapter, opts) do
        {:error, {:already_started, pid}} -> {:ok, pid}
        result -> result
      end
    end
  end

  @doc "Resume durable lifecycle watches. Run at boot or from a successor's eval; no model calls."
  def restore(opts \\ []) do
    dir = opts[:storage_dir] || default_storage()

    for path <- Path.wildcard(Path.join(dir, "*.term")) do
      with {:ok, binary} <- File.read(path),
           %{} = handle <- :erlang.binary_to_term(binary, [:safe]) do
        {handle.name, watch(handle, opts)}
      end
    end
  end

  defp default_storage,
    do: Path.join(Application.get_env(:nano, :state_dir, "/data/state"), "delegations")

  defp manifest_path(id, dir), do: Path.join(dir || default_storage(), id <> ".term")

  defp setup_mcp(_name, [], _opts), do: {:ok, []}

  defp setup_mcp(name, servers, opts) do
    case opts[:mcp_setup] do
      fun when is_function(fun, 2) ->
        fun.(name, servers)

      _ ->
        {:error,
         "MCP requested: supply mcp_setup: fn agent_name, servers -> {:ok, public_handles} end; see docs"}
    end
  end
end

defmodule Nano.Delegation.Watcher do
  @moduledoc false
  use GenServer

  def start(handle, adapter, opts),
    do:
      GenServer.start(__MODULE__, {handle, adapter, opts},
        name: {:via, Registry, {Nano.Registry, {:delegation, handle.id}}}
      )

  def init({handle, adapter, opts}) do
    pid = adapter.whereis(handle.name)
    ref = if pid, do: Process.monitor(pid)
    interval = opts[:poll_ms] || 250
    Process.send_after(self(), :poll, interval)
    {:ok, %{handle: handle, adapter: adapter, ref: ref, interval: interval, last: nil}}
  end

  def handle_info(:complete, s), do: {:stop, :normal, s}

  def handle_info({:DOWN, ref, :process, _, reason}, %{ref: ref} = s) do
    report(s, :exit, inspect(reason))
    {:noreply, %{s | ref: nil}}
  end

  def handle_info(:poll, s) do
    info = s.adapter.info(s.handle.name)
    halted = if info, do: info[:halted], else: :missing
    if halted && halted != s.last, do: report(s, :halted, halted)

    s =
      if s.ref == nil do
        case s.adapter.whereis(s.handle.name) do
          nil -> s
          pid -> %{s | ref: Process.monitor(pid)}
        end
      else
        s
      end

    Process.send_after(self(), :poll, s.interval)
    {:noreply, %{s | last: halted}}
  end

  defp report(s, kind, reason),
    do:
      s.adapter.notify(
        s.handle.parent,
        %{
          delegation: :failure,
          id: s.handle.id,
          from: s.handle.name,
          reply_to: s.handle.parent,
          kind: kind,
          reason: reason
        }
      )
end

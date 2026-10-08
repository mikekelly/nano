defmodule Delegation do
  @moduledoc """
  Start fitted, watched children from one eval (the start stays in the caller's eval,
  preserving `NanoAgent.info(child).started_by`). Required options: `revision` (an
  explicit git commit/ref, including for read-only tasks), `task`, `model` (provider
  slug), `reasoning`, `max_turns`, `max_tokens`, `max_context`. Limits follow NanoAgent:
  nonnegative whole numbers, 0 unlimited, except context must be positive. Model-specific
  validation is performed by NanoAgent before the child starts.

      Delegation.subagent("scout", revision: "COMMIT", task: "Review ...",
        model: "openai-codex/gpt-6-astra", reasoning: "low",
        max_turns: 100, max_tokens: 0, max_context: 272000)

  Optional: `worktree: true` (default), `pre: [paths]` (UTF-8, hash-marked, at most
  80,000 rendered bytes), `parts: [names]` (defaults to principles/orientation/builder),
  `message: term` (defaults to the task; explicit nil starts idle), `mcp: [server_names]`.
  MCP setup and readiness checks complete before the child can process any message;
  see `MCP` for configured server names and usage.
  The `mcp` partial is added automatically when servers are requested.
  Unknown or duplicate options are errors. Names and partial names are safe path components.

  Returns `{:ok, %{name: name, pid: pid, directory: path, revision: commit}}` or
  `{:error, reason}`. A failed start removes only the worktree/branch created by this
  call; successful worktrees are retained. Existing agents/branches/directories are
  never reused or deleted. Git commands and paths are relative to `/app`, not the eval cwd.
  Read-only children receive `/app (read-only)`; this is an instruction, not a sandbox.

  A child calls `report(parent_name, result)`; the parent receives
  `{:delegation, child_name, :result, result}`. `:halted`, `:down`, `:restarted` events
  carry `%{status: string, directory: path}`. Wait with the idle tool, not polling model
  turns. Reports should include commits, verification, usage and limitations, not transcripts.
  Lifecycle notifications are polled and durably queued while the parent is absent;
  delivery is best effort to the named mailbox (a crash can duplicate a notification).
  Polling may miss brief intermediate states. Names survive restarts.

  Supervise `Delegation.Watcher` at boot after Nano.StateStore and the agent supervisor;
  lazy startup is a compatibility fallback, not a substitute for boot supervision.
  Watch state uses `:nano, :delegation_dir`, defaulting to `delegation` beside `:state_dir`.
  `:delegation_repo` (default `/app`) and `:delegation_worktree_root` (default
  `/data/worktrees`) allow isolated installations/tests; prompts live in that repo.
  """

  @required [:revision, :task, :model, :reasoning, :max_turns, :max_tokens, :max_context]
  @optional [:worktree, :pre, :parts, :message, :mcp]
  @default_parts ["principles", "orientation", "builder"]

  @doc "Compose seed facts and ordered reusable partials, then append the job verbatim. Template comments are removed only from partials/seed, never from the job."
  def compose(parts, job) do
    with :ok <- check(is_list(parts) and Enum.all?(parts, &safe_name?/1), :invalid_parts),
         :ok <- check(is_binary(job) and String.valid?(job), :invalid_job),
         {:ok, seed} <- File.read(Path.join(repo(), "prompts/seed.txt")),
         {:ok, texts} <- read_parts(parts) do
      template = Enum.join([seed | texts], "\n")
      {:ok, Regex.replace(~r/\{\{!.*?\}\}/s, template, "") <> "\n" <> job}
    end
  end

  @doc "Validate all option shapes without starting agents or creating worktrees."
  def validate(name, opts) do
    cond do
      not safe_name?(name) ->
        {:error, :invalid_name}

      not (is_list(opts) and Keyword.keyword?(opts)) ->
        {:error, :expected_keyword_options}

      length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))) ->
        {:error, :duplicate_options}

      unknown = Enum.find(Keyword.keys(opts), &(&1 not in (@required ++ @optional))) ->
        {:error, {:unknown_option, unknown}}

      missing = Enum.find(@required, &is_nil(opts[&1])) ->
        {:error, {:missing_option, missing}}

      true ->
        validate_values(opts)
    end
  end

  defp validate_values(opts) do
    checks = [
      revision: text?(opts[:revision]),
      task: text?(opts[:task]),
      model: text?(opts[:model]),
      reasoning: text?(opts[:reasoning]),
      max_turns: limit?(opts[:max_turns]),
      max_tokens: limit?(opts[:max_tokens]),
      max_context: is_integer(opts[:max_context]) and opts[:max_context] > 0,
      worktree: Keyword.get(opts, :worktree, true) in [true, false],
      pre: list_of?(Keyword.get(opts, :pre, []), &text?/1),
      parts: list_of?(Keyword.get(opts, :parts, @default_parts), &safe_name?/1),
      mcp: list_of?(Keyword.get(opts, :mcp, []), &text?/1)
    ]

    case Enum.find(checks, fn {_key, valid} -> not valid end) do
      nil -> :ok
      {key, _} -> {:error, {:invalid_option, key}}
    end
  end

  defp text?(value),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) != "" and
        not String.contains?(value, <<0>>)

  defp limit?(value), do: is_integer(value) and value >= 0
  defp list_of?(value, fun), do: is_list(value) and Enum.all?(value, fun)
  @doc false
  def safe_name?(name),
    do:
      is_binary(name) and byte_size(name) <= 128 and name =~ ~r/^[A-Za-z0-9_][A-Za-z0-9_.-]*$/ and
        not String.contains?(name, "..") and not String.ends_with?(name, [".", ".lock"])

  defp check(true, _), do: :ok
  defp check(false, error), do: {:error, error}

  @doc "Start an idle child, configure its resources/watch, then optionally send its first message."
  def subagent(name, opts) do
    with :ok <- validate(name, opts) do
      :global.trans({{__MODULE__, name}, self()}, fn -> start_child(name, opts) end, [node()])
    end
  end

  defp start_child(name, opts) do
    with {:ok, parent} <- caller_name(),
         :ok <-
           check(NanoAgent.info(name) == nil and NanoAgent.whereis(name) == nil, :name_in_use),
         {:ok, revision} <-
           git(["rev-parse", "--verify", "--end-of-options", opts[:revision] <> "^{commit}"]),
         {:ok, pre} <- preread(Keyword.get(opts, :pre, [])),
         directory = directory(name, opts),
         {:ok, prompt} <-
           compose(
             fitted_parts(opts),
             "Your parent is #{parent}. Report with Delegation.report(#{inspect(parent)}, result). Your work directory: #{directory}. Starting revision: #{revision}. Task: #{opts[:task]}\n" <>
               pre <> mcp_brief(Keyword.get(opts, :mcp, []))
           ),
         :ok <- mcp_available(Keyword.get(opts, :mcp, [])),
         :ok <- Delegation.Watcher.ensure_started(),
         {:ok, resource} <- worktree(name, revision, opts) do
      result =
        attempt(fn ->
          case NanoAgent.start(
                 Keyword.take(opts, [:model, :reasoning, :max_turns, :max_tokens, :max_context]) ++
                   [name: name, system_prompt: prompt, start_idle: true]
               ) do
            {:ok, pid} -> finish_start(name, parent, pid, directory, revision, opts)
            error -> error
          end
        end)

      case result do
        {:ok, _} -> result
        {:error, reason} -> rollback(resource, reason)
      end
    end
  end

  defp finish_start(name, parent, pid, directory, revision, opts) do
    result =
      attempt(fn ->
        with :ok <- :sys.suspend(pid),
             :ok <- mcp_attach(name, Keyword.get(opts, :mcp, [])),
             :ok <-
               Delegation.Watcher.track(%{
                 name: name,
                 parent: parent,
                 pid: inspect(pid),
                 directory: directory,
                 revision: revision
               }) do
          message = Keyword.get(opts, :message, opts[:task])

          if message != nil,
            do:
              NanoAgent.notify(name, %{sender_name: parent, message: message, worktree: directory})

          :ok = :sys.resume(pid)
          {:ok, %{name: name, pid: pid, directory: directory, revision: revision}}
        end
      end)

    case result do
      {:ok, _} ->
        result

      {:error, reason} ->
        cleanup =
          attempt(fn ->
            :ok = DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
            NanoAgent.kill_tasks(pid)
            Nano.StateStore.delete(name)
            mcp_detach(name, Keyword.get(opts, :mcp, []))
          end)

        if cleanup == :ok,
          do: {:error, reason},
          else: {:error, {:cleanup_failed, reason, cleanup}}
    end
  end

  @doc "Find the named agent owning this eval (or the agent process itself)."
  def caller_name do
    pid =
      case Process.get(:"$callers", []) do
        [p | _] -> p
        _ -> self()
      end

    case Enum.find(NanoAgent.list(), &(NanoAgent.whereis(&1) == pid)) do
      nil -> {:error, :not_in_agent_eval}
      name -> {:ok, name}
    end
  end

  @doc "Send a concise result to the named parent. Returns an error when the parent is absent."
  def report(parent, result) do
    with :ok <- check(safe_name?(parent), :invalid_parent),
         {:ok, name} <- caller_name(),
         :ok <- check(NanoAgent.whereis(parent) != nil, :parent_unavailable) do
      NanoAgent.notify(parent, {:delegation, name, :result, result})
    end
  end

  defp fitted_parts(opts) do
    parts = Keyword.get(opts, :parts, @default_parts)
    if Keyword.get(opts, :mcp, []) == [] or "mcp" in parts, do: parts, else: parts ++ ["mcp"]
  end

  defp mcp_brief([]), do: ""
  defp mcp_brief(servers), do: "\nYour configured MCP servers: #{inspect(servers)}.\n"

  defp read_parts(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, texts} ->
      case File.read(Path.join([repo(), "prompts", "partials", part <> ".md"])) do
        {:ok, text} -> {:cont, {:ok, texts ++ [text]}}
        error -> {:halt, error}
      end
    end)
  end

  defp preread(paths) do
    Enum.reduce_while(paths, {:ok, ""}, fn path, {:ok, acc} ->
      with {:ok, stat} <- File.stat(path),
           :ok <- check(stat.type == :regular, {:invalid_prereading_file, path}),
           :ok <- check(stat.size <= 80_000, :prereading_over_80000_bytes),
           {:ok, text} <- File.read(path),
           :ok <- check(String.valid?(text), {:invalid_prereading_encoding, path}) do
        hash = Base.encode16(:crypto.hash(:sha256, text), case: :lower)
        next = acc <> "\nPre-reading #{path} SHA256 #{hash}:\n" <> text

        if byte_size(next) <= 80_000,
          do: {:cont, {:ok, next}},
          else: {:halt, {:error, :prereading_over_80000_bytes}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp repo, do: Application.get_env(:nano, :delegation_repo, "/app")

  defp directory(name, opts) do
    if Keyword.get(opts, :worktree, true),
      do:
        Path.join(Application.get_env(:nano, :delegation_worktree_root, "/data/worktrees"), name),
      else: repo() <> " (read-only)"
  end

  defp worktree(name, revision, opts) do
    if Keyword.get(opts, :worktree, true) do
      directory = directory(name, opts)
      branch = "seedling/deneb-#{name}"
      resource = %{directory: directory, branch: branch}

      with {:error, :enoent} <- File.lstat(directory),
           {:ok, _} <- git(["branch", branch, revision]) do
        case git(["worktree", "add", directory, branch]) do
          {:ok, _} ->
            deps = Path.join(repo(), "deps")

            case if(File.dir?(deps), do: File.ln_s(deps, Path.join(directory, "deps")), else: :ok) do
              :ok -> {:ok, resource}
              error -> rollback(resource, {:dependencies, error})
            end

          {:error, reason} ->
            # A failing post-checkout hook can leave a registered worktree behind.
            git(["worktree", "remove", "--force", directory])

            case git(["branch", "-D", branch]) do
              {:ok, _} -> {:error, reason}
              error -> {:error, {:cleanup_failed, reason, error, resource}}
            end
        end
      else
        {:ok, %File.Stat{}} -> {:error, :worktree_path_exists}
        error -> error
      end
    else
      {:ok, nil}
    end
  end

  defp rollback(nil, reason), do: {:error, reason}

  defp rollback(resource, reason) do
    with {:ok, _} <- git(["worktree", "remove", "--force", resource.directory]),
         {:ok, _} <- git(["branch", "-D", resource.branch]) do
      {:error, reason}
    else
      error -> {:error, {:cleanup_failed, reason, error, resource}}
    end
  end

  # An adapter override is useful in isolated contract tests; the production default is MCP.
  defp mcp_module, do: Application.get_env(:nano, :delegation_mcp_module, MCP)
  defp mcp_available([]), do: :ok

  defp mcp_available(_) do
    module = mcp_module()

    check(
      Code.ensure_loaded?(module) and
        Enum.all?(
          [attach: 2, await: 1, detach: 2],
          fn {fun, arity} -> function_exported?(module, fun, arity) end
        ),
      :mcp_unavailable
    )
  end

  defp mcp_attach(_, []), do: :ok

  defp mcp_attach(name, servers) do
    case apply(mcp_module(), :attach, [name, servers]) do
      :ok ->
        Enum.reduce_while(servers, :ok, fn server, :ok ->
          case apply(mcp_module(), :await, [server]) do
            {:ok, _} -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
            other -> {:halt, {:error, {:unexpected_mcp_response, other}}}
          end
        end)

      {:error, _} = error ->
        error

      other ->
        {:error, {:unexpected_mcp_response, other}}
    end
  end

  defp mcp_detach(_, []), do: :ok

  defp mcp_detach(name, servers) do
    failures =
      for server <- servers,
          result = attempt(fn -> apply(mcp_module(), :detach, [server, [agent: name]]) end),
          result != :ok,
          do: {server, result}

    if failures == [], do: :ok, else: {:error, {:mcp_detach_failed, failures}}
  end

  defp attempt(fun) do
    fun.()
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp git(args) do
    attempt(fn ->
      case System.cmd("git", ["-C", repo() | args], stderr_to_stdout: true) do
        {text, 0} -> {:ok, String.trim(text)}
        {text, n} -> {:error, {:git, n, text}}
      end
    end)
  end
end

defmodule Delegation.Watcher do
  @moduledoc """
  Durable lifecycle watches for delegated children. Supervise this server at boot after
  the agent supervisor and state store. `track/1` writes before acknowledging; JSON files
  are atomically replaced. Corrupt records are logged and skipped, not allowed to crash
  all watches. A write failure keeps the previous state for retry on the next poll.

  Events: `{:delegation, child_name, :down | :halted | :restarted,
  %{status: string, directory: path}}`. Pending events survive watcher/node restarts and
  wait until the named parent exists. Notification delivery is not acknowledged by the
  parent's harness; duplicates around a crash are possible. A polling watcher observes
  transitions, not every transient process exit. `untrack/1` removes a completed watch,
  never the child's worktree. `poll/0` forces a scan without a model turn.

  `start_link/1` accepts `:name`, `:root`, `:poll_ms` (default 1000), and `:agent_module`
  (default NanoAgent, implementing info/1, whereis/1, notify/2). `:boot_grace_ms` defaults
  to 5000: absent children are not reported down until boot revival has had that grace.
  A supervisor may adopt the existing lazily-started default watcher with start_link/1;
  an already supervised watcher is never adopted twice. Overrides support isolated
  tests/embeddings, without changing application-global settings.
  """
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.start_link(__MODULE__, opts, name: name) do
      {:error, {:already_started, pid}} = error ->
        case GenServer.call(pid, {:adopt, self()}) do
          :ok -> {:ok, pid}
          :already_supervised -> error
        end

      result ->
        result
    end
  end

  @doc "Compatibility fallback; boot supervision is required for unattended recovery."
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [lazy: true], name: __MODULE__) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          error -> error
        end

      _ ->
        :ok
    end
  end

  def track(record, server \\ __MODULE__), do: GenServer.call(server, {:track, record})
  def untrack(name, server \\ __MODULE__), do: GenServer.call(server, {:untrack, name})
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll)

  @impl true
  def init(opts) do
    default_root =
      Application.get_env(:nano, :state_dir, "/data/state")
      |> Path.dirname()
      |> Path.join("delegation")

    root = Keyword.get(opts, :root, Application.get_env(:nano, :delegation_dir, default_root))
    interval = Keyword.get(opts, :poll_ms, 1000)
    grace = Keyword.get(opts, :boot_grace_ms, 5000)

    with :ok <- File.mkdir_p(root),
         true <- is_integer(interval) and interval > 0 and is_integer(grace) and grace >= 0 do
      records =
        for file <- Path.wildcard(Path.join(root, "*.json")),
            {:ok, record} <- [load(file)],
            into: %{},
            do: {record["name"], record}

      timer = Process.send_after(self(), :poll, interval)

      {:ok,
       %{
         root: root,
         interval: interval,
         records: records,
         timer: timer,
         lazy: Keyword.get(opts, :lazy, false),
         down_after: System.monotonic_time(:millisecond) + grace,
         agent: Keyword.get(opts, :agent_module, NanoAgent)
       }}
    else
      false -> {:stop, :invalid_poll_interval}
      {:error, reason} -> {:stop, {:watch_directory, reason}}
    end
  end

  @impl true
  def handle_call({:adopt, supervisor}, _, state) do
    state = upgrade(state)

    if state.lazy do
      Process.link(supervisor)
      {:reply, :ok, %{state | lazy: false}}
    else
      {:reply, :already_supervised, state}
    end
  end

  def handle_call({:track, record}, _, state) do
    state = upgrade(state)

    with {:ok, encoded} <- Jason.encode(record),
         {:ok, r} <- Jason.decode(encoded),
         true <- valid_record?(r) do
      status =
        case safe_info(state.agent, r["name"]) do
          {:ok, %{pid: pid, halted: nil} = info} when not is_nil(pid) -> status(info)
          _ -> nil
        end

      r = r |> Map.put("status", status) |> Map.put("pending", [])

      case persist(state.root, r) do
        :ok -> {:reply, :ok, put_in(state.records[r["name"]], r)}
        error -> {:reply, error, state}
      end
    else
      _ -> {:reply, {:error, :invalid_watch_record}, state}
    end
  end

  def handle_call({:untrack, name}, _, state) do
    if Delegation.safe_name?(name) do
      case File.rm(path(state.root, name)) do
        result when result in [:ok, {:error, :enoent}] ->
          {:reply, :ok, %{state | records: Map.delete(state.records, name)}}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :invalid_name}, state}
    end
  end

  def handle_call(:poll, _, state), do: {:reply, :ok, scan(state)}

  @impl true
  def handle_info(:poll, state) do
    next = scan(state)
    timer = Process.send_after(self(), :poll, next.interval)
    {:noreply, %{next | timer: timer}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp scan(state) do
    state = upgrade(state)

    records =
      Map.new(state.records, fn {name, record} ->
        next =
          case safe_info(state.agent, name) do
            {:ok, info} ->
              observed = status(info)

              if observed == "down" and System.monotonic_time(:millisecond) < state.down_after,
                do: record,
                else: transition(record, observed)

            {:error, _} ->
              record
          end

        # Queue durably before sending, so a crash cannot forget an observed transition.
        next = if next == record or persist(state.root, next) == :ok, do: next, else: record
        {name, deliver(next, state)}
      end)

    %{state | records: records}
  end

  # Upgrade the initial foundation's unlinked watcher on the first callback after reload.
  # Its JSON records already have the same core fields, but no pending queue.
  defp upgrade(%{agent: _, lazy: _, down_after: _} = state), do: state

  defp upgrade(state) do
    state
    |> Map.put_new(:agent, NanoAgent)
    |> Map.put_new(:lazy, true)
    |> Map.put_new(:interval, 1000)
    |> Map.put_new(:timer, nil)
    |> Map.put_new(:down_after, System.monotonic_time(:millisecond) + 5000)
    |> Map.update!(:records, fn records ->
      Map.new(records, fn {name, record} -> {name, Map.put_new(record, "pending", [])} end)
    end)
  end

  defp status(nil), do: "down"
  defp status(%{pid: nil}), do: "down"
  defp status(%{halted: reason}) when reason != nil, do: "halted:#{reason}"
  defp status(%{pid: pid} = info), do: "alive:#{inspect(pid)}:#{Map.get(info, :restart_count, 0)}"

  defp transition(record, status) do
    previous = record["status"]
    next = Map.put(record, "status", status)

    if not same_status?(previous, status) and
         (previous != nil or not String.starts_with?(status, "alive:")) do
      type =
        cond do
          status == "down" -> "down"
          String.starts_with?(status, "halted:") -> "halted"
          true -> "restarted"
        end

      Map.update!(next, "pending", &(&1 ++ [%{"type" => type, "status" => status}]))
    else
      next
    end
  end

  # The first watcher stored alive:<pid> without a restart counter. Upgrade that
  # observation silently when the pid is unchanged; a different pid still is a restart.
  defp same_status?(status, status), do: true

  defp same_status?(previous, current) when is_binary(previous) do
    Regex.match?(~r/^alive:#PID<[^>]+>$/, previous) and
      String.starts_with?(current, previous <> ":")
  end

  defp same_status?(_, _), do: false

  defp deliver(%{"pending" => []} = record, _), do: record

  defp deliver(record, state) do
    if state.agent.whereis(record["parent"]) do
      Enum.each(record["pending"], fn event ->
        type =
          case event["type"] do
            "down" -> :down
            "halted" -> :halted
            "restarted" -> :restarted
          end

        state.agent.notify(
          record["parent"],
          {:delegation, record["name"], type,
           %{status: event["status"], directory: record["directory"]}}
        )
      end)

      next = Map.put(record, "pending", [])
      if persist(state.root, next) == :ok, do: next, else: record
    else
      record
    end
  rescue
    _ -> record
  catch
    _, _ -> record
  end

  defp safe_info(agent, name) do
    {:ok, agent.info(name)}
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp load(file) do
    with {:ok, text} <- File.read(file),
         {:ok, record} <- Jason.decode(text),
         true <- valid_record?(record),
         true <- Path.basename(file) == record["name"] <> ".json" do
      {:ok, Map.put_new(record, "pending", [])}
    else
      _ ->
        Logger.warning("Delegation.Watcher skipped invalid record #{file}")
        {:error, :invalid_record}
    end
  end

  defp valid_record?(r) when is_map(r) do
    Delegation.safe_name?(r["name"]) and Delegation.safe_name?(r["parent"]) and
      is_binary(r["directory"]) and is_binary(r["revision"]) and
      (is_nil(r["status"]) or is_binary(r["status"])) and
      is_list(Map.get(r, "pending", [])) and
      Enum.all?(Map.get(r, "pending", []), fn
        %{"type" => type, "status" => status} ->
          type in ["down", "halted", "restarted"] and is_binary(status)

        _ ->
          false
      end)
  end

  defp valid_record?(_), do: false

  defp path(root, name), do: Path.join(root, name <> ".json")

  defp persist(root, record) do
    file = path(root, record["name"])
    tmp = file <> ".#{System.unique_integer([:positive])}.tmp"

    result =
      with :ok <- File.write(tmp, Jason.encode!(record), [:binary, :sync]),
           :ok <- File.rename(tmp, file),
           do: :ok

    if result != :ok do
      File.rm(tmp)
      Logger.warning("Delegation.Watcher could not persist #{file}: #{inspect(result)}")
    end

    result
  end
end

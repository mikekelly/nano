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
      # Tool schemas belong in the child context, not in the parent's eval result.
      handle =
        Map.update!(handle, :mcp, fn entries ->
          Enum.map(entries, fn
            entry when is_map(entry) -> Map.drop(entry, [:tools, :use])
            entry -> entry
          end)
        end)

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
          finish(
            handle,
            %{
              delegation: :failure,
              id: id,
              from: name,
              reply_to: parent,
              kind: :start,
              reason: inspect(error)
            },
            Keyword.put(opts, :adapter, adapter)
          )

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
        "Workspace: #{inspect(handle.workspace)}. MCP: #{inspect(handle.mcp, limit: :infinity, printable_limit: :infinity)}.",
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
    finish(handle, %{
      delegation: :result,
      id: handle.id,
      from: handle.name,
      reply_to: handle.parent,
      result: summary
    })
  end

  @doc "Acknowledge a result/failure after saving/processing it. Retries carry the same receipt."
  def ack(%{receipt: receipt}) do
    if File.exists?(manifest_path(receipt.id, receipt[:storage_dir])) do
      with {:ok, watcher} <- watch(receipt) do
        GenServer.call(watcher, {:ack, receipt.delivery_id})
      end
    else
      :ok
    end
  end

  defp finish(handle, term, opts \\ []) do
    with {:ok, watcher} <- watch(handle, opts) do
      GenServer.call(watcher, {:complete, term})
    end
  end

  @doc "Persist and watch a handle; restart watchers after node restart with restore/1."
  def watch(handle, opts \\ []) do
    handle = Map.put_new(handle, :storage_dir, opts[:storage_dir] || default_storage())
    adapter = opts[:adapter] || NanoAgent
    path = manifest_path(handle.id, handle[:storage_dir])

    case watcher_lookup(handle.id, 100) do
      {:ok, pid} ->
        {:ok, pid}

      :missing ->
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- initialize_manifest(path, handle) do
          case Nano.Delegation.Watcher.start(handle, adapter, opts) do
            {:error, {:already_started, _pid}} ->
              # Registration can race another restore; recheck rather than return a stale pid.
              watch(handle, opts)

            result ->
              result
          end
        end

      error ->
        error
    end
  end

  @doc "Resume durable lifecycle watches. Run at boot or from a successor's eval; no model calls."
  def restore(opts \\ []) do
    dir = opts[:storage_dir] || default_storage()

    for path <- Path.wildcard(Path.join(dir, "*.term")) do
      restore_manifest(path, opts)
    end
  end

  defp watcher_lookup(id, retries) do
    case Registry.lookup(Nano.Registry, {:delegation, id}) do
      [] ->
        :missing

      [{pid, _}] ->
        cond do
          Process.alive?(pid) ->
            {:ok, pid}

          retries > 0 ->
            Process.sleep(1)
            watcher_lookup(id, retries - 1)

          true ->
            {:error, :stale_watcher_registration}
        end
    end
  end

  defp initialize_manifest(path, handle) do
    case File.write(path, :erlang.term_to_binary(Map.drop(handle, [:pid, :watcher])), [:exclusive]) do
      {:error, :eexist} -> :ok
      result -> result
    end
  end

  defp restore_manifest(path, opts) do
    with {:ok, binary} <- File.read(path),
         %{id: id, name: name, parent: parent} = handle <- :erlang.binary_to_term(binary, [:safe]),
         true <- is_binary(id) and is_binary(name) and is_binary(parent) do
      {name, watch(Map.put(handle, :storage_dir, Path.dirname(path)), opts)}
    else
      _ -> {path, {:error, :invalid_manifest}}
    end
  rescue
    _ -> {path, {:error, :invalid_manifest}}
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
        connect_mcp(name, servers, opts)
    end
  end

  defp connect_mcp(name, servers, opts) do
    adapter = opts[:mcp_adapter] || Nano.MCP
    cap = opts[:mcp_max_bytes] || 32_768

    if Code.ensure_loaded?(adapter) do
      Enum.reduce_while(servers, {:ok, []}, fn descriptor, {:ok, handles} ->
        case connect_mcp_server(adapter, name, descriptor, cap) do
          {:ok, handle} ->
            handles = handles ++ [handle]

            if byte_size(:erlang.term_to_binary(handles)) <= cap,
              do: {:cont, {:ok, handles}},
              else:
                {:halt, {:error, "MCP metadata exceeds #{cap} bytes; select fewer tools/servers"}}

          error ->
            {:halt, error}
        end
      end)
    else
      {:error, "Nano.MCP is not loaded; omit mcp or provide mcp_setup callback"}
    end
  end

  defp connect_mcp_server(adapter, child, descriptor, cap) do
    {server, config} =
      case descriptor do
        name when is_binary(name) -> {name, []}
        {name, config} when is_binary(name) and is_list(config) -> {name, config}
        _ -> {nil, []}
      end

    if server do
      subscriptions = Keyword.get(config, :subscribe, [])
      connect_opts = config |> Keyword.delete(:subscribe) |> Keyword.put(:recipient, child)

      with {:ok, _pid} <- apply(adapter, :connect, [server, connect_opts]),
           :ok <- apply(adapter, :watch, [server, child]),
           {:ok, status} <- apply(adapter, :status, [server]),
           {:ok, tools} <- mcp_tools(adapter, server, status, cap),
           :ok <- mcp_subscriptions(adapter, server, subscriptions, child) do
        {:ok,
         %{
           name: server,
           capabilities: status[:capabilities] || %{},
           tools: tools,
           use:
             "Nano.MCP.call_tool(#{inspect(server)}, tool_name, arguments); see Nano.MCP module docs"
         }}
      else
        _ ->
          {:error,
           "MCP setup failed for #{server}; inspect Nano.MCP.status/1 (credentials are not included in delegation errors)"}
      end
    else
      {:error, "mcp entries must be configured server names or {name, keyword_options}"}
    end
  end

  defp mcp_tools(adapter, server, status, cap) do
    if Map.has_key?(status[:capabilities] || %{}, "tools"),
      do: mcp_tool_pages(adapter, server, cap, [], nil, MapSet.new()),
      else: {:ok, []}
  end

  defp mcp_tool_pages(adapter, server, cap, acc, cursor, seen) do
    opts = [max_bytes: cap] ++ if(cursor, do: [cursor: cursor], else: [])

    case apply(adapter, :tools, [server, opts]) do
      {:ok, %{"tools" => tools} = result} when is_list(tools) ->
        all = acc ++ tools
        next = result["nextCursor"]

        cond do
          byte_size(:erlang.term_to_binary(all)) > cap -> {:error, :too_large}
          is_nil(next) -> {:ok, all}
          MapSet.member?(seen, next) or MapSet.size(seen) >= 20 -> {:error, :pagination_loop}
          true -> mcp_tool_pages(adapter, server, cap, all, next, MapSet.put(seen, next))
        end

      _ ->
        {:error, :tool_listing_failed}
    end
  end

  defp mcp_subscriptions(adapter, server, uris, child) do
    Enum.reduce_while(uris, :ok, fn uri, :ok ->
      case apply(adapter, :subscribe, [server, uri, child]) do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
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
    path = Path.join(handle.storage_dir, handle.id <> ".term")
    {:ok, binary} = File.read(path)
    saved = :erlang.binary_to_term(binary, [:safe]) |> Map.put(:storage_dir, handle.storage_dir)
    terminal = saved[:terminal] || false
    pid = if not terminal, do: adapter.whereis(handle.name)
    ref = if pid, do: Process.monitor(pid)
    interval = opts[:poll_ms] || 250
    Process.send_after(self(), :poll, interval)

    {:ok,
     %{
       handle: Map.drop(saved, [:pending, :terminal, :last]),
       adapter: adapter,
       ref: ref,
       interval: interval,
       last: saved[:last],
       pending: saved[:pending] || [],
       terminal: terminal,
       path: path,
       retry_ms: opts[:retry_ms] || 5000,
       next_delivery: 0,
       dirty: false
     }}
  end

  def handle_call({:complete, term}, _from, s) do
    if s.ref, do: Process.demonitor(s.ref, [:flush])
    # Persist before replying to the child's eval. Its subsequent exit cannot race this.
    s = %{s | terminal: true, ref: nil, dirty: true} |> enqueue(term)

    case persist(s) do
      :ok -> {:reply, :ok, deliver(%{s | dirty: false})}
      error -> {:reply, error, s}
    end
  end

  def handle_call({:ack, id}, _from, s) do
    original = s
    s = %{s | pending: Enum.reject(s.pending, &(&1.receipt.delivery_id == id))}

    case persist(s) do
      :ok ->
        if s.terminal and s.pending == [] do
          File.rm(s.path)
          {:stop, :normal, :ok, s}
        else
          {:reply, :ok, %{s | dirty: false}}
        end

      error ->
        {:reply, error, original}
    end
  end

  # Administrative cancellation, not used by reply (tests and explicit cleanup only).
  def handle_info(:complete, s) do
    File.rm(s.path)
    {:stop, :normal, s}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{ref: ref, terminal: false} = s) do
    s = %{s | ref: nil} |> failure(:exit, inspect(reason))
    {:noreply, durable_deliver(s)}
  end

  def handle_info({:DOWN, _, :process, _, _}, s), do: {:noreply, s}

  def handle_info(:poll, s) do
    s =
      if s.terminal do
        s
      else
        info = s.adapter.info(s.handle.name)
        halted = if info, do: info[:halted], else: :missing
        s = if halted && halted != s.last, do: failure(s, :halted, halted), else: s
        s = %{s | last: halted, dirty: s.dirty or halted != s.last}

        if s.ref == nil do
          case s.adapter.whereis(s.handle.name) do
            nil -> s
            pid -> %{s | ref: Process.monitor(pid)}
          end
        else
          s
        end
      end

    Process.send_after(self(), :poll, s.interval)
    {:noreply, durable_deliver(s)}
  end

  defp failure(s, kind, reason),
    do:
      enqueue(
        s,
        %{
          delegation: :failure,
          id: s.handle.id,
          from: s.handle.name,
          reply_to: s.handle.parent,
          kind: kind,
          reason: reason
        }
      )

  defp enqueue(s, term) do
    # Retrying a terminal reply must not create duplicate terminal entries.
    if Enum.any?(s.pending, &(Map.drop(&1, [:receipt]) == term)) do
      s
    else
      receipt =
        Map.take(s.handle, [:id, :name, :parent, :storage_dir])
        |> Map.put(:delivery_id, Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))

      %{
        s
        | pending: s.pending ++ [Map.put(term, :receipt, receipt)],
          next_delivery: 0,
          dirty: true
      }
    end
  end

  defp durable_deliver(%{dirty: true} = s) do
    case persist(s) do
      :ok -> deliver(%{s | dirty: false})
      _ -> s
    end
  end

  defp durable_deliver(s), do: deliver(s)

  defp deliver(s) do
    now = System.monotonic_time(:millisecond)

    if s.pending != [] and (s.next_delivery == 0 or now >= s.next_delivery) and
         s.adapter.whereis(s.handle.parent) != nil do
      Enum.each(s.pending, &s.adapter.notify(s.handle.parent, &1))
      %{s | next_delivery: now + s.retry_ms}
    else
      s
    end
  end

  defp persist(s) do
    saved = Map.merge(s.handle, %{pending: s.pending, terminal: s.terminal, last: s.last})
    tmp = s.path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(tmp, :erlang.term_to_binary(saved)),
         :ok <- File.rename(tmp, s.path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end
end

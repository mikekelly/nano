defmodule Delegation do
  @moduledoc """
  Compose and start isolated children. Example:
  `subagent("scout", task: "Inspect", revision: "HEAD", model: "openai-codex/gpt-6.1-sol", reasoning: "low", max_context: 272000, max_turns: 100, max_tokens: 0)`.
  `worktree: true` creates /tmp/<name>/checkout on seedling/rigel-<name>.
  `pre: [paths]` supplies bounded file contents and SHA256 hashes.
  Parent receives `{:delegation, name, :result, text}`, `:halted` with reason,
  `:down` with exit reason, and `{:delegation, name, :restarted, new_pid}`.
  Relationships and pending lifecycle notices are persisted under /data/delegation.
  Call restore/0 from the application after Names and StateStore start. Notifications
  are at-least-once on recovery, not acknowledged end-to-end; result reports are live sends.
  Children call `Delegation.report(parent_name, text)`; address by name survives restarts.
  """
  def compose(parts, job) when is_list(parts) and length(parts) <= 16 and is_binary(job) do
    if Enum.all?(parts, &(is_binary(&1) and Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, &1))) do
      paths = ["/app/priv/system_prompt.txt" | Enum.map(parts, &"/app/priv/partials/#{&1}.md")]

      with {:ok, texts} <- load_parts(paths),
           true <- byte_size(job) + Enum.reduce(texts, 0, &(byte_size(&1) + &2)) <= 96000 do
        {:ok, Regex.replace(~r/\{\{!.*?\}\}/s, Enum.join(texts ++ [job], "\n"), "")}
      else
        false -> {:error, "composed prompt exceeds 96000 bytes"}
        error -> error
      end
    else
      {:error, "partial names must contain only letters, digits, underscores or hyphens"}
    end
  end

  def compose(_, _), do: {:error, "compose requires at most 16 partials and a string job"}

  defp load_parts(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, texts} ->
      case bounded_read(path) do
        {:ok, text} -> {:cont, {:ok, texts ++ [text]}}
        error -> {:halt, error}
      end
    end)
  end

  defp bounded_read(path) do
    with {:ok, %{type: :regular, size: size}} when size <= 24000 <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(io, 24001) do
          :eof ->
            {:ok, ""}

          text when is_binary(text) and byte_size(text) <= 24000 ->
            if String.valid?(text), do: {:ok, text}, else: {:error, "file is not UTF-8"}

          _ ->
            {:error, "file exceeds 24000 bytes"}
        end
      after
        File.close(io)
      end
    else
      _ -> {:error, "#{inspect(path)} must be a regular file of at most 24000 bytes"}
    end
  end

  def subagent(name, opts) do
    parent = Keyword.get(opts, :parent) || caller_name()
    cwd = if opts[:worktree], do: "/tmp/#{name}/checkout", else: "/app"

    with :ok <- validate(name, opts, parent),
         {:ok, pre} <- preread(Keyword.get(opts, :pre, [])),
         {:ok, prompt} <-
           compose(
             Keyword.get(opts, :parts, ["operating", "orientation"]),
             "Your parent is #{parent}. Work in #{cwd}, revision #{opts[:revision]}. Own only your task files. Report with Delegation.report(#{inspect(parent)}, text). Task: #{opts[:task]}"
           ),
         {:ok, cwd} <- checkout(name, opts),
         {:ok, pid} <-
           NanoAgent.start(
             Keyword.take(opts, [:model, :reasoning, :max_turns, :max_tokens, :max_context]) ++
               [name: name, system_prompt: prompt <> "\nPre-reading:\n" <> pre, start_idle: true]
           ) do
      monitoring = monitor(name, parent)

      unless opts[:start_idle],
        do: send(pid, %{message: "Task: #{opts[:task]}\n" <> pre, parent_name: parent})

      case monitoring do
        :ok -> {:ok, %{name: name, pid: pid, cwd: cwd}}
        error -> {:error, %{monitoring: error, child: %{name: name, pid: pid, cwd: cwd}}}
      end
    else
      false -> {:error, "revision is required, even for read-only jobs"}
      error -> error
    end
  end

  def report(parent, text) when is_binary(parent) and is_binary(text) do
    case NanoAgent.whereis(parent) do
      nil -> {:error, "parent is not running"}
      pid -> send(pid, {:delegation, caller_name(), :result, text})
    end
  end

  defp caller_name do
    pid = List.first(Process.get(:"$callers", [])) || self()

    Enum.find_value(Nano.Names.all(), fn {{kind, name}, p} ->
      if kind == :agent and p == pid, do: name
    end)
  end

  defp checkout(name, opts) do
    if opts[:worktree] do
      path = "/tmp/#{name}/checkout"

      args = ["git", "worktree", "add", "-b", "seedling/rigel-#{name}", path, opts[:revision]]

      command =
        Enum.map_join(args, " ", fn arg -> "'" <> String.replace(arg, "'", "'\\''") <> "'" end)

      case SeedTools.sh(command, cwd: "/app", timeout: 30000) do
        %{status: 0} -> {:ok, path}
        %{output: text, full_output: full} -> {:error, "#{text}\nFull git output: #{full}"}
        error -> error
      end
    else
      {:ok, "/app"}
    end
  end

  @doc "Validate options without creating a worktree or starting a child."
  def validate(name, opts, parent) do
    cond do
      Keyword.get(opts, :mcp, []) not in [nil, []] ->
        {:error, "Delegation MCP startup is not configured; refusing to ignore mcp servers"}

      not is_binary(name) or not Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,100}\z/, name) ->
        {:error, "name must be 1..101 safe letters, digits, underscores or hyphens"}

      not is_binary(parent) or parent == "" ->
        {:error, "a named parent is required"}

      not is_binary(opts[:revision]) or opts[:revision] == "" or
          String.starts_with?(opts[:revision], "-") ->
        {:error, "revision is required, even for read-only jobs, and may not start with '-'"}

      not is_binary(opts[:task]) or String.trim(opts[:task]) == "" ->
        {:error, "task must be nonempty text"}

      not is_binary(opts[:model]) or not is_binary(opts[:reasoning]) ->
        {:error, "model and reasoning are required strings"}

      not Enum.all?(
        [:max_turns, :max_tokens, :max_context],
        &(is_integer(opts[&1]) and opts[&1] >= 0)
      ) ->
        {:error, "max_turns, max_tokens and max_context are required nonnegative integers"}

      opts[:max_context] != 0 and opts[:max_context] < 32768 ->
        {:error, "max_context must leave room for compaction (at least 32768), or 0"}

      true ->
        :ok
    end
  end

  @doc "Bounded pre-reading: at most 16 regular files, 24000 bytes each, 96000 bytes total."
  def preread(paths) when is_list(paths) and length(paths) <= 16 do
    Enum.reduce_while(paths, {:ok, ""}, fn path, {:ok, acc} ->
      with true <- is_binary(path),
           {:ok, %{type: :regular, size: size}} when size <= 24000 <- File.stat(path),
           {:ok, text} <- bounded_read(path),
           true <- String.valid?(text) do
        hash = Base.encode16(:crypto.hash(:sha256, text), case: :lower)
        next = acc <> "\nFile #{path} sha256=#{hash}\n" <> text

        if byte_size(next) <= 96000,
          do: {:cont, {:ok, next}},
          else: {:halt, {:error, "pre-reading exceeds 96000 aggregate bytes"}}
      else
        _ ->
          {:halt,
           {:error,
            "pre-read #{inspect(path)} must be a regular UTF-8 file of at most 24000 bytes"}}
      end
    end)
  end

  def preread(_), do: {:error, "pre-reading requires at most 16 file paths"}

  @doc "Persist a child-parent relationship and watch name-based restarts. Call restore/0 at boot."
  def monitor(name, parent) do
    dir = monitor_dir()

    with :ok <- File.mkdir_p(dir),
         :ok <-
           File.write(
             Path.join(dir, safe_key(name) <> ".json"),
             Jason.encode!(%{name: name, parent: parent})
           ) do
      start_watch(name, parent)
      :ok
    end
  end

  @doc "Restore persisted monitors after a node restart; idempotent in this node."
  def restore do
    Path.wildcard(Path.join(monitor_dir(), "*.json"))
    |> Enum.map(fn path ->
      with {:ok, text} <- File.read(path),
           {:ok, %{"name" => name, "parent" => parent}} <- Jason.decode(text),
           true <- is_binary(name) and is_binary(parent) do
        start_watch(name, parent)
        :ok
      else
        _ -> {:error, path}
      end
    end)
  end

  defp monitor_dir do
    Application.get_env(
      :nano,
      :delegation_dir,
      Path.join(Application.get_env(:nano, :test_dir, "/data"), "delegation")
    )
  end

  defp safe_key(name), do: Base.encode16(:crypto.hash(:sha256, name), case: :lower)

  defp start_watch(name, parent) do
    spawn(fn ->
      case :global.register_name({__MODULE__, name}, self()) do
        :yes -> supervise_watch(name, parent)
        :no -> :ok
      end
    end)
  end

  defp supervise_watch(name, parent) do
    Process.flag(:trap_exit, true)

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          queue = load_queue(name)

          queue =
            if NanoAgent.whereis(name),
              do: queue,
              else: queue ++ [{:delegation, name, :down, :not_running}]

          watch(name, parent, nil, nil, queue)
        end,
        [
          :link,
          :monitor
        ]
      )

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        receive do
          {:EXIT, ^pid, _} -> :ok
        after
          0 -> :ok
        end

        Process.sleep(1000)
        supervise_watch(name, parent)
    end
  end

  defp watch(name, parent, previous_pid, previous_halt, queue) do
    pid = NanoAgent.whereis(name)
    ref = if pid, do: Process.monitor(pid)
    info = NanoAgent.info(name)
    halted = info && info.halted

    queue =
      if pid && previous_pid && pid != previous_pid,
        do: queue ++ [{:delegation, name, :restarted, pid}],
        else: queue

    queue =
      if halted && halted != previous_halt,
        do: queue ++ [{:delegation, name, :halted, halted}],
        else: queue

    queue = deliver(name, parent, queue)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} when not is_nil(ref) ->
        queue = deliver(name, parent, queue ++ [{:delegation, name, :down, reason}])
        await_restart(name, parent, pid, halted, queue)
    after
      1000 ->
        if ref, do: Process.demonitor(ref, [:flush])
        watch(name, parent, pid || previous_pid, halted, queue)
    end
  end

  defp await_restart(name, parent, previous_pid, halted, queue) do
    Process.sleep(1000)
    queue = deliver(name, parent, queue)

    if NanoAgent.whereis(name) do
      watch(name, parent, previous_pid, halted, queue)
    else
      await_restart(name, parent, previous_pid, halted, queue)
    end
  end

  defp deliver(name, parent, queue) do
    persist_queue(name, queue)

    result =
      case NanoAgent.whereis(parent) do
        nil ->
          queue

        target ->
          Enum.each(queue, &send(target, &1))
          []
      end

    if result == [] and queue != [], do: persist_queue(name, [])
    result
  end

  defp queue_path(name), do: Path.join(monitor_dir(), safe_key(name) <> ".queue")

  defp persist_queue(name, queue) do
    path = queue_path(name)

    with :ok <- File.write(path <> ".tmp", :erlang.term_to_binary(queue)),
         do: File.rename(path <> ".tmp", path)
  end

  defp load_queue(name) do
    case File.read(queue_path(name)) do
      {:ok, binary} -> :erlang.binary_to_term(binary, [:safe])
      _ -> []
    end
  rescue
    _ -> []
  end
end

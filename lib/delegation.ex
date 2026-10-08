defmodule Delegation do
  @moduledoc """
  Start fitted, watched children from one eval. Required options: `model`, `reasoning`,
  `max_turns`, `max_tokens`, `max_context`, `revision` (explicit git commit/ref even for
  read-only tasks), and `task`. `worktree: true` isolates edits (default); `pre: [paths]`
  supplies hash-marked pre-reading. `parts:` defaults to principles/orientation/builder.
  `message: nil` starts idle; otherwise task is sent by default.

      Delegation.subagent("scout", revision: "COMMIT", task: "Review ...",
        model: "openai-codex/gpt-6-astra", reasoning: "low",
        max_turns: 100, max_tokens: 0, max_context: 272000)

  Child reports with `Delegation.report(parent_name, result)`. Parent receives
  `{:delegation, child_name, :result, result}`; watcher sends `:halted`, `:down`, and
  `:restarted` with details. Names survive restarts. Idle tool waits without model turns.
  Reports should be concise, results not transcripts. Polling watches survive node restart
  via records on disk. Worktrees are retained for review, never automatically deleted.
  """
  def compose(parts, job) do
    with {:ok, seed} <- File.read("/app/prompts/seed.txt") do
      Enum.reduce_while(parts, {:ok, seed}, fn part, {:ok, acc} ->
        case File.read("/app/prompts/partials/#{part}.md") do
          {:ok, text} -> {:cont, {:ok, acc <> "\n" <> text}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, text} -> {:ok, Regex.replace(~r/\{\{!.*?\}\}/s, text <> "\n" <> job, "")}
        error -> error
      end
    end
  end

  def subagent(name, opts) do
    required = [:revision, :task, :model, :reasoning, :max_turns, :max_tokens, :max_context]

    with nil <- Enum.find(required, &is_nil(opts[&1])),
         true <- is_binary(name) and name =~ ~r/^[\w.-]+$/,
         {:ok, parent} <- caller_name(),
         {:ok, revision} <- git(["rev-parse", "--verify", opts[:revision] <> "^{commit}"]),
         {:ok, pre} <- preread(opts[:pre] || []),
         {:ok, directory} <- worktree(name, revision, opts),
         {:ok, prompt} <-
           compose(
             opts[:parts] || ["principles", "orientation", "builder"],
             "Your parent is #{parent}. Report with Delegation.report(#{inspect(parent)}, result). Your work directory: #{directory}. Starting revision: #{revision}. Task: #{opts[:task]}\n" <>
               pre
           ),
         {:ok, pid} <-
           NanoAgent.start(
             Keyword.take(opts, [:model, :reasoning, :max_turns, :max_tokens, :max_context]) ++
               [name: name, system_prompt: prompt, start_idle: true]
           ) do
      Delegation.Watcher.track(%{
        name: name,
        parent: parent,
        pid: inspect(pid),
        directory: directory,
        revision: revision
      })

      if Keyword.get(opts, :message, :task) != nil do
        NanoAgent.notify(name, %{
          sender_name: parent,
          message: opts[:message] || opts[:task],
          worktree: directory
        })
      end

      {:ok, %{name: name, pid: pid, directory: directory, revision: revision}}
    else
      missing when is_atom(missing) and missing != false ->
        {:error, "missing required option #{missing}"}

      false ->
        {:error, :invalid_name}

      error ->
        error
    end
  end

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

  def report(parent, result) do
    with {:ok, name} <- caller_name() do
      NanoAgent.notify(parent, {:delegation, name, :result, result})
      :ok
    end
  end

  defp preread(paths) do
    Enum.reduce_while(paths, {:ok, ""}, fn path, {:ok, acc} ->
      case File.read(path) do
        {:ok, text} when byte_size(text) + byte_size(acc) <= 80_000 ->
          hash = Base.encode16(:crypto.hash(:sha256, text), case: :lower)
          {:cont, {:ok, acc <> "\nPre-reading #{path} SHA256 #{hash}:\n" <> text}}

        {:ok, _} ->
          {:halt, {:error, :prereading_over_80000_bytes}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp worktree(name, revision, opts) do
    if Keyword.get(opts, :worktree, true) do
      directory = "/data/worktrees/#{name}"

      with {:ok, _} <-
             git(["worktree", "add", "-b", "seedling/deneb-#{name}", directory, revision]) do
        # Dependencies are immutable; builds stay local with MIX_ENV=test.
        File.ln_s("/app/deps", Path.join(directory, "deps"))
        {:ok, directory}
      end
    else
      {:ok, "/app (read-only)"}
    end
  end

  defp git(args) do
    case System.cmd("git", ["-C", "/app" | args], stderr_to_stdout: true) do
      {text, 0} -> {:ok, String.trim(text)}
      {text, n} -> {:error, {:git, n, text}}
    end
  end
end

defmodule Delegation.Watcher do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def track(record) do
    ensure_started()
    GenServer.call(__MODULE__, {:track, record})
  end

  defp ensure_started do
    if Process.whereis(__MODULE__) == nil do
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end

  def init(_) do
    Process.send_after(self(), :poll, 1000)
    root = Application.get_env(:nano, :delegation_dir, "/data/delegation")
    File.mkdir_p!(root)

    records =
      for file <- Path.wildcard(root <> "/*.json"),
          {:ok, text} <- [File.read(file)],
          {:ok, r} <- [Jason.decode(text)],
          into: %{},
          do: {r["name"], r}

    {:ok, %{root: root, records: records}}
  end

  def handle_call({:track, record}, _, s) do
    r = record |> Jason.encode!() |> Jason.decode!()
    File.write!(Path.join(s.root, r["name"] <> ".json"), Jason.encode!(r))
    {:reply, :ok, %{s | records: Map.put(s.records, r["name"], r)}}
  end

  def handle_info(:poll, s) do
    records =
      Map.new(s.records, fn {name, r} ->
        info = NanoAgent.info(name)

        status =
          cond do
            info == nil or info.pid == nil -> "down"
            info.halted != nil -> "halted:#{info.halted}"
            true -> "alive:#{inspect(info.pid)}"
          end

        if r["status"] != status and
             (r["status"] != nil or not String.starts_with?(status, "alive:")) do
          type =
            cond do
              status == "down" -> :down
              String.starts_with?(status, "halted:") -> :halted
              true -> :restarted
            end

          NanoAgent.notify(
            r["parent"],
            {:delegation, name, type, %{status: status, directory: r["directory"]}}
          )
        end

        next = Map.put(r, "status", status)
        if next != r, do: File.write(Path.join(s.root, name <> ".json"), Jason.encode!(next))
        {name, next}
      end)

    Process.send_after(self(), :poll, 1000)
    {:noreply, %{s | records: records}}
  end
end

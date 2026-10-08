defmodule Seedling.Delegation do
  @moduledoc """
  Composable agent starts, bounded hashed pre-reading and explicit git worktrees.

      subagent("scout", model: "provider/model", reasoning: "low",
        max_turns: 40, max_tokens: 200_000, max_context: 100_000,
        prompt: "Investigate X", flavour: :scout, pre: ["/app/NOTES.md"],
        parent: "planner", message: "Begin")

  No model, reasoning, budget or worktree revision defaults. `worktree:` is optional;
  if present use `[path: "/tmp/job", revision: "COMMIT", branch: "seedling/job"]`.
  `repo:` defaults to `/app`; worktrees are never deleted automatically. Build in the
  returned path with MIX_ENV=test and a unique MIX_BUILD_ROOT (seed Mix isolates test
  builds in the checkout). Pre entries may be paths or `{path, offset: 1, limit: 100}`.
  Oversized pre-reading is rejected rather than silently truncated. Hashes describe
  full files and included excerpts. `changed?/1` rechecks a manifest entry.

  A start runs directly in the calling eval, preserving NanoAgent's `started_by`.
  Parent defaults to that eval's caller's agent name; outside an agent supply `parent:`
  (a stable agent name or a pid). Start is idle until `message:` is delivered, so all
  pre-reading and optional `mcp: ["server"]` connections precede the first turn. Events are held across all servers until ready;
  `mcp_options:` supplies shared connection options such as an isolated `instance:`.
  A constructor-task monitor terminates and reports half-setup children on task death.
  `start_idle: false` supplies a standard kickoff if there is no message.

  Child: `report(child_name, summary)`; parent: call the harness `idle` tool, no
  polling turns required. Receives `%{type: :delegation, child:, child_id:, status:,
  summary:, sender_pid:, sender_name:}`. Status is `:ok`, `:error`, `:halted`,
  `:exited` or `:restarted`; exits are warnings even if the harness restarts the child.
  Reports are capped at 8KB. Addresses are names so agent restarts do not break them.
  Failure watches and completed results persist under `state_dir/seedling-delegation`.
  Pending events wait for a named parent to return; delivery is at-least-once across
  crashes (`report_id` permits deduplication). `result/1` retrieves the last event.
  Add `Seedling.Delegation.Manager` to the application after Nano.StateStore for
  node-restart recovery; lazy starts cover runtime use. See docs/seedling/delegation.md.
  """

  alias Seedling.Delegation.Manager

  def subagent(name, opts) do
    with :ok <- valid_name(name),
         :ok <- required(opts),
         {:ok, _} <- Nano.Model.check(opts[:model], opts[:reasoning], opts[:max_context]),
         {:ok, parent} <- parent(opts),
         {:ok, prompt, manifest} <- compose(name, Keyword.put(opts, :parent, parent)),
         :ok <- prompt_room(prompt, opts[:max_context]),
         {:ok, manager} <- Manager.ensure_started(),
         {:ok, worktree} <- worktree(opts[:worktree], opts[:repo] || "/app") do
      prompt = prompt <> worktree_prompt(worktree)
      start_opts = Keyword.take(opts, [:model, :reasoning, :max_turns, :max_tokens, :max_context])

      case NanoAgent.start(start_opts ++ [name: name, system_prompt: prompt, start_idle: true]) do
        {:ok, pid} ->
          id = NanoAgent.info(name).id

          case setup_child(manager, name, id, pid, parent, worktree, opts) do
            :ok ->
              message =
                opts[:message] || if(opts[:start_idle] == false, do: "Begin your assigned job.")

              if message,
                do: send(pid, %{message: message, sender_name: parent, sender_pid: caller()})

              {:ok,
               %{name: name, pid: pid, id: id, parent: parent, worktree: worktree, pre: manifest}}

            {:error, reason} ->
              {:error, {:child_setup, reason}}
          end

        error ->
          error
      end
    end
  end

  @doc "Compose without starting; returned manifest is exactly what the child has seen."
  def compose(name, opts) do
    root = opts[:root] || "/app"
    parts = opts[:partials_dir] || Path.join(root, "priv/seedling/prompts")
    flavours = opts[:flavours] || [opts[:flavour] || :builder]

    with {:ok, facts} <- File.read(opts[:facts_file] || Path.join(root, "priv/system_prompt.txt")),
         {:ok, principles} <- File.read(Path.join(parts, "principles.txt")),
         {:ok, role} <- read_flavours(parts, flavours),
         {:ok, pre, manifest} <- preread(opts[:pre] || [], opts[:pre_max_bytes] || 32_000) do
      report =
        "Your parent is #{inspect(opts[:parent])}. Address it by name, not a saved pid. " <>
          "Report a compact summary through Seedling.Delegation.report(#{inspect(name)}, summary); " <>
          "include branch/commit, actual tests and unresolved issues. Never rely on final prose being delivered."

      {:ok,
       Enum.join(
         [facts, principles, role, report, "Job:\n" <> (opts[:prompt] || ""), pre],
         "\n\n"
       ), manifest}
    end
  end

  def preread(entries, cap \\ 32_000) do
    Enum.reduce_while(entries, {:ok, "", []}, fn entry, {:ok, text, manifest} ->
      {path, opts} = if is_binary(entry), do: {entry, []}, else: entry

      with {:ok, full} <- File.read(path),
           true <- String.valid?(full) || {:error, {:not_text, path}},
           offset = Keyword.get(opts, :offset, 1),
           lines = String.split(full, "\n"),
           true <-
             (is_integer(offset) and offset in 1..length(lines)) || {:error, {:offset, path}},
           limit = Keyword.get(opts, :limit, length(lines)),
           true <- (is_integer(limit) and limit > 0) || {:error, {:limit, path}} do
        excerpt = lines |> Enum.drop(offset - 1) |> Enum.take(limit) |> Enum.join("\n")

        mark = %{
          path: Path.expand(path),
          sha256: hash(full),
          excerpt_sha256: hash(excerpt),
          offset: offset,
          lines: min(limit, length(lines) - offset + 1),
          total_lines: length(lines)
        }

        added = "\n<pre_read #{inspect(mark)}>\n#{excerpt}\n</pre_read>\n"

        cond do
          harness_marker?(excerpt) ->
            {:halt,
             {:error,
              {:harness_template_marker_in_pre, path,
               "choose an excerpt without reserved {{placeholders}}; the harness would rewrite it"}}}

          byte_size(text <> added) > cap ->
            {:halt,
             {:error,
              {:pre_read_too_large, path, cap,
               "choose explicit offset/limit or raise pre_max_bytes"}}}

          true ->
            {:cont, {:ok, text <> added, manifest ++ [mark]}}
        end
      else
        error -> {:halt, error}
      end
    end)
  end

  def changed?(%{path: path, sha256: old}) do
    with {:ok, full} <- File.read(path), do: {:ok, hash(full) != old}
  end

  def worktree(nil, _repo), do: {:ok, nil}

  def worktree(opts, repo) when is_list(opts) do
    with path when is_binary(path) <- opts[:path],
         revision when is_binary(revision) <- opts[:revision],
         branch when is_binary(branch) <- opts[:branch],
         true <- not File.exists?(path) || {:error, {:worktree_exists, path}},
         %{status: 0, output: resolved} <-
           git(repo, ["rev-parse", "--verify", revision <> "^{commit}"]),
         commit = String.trim(resolved),
         %{status: 0} <- git(repo, ["worktree", "add", "-b", branch, "--", path, commit]) do
      {:ok,
       %{
         path: Path.expand(path),
         revision: revision,
         commit: commit,
         branch: branch,
         mix_env: "test",
         mix_build_root: Path.join(Path.expand(path), ".seedling-build")
       }}
    else
      nil -> {:error, "worktree requires path, revision and branch (no revision default)"}
      %{status: _, output: output} -> {:error, {:git, output}}
      error -> error
    end
  end

  def report(child, summary, status \\ :ok), do: Manager.report(child, summary, status)
  def result(child), do: Manager.result(child)
  def tell(child, message), do: NanoAgent.notify(child, %{message: message, sender_pid: caller()})

  defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp git(repo, args),
    do:
      Seedling.Tools.sh(Enum.map_join(["git" | args], " ", &Seedling.Tools.quote_arg/1),
        cwd: repo
      )

  defp read_flavours(parts, flavours) do
    Enum.reduce_while(flavours, {:ok, ""}, fn flavour, {:ok, text} ->
      flavour = to_string(flavour)

      with true <- flavour =~ ~r/^[a-z0-9_-]+$/ || {:error, :invalid_flavour},
           {:ok, role} <- File.read(Path.join(parts, flavour <> ".txt")) do
        {:cont, {:ok, text <> role <> "\n"}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp valid_name(name) do
    if is_binary(name) and name =~ ~r/^[\w.-]+$/, do: :ok, else: {:error, :invalid_name}
  end

  defp harness_marker?(text) do
    Enum.any?(
      ~w(pid name node otp_release elixir_version os_user os network_policy max_turns max_tokens max_context result_max_bytes),
      &String.contains?(text, "{{" <> &1 <> "}}")
    )
  end

  defp setup_child(manager, name, id, pid, parent, worktree, opts) do
    servers = opts[:mcp] || []
    mcp_opts = opts[:mcp_options] || []

    Seedling.Delegation.SetupGuard.run(name, id, servers, mcp_opts, fn ->
      with :ok <- GenServer.call(manager, {:track, name, id, pid, parent, worktree}),
           :ok <- connect_mcp(servers, name, mcp_opts),
           :ok <- release_mcp(servers, name, mcp_opts),
           do: :ok
    end)
  end

  defp required(opts) do
    missing =
      Enum.filter([:model, :reasoning, :max_turns, :max_tokens, :max_context], &(opts[&1] == nil))

    if missing == [], do: :ok, else: {:error, {:missing, missing}}
  end

  defp prompt_room(prompt, context) when is_integer(context) and context >= 8192 do
    if div(byte_size(prompt) + 1, 2) + 5120 < context,
      do: :ok,
      else: {:error, :prompt_exceeds_context_budget}
  end

  defp prompt_room(_, _),
    do:
      {:error, "delegation max_context must be at least 8192 to leave reporting/compaction room"}

  defp parent(opts) do
    target =
      opts[:parent] ||
        Enum.find_value(Nano.Names.all(), fn
          {{:agent, name}, pid} -> if pid == caller(), do: name
          _ -> nil
        end)

    if is_binary(target) or is_pid(target),
      do: {:ok, target},
      else: {:error, "supply parent: name outside an agent eval"}
  end

  defp caller, do: List.first(Process.get(:"$callers", [])) || self()
  defp worktree_prompt(nil), do: "\nRead-only job: no worktree assigned. Do not edit /app.\n"

  defp worktree_prompt(w),
    do: "\nAssigned worktree: #{inspect(w)}. Edit there only, never /app.\n"

  defp release_mcp([], _, _), do: :ok
  defp release_mcp(_, name, opts), do: apply(Seedling.MCP, :release_events, [name, opts])

  defp connect_mcp([], _, _), do: :ok

  defp connect_mcp(servers, name, opts) do
    Enum.reduce_while(servers, :ok, fn server, :ok ->
      case apply(Seedling.MCP, :connect, [
             server,
             Keyword.merge(opts, agent: name, defer_events: true)
           ]) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end

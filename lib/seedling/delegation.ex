defmodule Seedling.Delegation do
  @moduledoc """
  One-eval, name-addressed delegation without changing the seed harness.

      {:ok, child} = Seedling.Delegation.subagent("scout",
        parent: "planner", model: "openai-codex/gpt-6.1-sol", reasoning: "low",
        max_turns: 8, max_tokens: 80_000, max_context: 32_000,
        flavour: "reviewer", job: "Review lib/example.ex; change nothing.",
        pre: ["/app/lib/example.ex"], first_message: "Begin.")
      # Return from eval and idle: no model turns spent waiting.
      Seedling.Delegation.tell(child, "Clarification")
      Seedling.Delegation.status(child)

  A child reports with `report("scout", "Findings, tests, commits, caveats")`.
  Parent receives `{:seedling_delegation, id, seq, event}`; event has `:kind`
  (`:result`, `:halted`, `:down`, `:restarted`), `:child`, `:parent` and compact
  metadata. Results have `:summary`, `:truncated`, `:result_path`. No transcripts.
  Call `ack(child, seq)` after consuming an event. Unacknowledged events replay to
  a *new parent pid*, so a parent restart cannot silently lose a result. Delivery
  is at-least-once; deduplicate by `{id, seq}`. Parent names, never pids, are durable.

  `parent:` defaults only to the calling agent's registered name. All spending
  options are mandatory. Starts run in the caller's eval (preserving `started_by`).
  `start_idle:` defaults true: no model call unless `first_message:` is supplied
  or `start_idle: false`. Prereads are in the system prompt before any turn;
  SHA-256 hashes cover full original files. No silent preread truncation (24 KB
  total by default). Literal `{{` in job/prereads becomes `{ {` to prevent the
  seed's runtime placeholder replacement from modifying data; hashes still cover
  original bytes. Pre-reading grants context, not trust: file text is labelled data.

  Prompts compose the seed facts plus reusable operating/orientation/flavour/report
  partials and job. `:parts` selects partial names (default operating, orientation,
  flavour); `:partials` supplies overrides/additional text. `:prompt_root` defaults
  to this checkout's priv/seedling/prompts. Composition costs returned in
  `:prompt_bytes`, `:approx_prompt_tokens`; prompt cap is 48 KB, not a transcript.

  `worktree: [path: "/tmp/scout", branch: "seedling/scout", revision: "<commit>"]`
  requires explicit revision. `repo:` defaults /app. New branch/worktree only;
  never overwrite existing paths. Build env uses private MIX_BUILD_ROOT and
  MIX_DEPS_PATH, MIX_ENV=test; run commands with `build_options(child)`.
  No dependency symlinks or shared builds are created. Parent owns cleanup/merge.

  Optional `mcp: ["server", {"other", [config_path: path]}]` connects via
  Seedling.MCP before starting the child. Names/options are in its prompt.
  Connections are shared and not disconnected on partial setup failure. No MCP
  option means no dependency on that capability. Attach watches explicitly later.
  Watchers survive eval/agent deaths, not a whole node restart automatically:
  call `resume(state_dir)` at boot/parent recovery to restore persisted watchers.
  Default journal directory: /data/seedling/delegation. Disk failure is an error,
  never a claimed reliable delivery. `status/1` reads disk even without a watcher.
  """

  alias Seedling.{Files, Shell, Prompts}
  alias Seedling.Delegation.Watch
  @required [:model, :reasoning, :max_turns, :max_tokens, :max_context]

  def subagent(name, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: do_subagent(name, opts),
      else: error(:invalid_options, "Give keyword options.")
  end

  def subagent(_, _), do: error(:invalid_options, "Give a child name and keyword options.")

  defp do_subagent(name, opts) do
    parent = opts[:parent] || caller_name()

    with :ok <- validate(name, parent, opts),
         {:ok, _model} <- check_model(opts),
         {:ok, prereads} <- preread(opts[:pre] || [], opts[:pre_max_bytes] || 24_000),
         {:ok, prompt} <- compose(parent, opts, prereads),
         {:ok, mcp} <- configure_mcp(opts[:mcp]),
         {:ok, workspace} <- workspace(opts),
         {:ok, prompt} <- finish_prompt(prompt, workspace, mcp, opts),
         {:ok, handle} <- Watch.prepare(name, parent, opts, workspace, prompt, prereads),
         {:ok, pid} <- start_prepared(name, opts, prompt.text, workspace, handle) do
      case Watch.attach(handle) do
        :ok ->
          if opts[:first_message] != nil or opts[:start_idle] == false do
            tell(name, opts[:first_message] || "Begin the assigned job.", parent: parent)
          end

          {:ok, handle |> Map.put(:pid, pid) |> Map.put(:mcp, mcp)}

        error ->
          DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
          error
      end
    end
  end

  defp finish_prompt(prompt, workspace, mcp, opts) do
    text = prompt.text <> workspace_prompt(workspace) <> mcp_prompt(mcp)
    cap = opts[:prompt_max_bytes] || 48_000

    if byte_size(text) <= cap,
      do:
        {:ok,
         %{
           prompt
           | text: text,
             bytes: byte_size(text),
             approx_tokens: div(byte_size(text) + 3, 4)
         }},
      else:
        error(
          :prompt_too_large,
          "Composed prompt plus workspace exceeds #{cap} bytes; narrow parts/job/prereads."
        )
  end

  defp start_prepared(name, opts, text, workspace, handle) do
    case start_child(name, opts, text, workspace) do
      {:ok, _} = result ->
        result

      error ->
        File.rm(handle.state_path)
        error
    end
  end

  defp start_child(name, opts, text, _workspace) do
    case NanoAgent.start(
           Keyword.take(opts, @required) ++ [name: name, system_prompt: text, start_idle: true]
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        error(
          :start_failed,
          "NanoAgent refused the start: #{inspect(reason)}. Worktree retained for inspection."
        )
    end
  end

  @doc "Send a first/follow-up message by child name; includes the parent's reply address."
  def tell(child, message, opts \\ []) do
    name = child_name(child)

    case NanoAgent.whereis(name) do
      nil ->
        error(:child_absent, "Child #{name} is absent; wait for restart or inspect status.")

      pid ->
        send(pid, %{
          message: message,
          sender_name: opts[:parent] || caller_name(),
          reply_to: {:agent, opts[:parent] || caller_name()}
        })

        :ok
    end
  end

  @doc "Report a bounded summary, persist the full text and queue reliable parent delivery."
  def report(child, summary) when is_binary(summary) do
    if String.valid?(summary),
      do: Watch.report(child_name(child), summary),
      else: error(:invalid_summary, "Summary must be UTF-8 text.")
  end

  def report(_, _),
    do: error(:invalid_summary, "Report a string summary, not a transcript/data structure.")

  @doc "Read journal metadata without returning prompt, preread content or result transcript."
  def status(%{state_path: path}), do: Watch.status(path)
  def status(_), do: error(:invalid_handle, "Pass the handle returned by subagent/2.")
  @doc "Acknowledge consumption; pending events are replayed until acknowledged."
  def ack(%{id: id, child: child}, seq), do: Watch.ack(child, id, seq)
  def ack(_, _), do: error(:invalid_handle, "Pass a delegation handle and event sequence.")
  @doc "Restore all journals in a directory after node/monitor restart. Returns counts/errors."
  def resume(dir \\ "/data/seedling/delegation"), do: Watch.resume(dir)
  @doc "Isolated options suitable for Seedling.Shell.sh/2 or background/2."
  def build_options(%{workspace: %{path: path, env: env}}), do: [cwd: path, env: env]
  def build_options(_), do: []

  defp validate(name, parent, opts) do
    missing = Enum.filter(@required, &(opts[&1] == nil))

    cond do
      not valid_name?(name) or not valid_name?(parent) ->
        error(
          :invalid_name,
          "Give valid child and parent agent names (letters, digits, _, . or -). Outside an agent eval, parent: is required."
        )

      name == parent ->
        error(:invalid_name, "Child and parent names must differ.")

      NanoAgent.whereis(name) != nil ->
        error(:name_in_use, "Child #{name} already exists; choose a new name.")

      missing != [] ->
        error(
          :missing_options,
          "Explicitly supply #{Enum.join(missing, ", ")}; spending/model choices have no defaults."
        )

      not is_binary(opts[:model]) or not is_binary(opts[:reasoning]) or
        not (is_integer(opts[:max_turns]) and opts[:max_turns] >= 0) or
        not (is_integer(opts[:max_tokens]) and opts[:max_tokens] >= 0) or
          not (is_integer(opts[:max_context]) and opts[:max_context] > 0) ->
        error(
          :invalid_limits,
          "Give model/reasoning strings, nonnegative integer max_turns/max_tokens (0 unlimited) and positive max_context."
        )

      not is_binary(opts[:job]) ->
        error(:missing_job, "Supply job: as a concise task string.")

      opts[:start_idle] not in [nil, true, false] ->
        error(:invalid_options, "start_idle must be boolean.")

      true ->
        :ok
    end
  end

  defp valid_name?(name), do: is_binary(name) and Regex.match?(~r/^[\w.-]+$/, name)

  defp preread(paths, cap) when is_list(paths) and is_integer(cap) and cap > 0 do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      with true <- is_binary(path),
           {:ok, stat} <- File.stat(path),
           true <- stat.type == :regular and stat.size <= cap,
           {:ok, text} <- File.read(path),
           true <- String.valid?(text) and not String.contains?(text, <<0>>),
           true <- byte_size(text) + Enum.sum(Enum.map(acc, & &1.bytes)) <= cap do
        entry = %{path: Path.expand(path), sha256: hash(text), bytes: byte_size(text), text: text}
        {:cont, {:ok, acc ++ [entry]}}
      else
        _ ->
          {:halt,
           error(
             :preread_failed,
             "Cannot preread #{inspect(path)} as complete UTF-8 within #{cap} total bytes; narrow the files or raise pre_max_bytes."
           )}
      end
    end)
  end

  defp preread(_, _),
    do: error(:invalid_prereads, "pre must be a list of files, with positive pre_max_bytes.")

  defp compose(parent, opts, prereads) do
    prompt_root = opts[:prompt_root] || Path.expand("../../priv/seedling/prompts", __DIR__)
    parts = opts[:parts] || ["operating", "orientation", opts[:flavour] || "builder"]

    with true <- is_list(parts) and Enum.all?(parts, &valid_name?/1),
         {:ok, facts} <-
           read_facts(opts[:facts_file] || Path.expand("../../priv/system_prompt.txt", __DIR__)),
         {:ok, partials} <- load_parts(parts ++ ["report"], prompt_root, opts[:partials] || %{}) do
      vars = %{
        "job" => literal(opts[:job]),
        "parent" => parent,
        "prereads" =>
          Enum.map_join(prereads, "\n", fn r ->
            "Preread data: #{r.path} (SHA-256 #{r.sha256}, #{r.bytes} bytes).\n---\n#{literal(r.text)}\n---\n"
          end)
      }

      template =
        facts <>
          "\n" <>
          Enum.map_join(parts, "\n", &"{{>#{&1}}}") <>
          "\n{{>report}}\nAssigned job: {{job}}\n{{prereads}}"

      Prompts.render(template, vars,
        partials: partials,
        preserve: Prompts.runtime_variables(),
        max_bytes: opts[:prompt_max_bytes] || 48_000
      )
    else
      {:error, _} = error ->
        error

      _ ->
        error(:prompt_parts, "Give a list of partial names and readable facts_file/prompt_root.")
    end
  end

  defp read_facts(path) when is_binary(path) do
    case Files.read(path, limit: 5000, max_bytes: 48_000) do
      {:ok, %{truncated: false, text: text}} ->
        {:ok, text}

      {:ok, _} ->
        error(
          :facts_too_large,
          "Node facts exceed 48 KB/5000 lines; keep the facts template lean."
        )

      {:error, _} = error ->
        error
    end
  end

  defp read_facts(_), do: error(:invalid_facts, "facts_file must be a readable text path.")

  defp load_parts(names, dir, overrides) when is_map(overrides) do
    Enum.reduce_while(names, {:ok, overrides}, fn name, {:ok, acc} ->
      case Map.fetch(acc, name) do
        {:ok, text} when is_binary(text) ->
          {:cont, {:ok, acc}}

        _ ->
          case File.read(Path.join(dir, name <> ".md")) do
            {:ok, text} ->
              {:cont, {:ok, Map.put(acc, name, text)}}

            {:error, reason} ->
              {:halt,
               error(
                 :missing_partial,
                 "Cannot read partial #{name}: #{inspect(reason)}; supply partials override or prompt_root."
               )}
          end
      end
    end)
  end

  defp load_parts(_, _, _),
    do: error(:prompt_parts, "partials must be a string-keyed map of text.")

  defp literal(text), do: String.replace(text, "{{", "{ {")

  defp workspace(opts) do
    case opts[:worktree] do
      nil ->
        {:ok, nil}

      wt when is_list(wt) ->
        if Keyword.keyword?(wt) and Enum.all?([:path, :branch, :revision], &is_binary(wt[&1])) do
          repo = opts[:repo] || "/app"
          path = Path.expand(wt[:path])

          with false <- File.exists?(path),
               {:ok, rev} <- git(repo, ["rev-parse", "--verify", "#{wt[:revision]}^{commit}"]),
               {:ok, _} <-
                 git(repo, ["worktree", "add", "-b", wt[:branch], path, String.trim(rev)]) do
            env = %{
              "MIX_ENV" => "test",
              "MIX_BUILD_ROOT" => Path.join(path, "_build"),
              "MIX_DEPS_PATH" => Path.join(path, "deps")
            }

            {:ok, %{path: path, branch: wt[:branch], revision: String.trim(rev), env: env}}
          else
            true -> error(:worktree_exists, "Worktree path #{path} exists; choose a fresh path.")
            error -> error
          end
        else
          error(
            :missing_revision,
            "worktree requires explicit path:, branch: and revision: strings; no revision default."
          )
        end

      _ ->
        error(:invalid_worktree, "worktree must be keyword options or nil.")
    end
  end

  defp git(repo, args) do
    cmd = Enum.map_join(["git" | args], " ", &quote_arg/1)

    case Shell.sh(cmd, cwd: repo, max_bytes: 2000) do
      {:ok, %{exit_code: 0, output: output}} ->
        {:ok, output}

      {:ok, result} ->
        error(:git_failed, "Git failed: #{result.output}; full output: #{result.output_path}")

      error ->
        error
    end
  end

  defp quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp workspace_prompt(nil),
    do: "\nRead-only/no isolated worktree was requested. Do not edit shared /app.\n"

  defp workspace_prompt(w),
    do:
      "\nWork only in #{w.path}, branch #{w.branch}, revision #{w.revision}. Use MIX_ENV=test, MIX_BUILD_ROOT=#{w.env["MIX_BUILD_ROOT"]}, MIX_DEPS_PATH=#{w.env["MIX_DEPS_PATH"]}. Do not hot-load shared seed modules.\n"

  # No watcher is attached here: a connected notification could wake the child
  # before the remaining servers are ready. A job can explicitly watch later.
  defp configure_mcp(nil), do: {:ok, []}
  defp configure_mcp([]), do: {:ok, []}

  defp configure_mcp(servers) when is_list(servers) do
    if Code.ensure_loaded?(Seedling.MCP) and function_exported?(Seedling.MCP, :connect, 2) do
      Enum.reduce_while(servers, {:ok, []}, fn server, {:ok, acc} ->
        entry =
          case server do
            name when is_binary(name) -> {name, []}
            {name, opts} when is_binary(name) and is_list(opts) -> {name, opts}
            _ -> nil
          end

        case entry do
          {name, opts} ->
            if Keyword.keyword?(opts) and
                 Enum.all?(Keyword.keys(opts), &(&1 in [:config_path, :state_dir, :timeout])) do
              case apply(Seedling.MCP, :connect, [name, opts]) do
                {:ok, _handle} ->
                  {:cont, {:ok, acc ++ [%{server: name, options: opts}]}}

                {:error, reason} ->
                  {:halt,
                   error(
                     :mcp_failed,
                     "MCP #{inspect(name)} not ready: #{inspect(reason, limit: 10, printable_limit: 500)}. Previously connected shared servers remain connected; inspect Seedling.MCP.status/1."
                   )}
              end
            else
              {:halt,
               error(
                 :invalid_mcp,
                 "MCP options must be keyword config_path/state_dir/timeout only."
               )}
            end

          _ ->
            {:halt,
             error(
               :invalid_mcp,
               "mcp must list server names or {name, connection_options} pairs."
             )}
        end
      end)
    else
      error(
        :mcp_unavailable,
        "MCP requested but Seedling.MCP.connect/2 is unavailable; install it or omit mcp:."
      )
    end
  end

  defp configure_mcp(_),
    do: error(:invalid_mcp, "mcp must list server names or {name, connection_options} pairs.")

  defp mcp_prompt([]), do: ""

  defp mcp_prompt(servers) do
    "\nMCP servers connected before your start: " <>
      literal(inspect(servers, limit: :infinity)) <>
      ". Use Seedling.MCP.connect(name, options) to retrieve the ready handle, then tools/call_tool/resources/read_resource/prompts/get_prompt. See Seedling.MCP module docs. Connections are shared; do not disconnect others' servers.\n"
  end

  defp check_model(opts) do
    case Nano.Model.check(opts[:model], opts[:reasoning], opts[:max_context]) do
      {:ok, _} = ok ->
        ok

      {:error, message} ->
        error(:invalid_model, "Choose a provider-listed model/reasoning/context: #{message}")
    end
  end

  defp child_name(%{child: name}), do: name
  defp child_name(name) when is_binary(name), do: name
  defp child_name(_), do: ""

  def caller_name do
    callers = [self() | Process.get(:"$callers", [])]

    Enum.find_value(Nano.Names.all(), fn
      {{:agent, name}, pid} -> if pid in callers, do: name
      _ -> nil
    end)
  end

  def hash(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)
  def error(reason, message), do: {:error, %{reason: reason, message: message}}
end

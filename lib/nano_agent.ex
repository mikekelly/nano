defmodule NanoAgent do
  @moduledoc """
  One LLM agent as a GenServer (bootstrap/SPEC.md "Agent GenServer"). The harness does three things:
  deliver mailbox messages as events, run the model's tool calls, and log everything.

  Model requests and evals run in tasks under `Nano.EvalSupervisor` and come back as messages,
  so the agent stays responsive (and suspendable) while they run. Internal messages carry
  the task refs or a per-process `tag` ref; everything else that arrives is an event.

  State is a plain map. It is written to `Nano.StateStore` after every callback, after each
  model response, and before every model request and eval, and a restarted process resumes
  from it. Nothing in state is a closure, so this module can be recompiled under running
  agents as long as new code accepts the same map. `init/1` cannot fail: if restoring
  crashes, the agent comes up halted, so a broken edit cannot loop the supervisor.
  """
  use GenServer
  require Logger

  @log_failed "I could not write the harness log, the durable record of what you do"

  # The largest summary (in bytes) `compact/3` accepts; a compaction should be small.
  @compact_max_summary 64_000

  @tools [
    %{
      type: "function",
      function: %{
        name: "eval",
        description:
          "Evaluate Elixir code on this node. Variables you bind persist between calls; `me` is your pid. " <>
            "Returns the inspected result and any captured IO, or the exception and stacktrace.",
        parameters: %{
          type: "object",
          properties: %{code: %{type: "string", description: "Elixir source to evaluate"}},
          required: ["code"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "idle",
        description: "End your turn and wait for the next message. Returns nothing.",
        parameters: %{
          type: "object",
          properties: %{
            wakeup_after: %{
              type: "integer",
              description: "Milliseconds after which to wake you if no message has arrived first"
            }
          }
        }
      }
    }
  ]

  ## API

  @doc """
  Starts an agent under `Nano.AgentSupervisor`. Options: `name:` (required; letters, digits,
  `_`, `.`, `-`), `model:` (default `DEFAULT_MODEL`), `start_idle:` (boolean, default true),
  `system_prompt:` (a template string replacing the default; same `{{placeholders}}`),
  `system_prompt_file:` (a template file, instead of `SYSTEM_PROMPT_FILE`), `max_turns:`,
  `max_tokens:`, `max_context:` (non-negative integers; 0 means no limit), `reasoning:` (one of `reasoning_levels/0`, default
  `REASONING`). Returns `{:error, :invalid_name | :invalid_option | :missing_model}`, the
  reason `Nano.Model.unavailable/1` gives, or the supervisor's result.
  """
  def start(opts) do
    name = opts[:name]
    model = opts[:model] || Application.get_env(:nano, :default_model)
    # An invalid REASONING default surfaces here, as an invalid option.
    opts =
      if opts[:reasoning] == nil, do: Keyword.put(opts, :reasoning, env(:reasoning)), else: opts

    cond do
      not (is_binary(name) and name =~ ~r/^[\w.-]+$/) ->
        {:error, :invalid_name}

      not valid_options?(opts) ->
        {:error, :invalid_option}

      model in [nil, ""] ->
        {:error, :missing_model}

      reason = Nano.Model.unavailable(model) ->
        {:error, reason}

      true ->
        # The template: the agent's own string, or a file read now (and again at each restart).
        file =
          if opts[:system_prompt],
            do: nil,
            else: opts[:system_prompt_file] || env(:system_prompt_file)

        with {:ok, template} <- if(file, do: File.read(file), else: {:ok, opts[:system_prompt]}) do
          more = [model: model, id: new_id(name), template: template, prompt_file: file]
          # Called from an agent's eval: the eval task's first caller is that agent.
          parent =
            with [pid | _] <- Process.get(:"$callers"),
                 [{:agent, n}] <- Registry.keys(Nano.Registry, pid) do
              n
            else
              _ -> nil
            end

          more = Keyword.put(more, :started_by, parent)

          case DynamicSupervisor.start_child(
                 Nano.AgentSupervisor,
                 {__MODULE__, Keyword.merge(opts, more)}
               ) do
            :ignore -> {:error, :start_failed}
            result -> result
          end
        else
          {:error, reason} -> {:error, {:system_prompt_file, reason}}
        end
    end
  end

  @doc """
  Replaces the agent's conversation history with a compact `summary` of it, so its context
  starts again from a small, valid transcript. Call it when the conversation is approaching the
  context budget: the summary should keep decisions, commitments, open questions and anything
  needed to carry on, and must not invent facts.

  Runs only while the agent is idle: `{:error, :busy}` if a model request or eval is in flight
  (or its tool calls are still being handled), in which case call again later. As the call is
  serialized by the GenServer, an agent that accepts it is not running anything else.

  What is preserved exactly: the log (the durable record) and every runtime fact and counter —
  id, name, model, reasoning, system prompt and its source, pid and start, restart count, cost,
  turns/tokens/cache and *budgets*, call and event sequence numbers, variable bindings, spawned
  processes, and any events already received but not yet delivered (their text is kept verbatim
  and delivered at the start of the next turn). Only the transcript and the derived
  `context_used` are rewritten; a summary is appended as the first user message, so the model
  keeps the thread, and the transcript stays valid (every recorded tool call keeps its result).

  Pass `expected_transcript_hash: :erlang.phash2(snapshot.transcript)` to reject a stale
  summary. Summaries must be nonblank UTF-8, at most 64,000 bytes. Options are a keyword
  list accepting that hash and optional `retained:` metadata (a list). The durable
  `:compacted` log entry must succeed before history is changed; original logs are untouched.
  Halt reasons are not cleared, and no turn is started by compaction.

  Returns `{:ok, info}` or `{:error, reason}` where reason is `:not_found`, `:busy`,
  `:stale`, `:invalid_summary`, `:invalid_option`, `:unanswered_tools`, or `:log_failed`.
  """
  def compact(name, summary, opts \\ []) do
    with :ok <- validate_compaction(summary, opts) do
      case whereis(name) do
        nil -> {:error, :not_found}
        pid -> GenServer.call(pid, {:compact, summary, opts}, :infinity)
      end
    end
  end

  @doc "The `reasoning:` settings an agent can be started with: `\"off\"`, then effort levels, lowest first."
  defdelegate reasoning_levels, to: Nano.OpenRouter

  defp valid_options?(opts) do
    Enum.all?(
      [:max_turns, :max_tokens, :max_context],
      &(opts[&1] == nil or (is_integer(opts[&1]) and opts[&1] >= 0))
    ) and
      opts[:start_idle] in [nil, true, false] and opts[:reasoning] in reasoning_levels() and
      Enum.all?(
        [:model, :system_prompt, :system_prompt_file],
        &(opts[&1] == nil or is_binary(opts[&1]))
      )
  end

  @doc false
  def start_link(opts),
    do:
      GenServer.start_link(__MODULE__, opts,
        name: {:via, Registry, {Nano.Registry, {:agent, opts[:name]}}}
      )

  @doc "The agent's live pid, or nil (Registry lookup; no call to the agent)."
  def whereis(name) do
    case Registry.lookup(Nano.Registry, {:agent, name}) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc "Casts a term to an agent (pid or name); it arrives as an event, like a plain `send/2`."
  def notify(agent, term), do: GenServer.cast(target(agent), {:notify, term})

  @doc "Clears an agent's halt, whatever the reason; for `:start_failed` that retries the start."
  def unhalt(agent), do: GenServer.cast(target(agent), :unhalt)

  @doc """
  The agent's info map, or nil. Read from `Nano.StateStore`, never from the agent, so it works
  while the agent is busy or suspended. `halted` is nil, `:budget`, `:context`, `:node_budget`,
  `:usage_limit`, `:restart_brake`, `:start_failed` or `:log_failed`; `cache_hit_rate` is nil
  until the first response.
  """
  def info(name) do
    with %{} = s <- Nano.StateStore.get(name) do
      pid = whereis(name)

      %{
        id: s.id,
        name: s.name,
        pid: pid,
        model: s.model,
        status: s.status,
        halted: s.halted,
        suspended:
          match?(
            {:current_function, {:sys, :suspend_loop, _}},
            pid && Process.info(pid, :current_function)
          ),
        system_prompt: s.system_prompt,
        prompt_source: prompt_file(s) || "inline",
        started_by: Map.get(s, :started_by),
        restart_count: s.restart_count,
        cost: s.cost,
        reasoning: Map.get(s, :reasoning, "off"),
        cache_hit_rate: if(s.responses > 0, do: s.cache_hits / s.responses),
        budget: budget(s)
      }
    end
  end

  @doc "Names of all agents in the state store, sorted."
  def list, do: Nano.StateStore.all() |> Enum.map(& &1.name) |> Enum.sort()

  @doc """
  Kills every task under `Nano.EvalSupervisor` (evals and model requests) started by the
  agent process `pid`, found by `$callers`. Tasks outlive their agent, so this is how a
  stopped or restarted agent's work is cleaned up. Returns `:ok`.
  """
  def kill_tasks(pid) do
    for task <- Task.Supervisor.children(Nano.EvalSupervisor),
        {:dictionary, dict} <- [Process.info(task, :dictionary)],
        {_, [^pid | _]} <- [List.keyfind(dict, :"$callers", 0)],
        do: Process.exit(task, :kill)

    :ok
  end

  @doc """
  Starts, under `sup`, every agent saved in `Nano.StateStore` that has no live process, with
  the options it was started with; each comes back through the restart path, with its history.
  """
  def revive(sup) do
    for s <- Nano.StateStore.all(), whereis(s.name) == nil do
      keys = [:name, :id, :model, :max_turns, :max_tokens, :max_context, :reasoning]
      opts = s |> Map.take(keys) |> Keyword.new()
      DynamicSupervisor.start_child(sup, {__MODULE__, opts})
    end

    :ok
  end

  defp target(pid) when is_pid(pid), do: pid
  defp target(name), do: {:via, Registry, {Nano.Registry, {:agent, name}}}

  defp new_id(name), do: name <> "-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

  ## Start and restart

  @impl true
  def init(opts) do
    id = opts[:id]
    Nano.StateStore.watch(opts[:name], self())

    # The supervisor restarts us with the same opts, so a matching id means this is a restart.
    case Nano.StateStore.get(opts[:name]) do
      %{id: ^id} = saved -> {:ok, save(restore(saved)), {:continue, :start}}
      _ -> {:ok, save(fresh(opts)), {:continue, :start}}
    end
  catch
    kind, reason -> start_failed(opts, Exception.format(kind, reason, __STACKTRACE__))
  end

  @impl true
  def handle_continue(:start, s), do: noreply(maybe_start_turn(s))

  # Init must never return an error: the supervisor would retry in a tight loop until its
  # restart limit took every other agent down. So a failed restart comes up as a stand-in,
  # halted :start_failed, that only queues and logs events and leaves the saved entry as it
  # was (keeping any earlier halt in :halted_before); un-halting it exits, so the supervisor
  # runs the real restore again. With no saved entry, or if even this fails, the agent is
  # dropped (:ignore), which start/1 reports as {:error, :start_failed}.
  defp start_failed(opts, error) do
    Logger.error("#{opts[:name]}: start failed: #{error}")
    id = opts[:id]

    case Nano.StateStore.get(opts[:name]) do
      %{id: ^id} = saved ->
        # The previous process's eval has no timeout any more, and no one to report to.
        kill_tasks(saved.pid)
        # An entry saved by an older version of this module still holds its bindings.
        with %{bindings: b} <- saved, do: Nano.StateStore.put_bindings(saved.name, b)

        s =
          opts
          |> base()
          |> Map.merge(saved)
          |> Map.put_new(:halted_before, saved[:halted])
          |> Map.merge(%{tag: make_ref(), halted: :start_failed})

        log(s, :agent_started, %{
          id: id,
          name: s.name,
          pid: self(),
          restarted: true,
          halted: :start_failed,
          error: brief(error)
        })

        {:ok, save(s)}

      _ ->
        :ignore
    end
  catch
    _, _ -> :ignore
  end

  defp base(opts) do
    %{
      id: opts[:id],
      name: opts[:name],
      model: opts[:model],
      reasoning: opts[:reasoning] || env(:reasoning),
      pid: self(),
      tag: make_ref(),
      # The template text last read, and the file it came from (nil: given as a string).
      template: opts[:template],
      prompt_file: opts[:prompt_file],
      # The agent whose eval started this one, or nil (an operator did).
      started_by: opts[:started_by],
      system_prompt: nil,
      transcript: [],
      bindings: [],
      status: :idle,
      pending: [],
      halted: nil,
      max_turns: opts[:max_turns] || env(:agent_max_turns),
      max_tokens: opts[:max_tokens] || env(:agent_max_tokens),
      max_context: opts[:max_context] || env(:agent_max_context),
      turns_used: 0,
      tokens_used: 0,
      context_used: 0,
      cost: 0,
      responses: 0,
      cache_hits: 0,
      event_seq: 0,
      request_id: 0,
      call_seq: 0,
      restart_count: 0,
      restarts: [],
      calls: [],
      idle_called: false,
      wakeup_after: nil,
      wakeup: nil,
      task: nil,
      spawned: []
    }
  end

  defp fresh(opts) do
    s = base(opts)
    s = %{s | system_prompt: render(s)}
    # Clears any saved by an earlier agent of the same name.
    Nano.StateStore.put_bindings(s.name, [])

    log(
      s,
      :agent_started,
      Map.take(s, [:id, :name, :pid, :model, :reasoning, :system_prompt, :started_by])
      |> Map.merge(%{restarted: false, prompt_source: prompt_file(s) || "inline"})
    )

    if opts[:start_idle] == false,
      do: note(s, "Your process has just started. No message has arrived yet."),
      else: s
  end

  defp restore(saved) do
    reason = Nano.StateStore.exit_reason(saved.name, saved.pid) || :unknown
    # Revived at boot from the agent's state file: the whole node stopped, not just the process.
    node_restart? = reason == :node_restart
    kill_tasks(saved.pid)
    # Wall-clock time, so the 60 s window also spans node restarts (which count, like any exit).
    wall = System.system_time(:millisecond)
    restarts = Enum.filter([wall | saved.restarts], &(&1 > wall - 60_000))
    # An entry saved by a :start_failed stand-in: restore works now, so the earlier halt is back.
    {before, saved} = Map.pop(saved, :halted_before)
    saved = if saved.halted == :start_failed, do: %{saved | halted: before}, else: saved
    brake? = saved.halted == nil and length(restarts) >= 3

    # An eval in flight when the process died left its spawned processes on a dead device;
    # after a node restart there are none left.
    orphans = with %{io: io} <- saved.task, do: adopt(io, Process.group_leader()), else: (_ -> [])

    # Bindings are saved apart from the entry (one saved by an older version of this module
    # still holds them), and the largest may have been left out as too large to save.
    with %{bindings: b} <- saved, do: Nano.StateStore.put_bindings(saved.name, b)
    {bindings, unsaved} = Nano.StateStore.bindings(saved.name)

    s =
      saved
      |> new_process()
      |> Map.merge(%{
        bindings: bindings,
        restart_count: saved.restart_count + 1,
        restarts: restarts,
        spawned: if(node_restart?, do: [], else: saved.spawned ++ orphans)
      })

    # The template file is read again, so edits to it take effect at a restart. If it cannot
    # be read, the copy read last is used, and the note says so.
    file = prompt_file(saved)
    read = if file, do: File.read(file), else: {:ok, saved.template}
    template = with {:ok, text} <- read, do: text, else: (_ -> saved.template)
    s = Map.merge(s, %{template: template, prompt_file: file})
    s = %{s | system_prompt: render(s)}
    keys = [:id, :name, :pid, :model, :reasoning, :system_prompt, :restart_count, :started_by]
    started = Map.take(s, keys)

    log(
      s,
      :agent_started,
      Map.merge(started, %{
        restarted: true,
        exit_reason: brief(reason),
        halted: if(brake?, do: :restart_brake, else: s.halted),
        prompt_source: file || "inline",
        prompt_error: with({:error, e} <- read, do: inspect(e), else: (_ -> nil))
      })
    )

    # Calls cut short get a result, so the transcript stays valid for the API; it is logged
    # like any other result the model is given.
    stub = "No result: your process exited before this call completed."
    now = System.monotonic_time(:millisecond)
    s = Enum.reduce(unanswered(saved.transcript), s, &tool_result(&2, &1, now, false, stub))

    s =
      note(
        s,
        if(node_restart?,
          do:
            "The node was restarted #{doing(saved)}, and I restored your process from what I " <>
              "had saved. Your pid is now #{inspect(self())}; your registered name is unchanged. " <>
              "Your history and variable bindings are back, but any pids, references or ports " <>
              "in your bindings belonged to the old node and are dead, and the processes you " <>
              "had started are gone.",
          else:
            "Your process exited with reason #{brief(reason)} #{doing(saved)} and was restarted. " <>
              "Your pid is now #{inspect(self())}; your registered name is unchanged."
        ) <>
          if(unsaved == [],
            do: "",
            else:
              " These variables were not restored and are no longer bound, because they were " <>
                "too large for me to save: #{Enum.join(unsaved, ", ")}."
          ) <>
          with(
            {:error, e} <- read,
            do:
              " I could not read the system prompt file #{file} (#{inspect(e)}), so your " <>
                "system prompt comes from the copy of it I read before.",
            else: (_ -> "")
          )
      )

    if brake?,
      do:
        halt(
          s,
          :restart_brake,
          "Your process has restarted #{length(restarts)} times within 60 seconds"
        ),
      else: s
  end

  # The fields that belong to a process rather than to the agent's history.
  defp new_process(s),
    do: %{
      s
      | pid: self(),
        tag: make_ref(),
        status: :idle,
        task: nil,
        calls: [],
        idle_called: false,
        wakeup: nil
    }

  # Only what the last save can support: a save is made before each eval and after its result.
  defp doing(%{task: %{kind: :eval, n: n}}), do: "during or just after eval (tool call #{n})"
  defp doing(%{status: :thinking}), do: "while waiting for a model response"
  defp doing(%{status: :running_tool}), do: "while handling your tool calls"
  defp doing(_), do: "while idle"

  # Tool calls in the last response that have no result yet (the process died mid-step).
  defp unanswered(transcript) do
    {results, rest} = transcript |> Enum.reverse() |> Enum.split_while(&(&1["role"] == "tool"))
    done = Enum.map(results, & &1["tool_call_id"])

    case rest do
      [%{"tool_calls" => [_ | _] = calls} | _] -> Enum.reject(calls, &(&1["id"] in done))
      _ -> []
    end
  end

  # Rendered at start and again at every restart, so the pid it states is always current.
  defp render(s) do
    vars = %{
      "pid" => inspect(self()),
      "name" => s.name,
      "node" => node(),
      "otp_release" => "OTP #{System.otp_release()}",
      "elixir_version" => System.version(),
      "os_user" => System.get_env("USER") || String.trim(elem(System.cmd("id", ["-un"]), 0)),
      "os" => os_name(),
      "network_policy" => env(:network_policy),
      "max_turns" => limit(s.max_turns),
      "max_tokens" => limit(s.max_tokens),
      "max_context" => limit(budget(s).max_context),
      "result_max_bytes" => env(:result_max_bytes)
    }

    Enum.reduce(vars, s.template, fn {k, v}, acc ->
      String.replace(acc, "{{#{k}}}", to_string(v))
    end)
  end

  # The template file an agent's prompt comes from, or nil for one given as a string. State
  # saved before this was recorded used the default file unless it had a string.
  defp prompt_file(s),
    do: Map.get(s, :prompt_file, if(s.template, do: nil, else: env(:system_prompt_file)))

  defp os_name do
    with {:ok, text} <- File.read("/etc/os-release"),
         [_, name] <- Regex.run(~r/^PRETTY_NAME="?([^"\n]+)/m, text) do
      name
    else
      _ -> :os.type() |> elem(1) |> to_string()
    end
  end

  ## Mailbox

  @impl true
  def handle_cast({:notify, term}, s), do: noreply(event(s, term))

  # From Nano.StateStore after it restarted with an empty table: save again, and be watched.
  def handle_cast(:resave, s) do
    Nano.StateStore.watch(s.name, self())
    noreply(s)
  end

  def handle_cast(:unhalt, %{halted: nil} = s), do: noreply(s)

  def handle_cast(:unhalt, %{halted: :start_failed} = s) do
    {before, s} = Map.pop(s, :halted_before)
    {:stop, :retry_start, save(%{s | halted: before, restarts: []})}
  end

  def handle_cast(:unhalt, s) do
    b = budget(s)

    {s, more} =
      case s.halted do
        :budget ->
          {%{s | turns_used: 0, tokens_used: 0},
           " Your turn and token counters are reset to zero."}

        :context ->
          {s,
           " This conversation does not shrink: its context is still " <>
             "#{used(b.context_used, b.max_context, "tokens")}, so I will halt you again " <>
             "after my next call to the model."}

        _ ->
          {s, ""}
      end

    s = note(%{s | halted: nil, restarts: []}, "An operator un-halted you.#{more}")
    noreply(maybe_start_turn(s))
  end

  # Not internal either: a stray cast or call is relayed exactly as it arrived.
  def handle_cast(msg, s), do: noreply(event(s, {:"$gen_cast", msg}))

  # Compaction: only while nothing is running, so it cannot race a model request, an eval, or
  # the tool calls of a response being handled. Anything else is :busy and the caller tries later.
  @impl true
  def handle_call({:compact, summary, opts}, _from, s) do
    result = validate_compaction(summary, opts)

    cond do
      result != :ok ->
        {:reply, result, s}

      s.status != :idle or s.task != nil or s.calls != [] ->
        {:reply, {:error, :busy}, s}

      opts[:expected_transcript_hash] != nil and
          opts[:expected_transcript_hash] != hash_transcript(s.transcript) ->
        {:reply, {:error, :stale}, s}

      not paired_transcript?(s.transcript) ->
        {:reply, {:error, :unanswered_tools}, s}

      true ->
        case do_compact(s, summary, opts) do
          {:ok, next} ->
            next = save(next)
            {:reply, {:ok, info(next.name)}, next}

          {:error, reason} ->
            {:reply, {:error, reason}, s}
        end
    end
  end

  def handle_call(msg, from, s), do: noreply(event(s, {:"$gen_call", from, msg}))

  @impl true
  def handle_info({ref, result}, %{task: %{task: %Task{ref: ref}}} = s) do
    Process.demonitor(ref, [:flush])
    noreply(task_done(s, result))
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %{task: %Task{ref: ref}}} = s),
    do: noreply(task_done(s, {:exit, reason}))

  def handle_info(
        {tag, :eval_timeout, ref},
        %{tag: tag, task: %{task: %Task{ref: ref} = task}} = s
      ) do
    result =
      case Task.shutdown(task, :brutal_kill) do
        nil -> :timeout
        {:ok, result} -> result
        exit -> exit
      end

    noreply(task_done(s, result))
  end

  def handle_info({tag, :wakeup, id}, %{tag: tag, wakeup: id} = s) do
    s =
      note(
        %{s | wakeup: nil},
        "No message arrived within #{s.wakeup_after} ms, so I am waking you as you asked."
      )

    noreply(maybe_start_turn(s))
  end

  # Failed attempts reported by the model request task, logged here so entries stay in seq order.
  def handle_info({tag, :model_error, fields}, %{tag: tag} = s) do
    log(s, :model_error, fields)
    noreply(s)
  end

  # A stale timer (its eval finished, or an event cancelled the wakeup).
  def handle_info({tag, _, _}, %{tag: tag} = s), do: noreply(s)

  def handle_info(msg, s), do: noreply(event(s, msg))

  defp event(s, term) do
    seq = s.event_seq + 1
    {text, truncated, spill} = truncate(inspect(term, inspect_opts()), {s.id, "event-#{seq}"})
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    s = %{
      s
      | event_seq: seq,
        wakeup: nil,
        pending: s.pending ++ [~s(<event seq="#{seq}" at="#{at}">#{text}</event>)]
    }

    # queue_length: events waiting for the next turn, this one included.
    queued = Enum.count(s.pending, &String.starts_with?(&1, "<event"))

    log(
      s,
      :event_received,
      spilled(spill, %{
        event_seq: seq,
        message: text,
        queue_length: queued,
        truncated: truncated
      })
    )

    maybe_start_turn(s)
  end

  # Harness notes queue up with events, in the order things happened.
  defp note(s, text) do
    log(s, :harness_note, %{text: text})
    %{s | pending: s.pending ++ ["<harness>#{text}</harness>"]}
  end

  defp halt(s, why, text) do
    note(
      %{s | halted: why},
      text <> ", so I have halted you: I will not call the model until an operator un-halts you."
    )
  end

  ## The loop

  defp maybe_start_turn(%{status: :idle, halted: nil, pending: [_ | _]} = s), do: request(s, true)
  defp maybe_start_turn(s), do: s

  defp request(s, new_turn?) do
    node_used = Nano.StateStore.node_tokens_last_hour()
    cap = env(:node_max_tokens_per_hour)

    cond do
      s.halted ->
        end_turn(s, if(s.halted == :log_failed, do: "error", else: "budget"))

      reached?(node_used, cap) ->
        text =
          "This node has used #{node_used} tokens in the last hour, reaching its cap of #{cap}"

        node = %{node_tokens_last_hour: node_used, node_max_tokens_per_hour: cap}
        log(s, :budget_exhausted, Map.merge(budget(s, "node"), node))
        s |> halt(:node_budget, text) |> end_turn("budget")

      true ->
        # Each delivery ends with what is used so far: not counting the call it starts, and
        # the context as of the latest response.
        b = budget(s)

        line =
          "<harness>Used so far: #{used(b.turns_used, b.max_turns, "turns")}, " <>
            "#{used(b.tokens_used, b.max_tokens, "tokens")}, " <>
            "context #{used(b.context_used, b.max_context, "tokens")}.</harness>"

        user = %{"role" => "user", "content" => Enum.join(s.pending ++ [line], "\n")}
        s = if new_turn?, do: %{append(s, user) | pending: []}, else: s
        messages = [%{"role" => "system", "content" => s.system_prompt} | s.transcript]
        id = s.request_id + 1
        size = approx_tokens(messages)
        fields = %{request_id: id, model: s.model, message_count: length(messages)}
        fields = if new_turn?, do: Map.put(fields, :budget_note, line), else: fields

        # No model call whose record could not be written.
        if log(s, :model_request, Map.put(fields, :approx_input_tokens, size)) == :ok do
          s = save(%{s | status: :thinking, request_id: id, turns_used: s.turns_used + 1})
          # Map.get: state saved by an older version of this module has no :reasoning.
          args = [self(), s.tag, {s.model, Map.get(s, :reasoning, "off")}, messages, id]
          task = Task.Supervisor.async_nolink(Nano.EvalSupervisor, __MODULE__, :call_model, args)
          %{s | task: %{kind: :model, task: task}}
        else
          s |> halt(:log_failed, @log_failed) |> end_turn("error")
        end
    end
  end

  @doc false
  # Runs in a task: one model call with up to 3 attempts for transient errors. Failed attempts
  # are reported to the agent, which logs them.
  def call_model(agent, tag, {model, reasoning}, messages, request_id, attempt \\ 1) do
    started = System.monotonic_time(:millisecond)

    case Nano.Model.chat(model, messages, @tools, reasoning) do
      {:ok, response} ->
        {:ok, Map.put(response, :latency_ms, System.monotonic_time(:millisecond) - started)}

      {:error, error} ->
        {transient, error} = Map.pop(error, :transient, false)
        retry = attempt < 3 and transient

        send(
          agent,
          {tag, :model_error,
           Map.merge(error, %{request_id: request_id, attempt: attempt, retry: retry})}
        )

        if retry do
          Process.sleep(Application.get_env(:nano, :openrouter_backoff_ms, 1_000) * attempt)
          call_model(agent, tag, {model, reasoning}, messages, request_id, attempt + 1)
        else
          {:error, error}
        end
    end
  end

  defp task_done(%{task: %{kind: :model}} = s, result), do: model_done(%{s | task: nil}, result)

  defp task_done(%{task: %{kind: :eval} = t} = s, result),
    do: eval_done(%{s | task: nil}, t, result)

  defp model_done(s, {:exit, reason}) do
    body = "model request task exited: " <> brief(reason)

    log(s, :model_error, %{
      request_id: s.request_id,
      status: nil,
      body: body,
      attempt: nil,
      retry: false
    })

    model_done(s, {:error, body})
  end

  # A usage limit (the provider says which) is not retried: the agent waits halted for an operator.
  defp model_done(s, {:error, %{limit: text}}),
    do: s |> halt(:usage_limit, text) |> end_turn("error")

  defp model_done(s, {:error, _}), do: s |> check_budget() |> end_turn("error")

  defp model_done(s, {:ok, %{message: msg} = r}) do
    prompt = r.usage["prompt_tokens"] || 0
    completion = r.usage["completion_tokens"] || 0
    cached = get_in(r.usage, ["prompt_tokens_details", "cached_tokens"]) || 0
    calls = msg["tool_calls"] || []
    Nano.StateStore.add_node_tokens(prompt + completion)

    log(s, :model_response, %{
      request_id: s.request_id,
      latency_ms: r.latency_ms,
      finish_reason: r.finish_reason,
      text: msg["content"],
      reasoning: msg["reasoning"],
      tool_calls: calls,
      provider: r.provider,
      prompt_tokens: prompt,
      completion_tokens: completion,
      cached_tokens: cached,
      cost: r.cost
    })

    # Null content is not valid in a later request; tool calls and reasoning details go back as sent.
    message =
      %{"role" => "assistant", "content" => msg["content"] || ""}
      |> Map.merge(
        Map.take(msg, ["tool_calls", "reasoning_details"])
        |> Map.reject(fn {_, v} -> v in [nil, []] end)
      )

    s =
      %{
        s
        | status: :running_tool,
          calls: calls,
          tokens_used: s.tokens_used + prompt + completion,
          cost: s.cost + (r.cost || 0),
          responses: s.responses + 1,
          cache_hits: s.cache_hits + if(cached > 0, do: 1, else: 0)
      }
      # The context: the size of this conversation as the provider last measured it, i.e.
      # this response's prompt plus its completion, which the next request at least contains.
      |> Map.put(:context_used, prompt + completion)
      |> append(message)
      |> check_budget()
      |> save()

    if calls == [], do: end_turn(s, "no_tool_call"), else: run_calls(s)
  end

  # Halts when one of the agent's own limits is reached; tool calls already returned still run.
  defp check_budget(%{halted: nil} = s) do
    b = budget(s)

    cond do
      reached?(b.turns_used, b.max_turns) or reached?(b.tokens_used, b.max_tokens) ->
        log(s, :budget_exhausted, Map.put(b, :scope, "agent"))
        turns = used(b.turns_used, b.max_turns, "turns")

        halt(
          s,
          :budget,
          "You have used #{turns} and #{used(b.tokens_used, b.max_tokens, "tokens")}"
        )

      reached?(b.context_used, b.max_context) ->
        log(s, :budget_exhausted, Map.put(b, :scope, "context"))

        text =
          "This conversation's context has reached #{used(b.context_used, b.max_context, "tokens")}"

        halt(s, :context, text)

      true ->
        s
    end
  end

  defp check_budget(s), do: s

  # Limits and use. State saved by an older version of this module has no context fields.
  defp budget(s) do
    s
    |> Map.take([:max_turns, :max_tokens, :turns_used, :tokens_used])
    |> Map.merge(%{
      max_context: Map.get(s, :max_context, env(:agent_max_context)),
      context_used: Map.get(s, :context_used, 0)
    })
  end

  defp budget(s, scope), do: Map.put(budget(s), :scope, scope)

  # A limit of 0 means no limit.
  defp reached?(used, max), do: max > 0 and used >= max
  defp used(n, 0, unit), do: "#{n} #{unit} (no limit)"
  defp used(n, max, unit), do: "#{n} of #{max} #{unit}"
  defp limit(0), do: "unlimited"
  defp limit(max), do: max

  # Tool calls run in order; when they are done the model is called again, unless one was idle.
  defp run_calls(%{calls: []} = s) do
    cond do
      not s.idle_called -> request(s, false)
      s.wakeup_after && s.pending == [] -> end_turn(%{s | wakeup: arm_wakeup(s)}, "idle")
      true -> end_turn(s, "idle")
    end
  end

  defp run_calls(%{calls: [call | rest]} = s) do
    s = %{s | calls: rest, call_seq: s.call_seq + 1}
    name = call["function"]["name"]
    raw = call["function"]["arguments"]
    started = System.monotonic_time(:millisecond)

    args =
      cond do
        is_map(raw) -> {:ok, raw}
        raw in [nil, ""] -> {:ok, %{}}
        is_binary(raw) -> Jason.decode(raw)
        true -> :error
      end

    wakeup = with {:ok, %{} = a} <- args, do: a["wakeup_after"], else: (_ -> nil)

    logged =
      log(s, :tool_call, %{
        call_id: call["id"],
        call_seq: s.call_seq,
        name: name,
        arguments: with({:ok, a} <- args, do: a, else: (_ -> raw)),
        started_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    # No tool run whose record could not be written.
    s =
      if logged == :error and s.halted != :log_failed,
        do: halt(s, :log_failed, @log_failed),
        else: s

    skip =
      cond do
        s.idle_called ->
          "Not run: an earlier idle call in this response ended your turn."

        logged == :error or s.halted == :log_failed ->
          "Not run: the harness log could not be written."

        true ->
          nil
      end

    case {name, args} do
      _ when skip != nil ->
        run_calls(tool_result(s, call, started, false, skip))

      {"eval", {:ok, %{"code" => code}}} when is_binary(code) ->
        # The agent owns the capture device, so output and spawned processes survive a timeout.
        {:ok, io} = StringIO.open("")

        s =
          save(%{
            s
            | status: :running_tool,
              task: %{kind: :eval, n: s.call_seq, call: call, started: started, io: io}
          })

        args = [code, Keyword.put(s.bindings, :me, self()), io]
        task = Task.Supervisor.async_nolink(Nano.EvalSupervisor, __MODULE__, :eval, args)

        Process.send_after(self(), {s.tag, :eval_timeout, task.ref}, env(:eval_timeout_ms))
        %{s | task: Map.put(s.task, :task, task)}

      {"idle", {:ok, %{}}} when is_nil(wakeup) or wakeup in 0..4_294_967_295 ->
        s = tool_result(s, call, started, true, "")
        run_calls(%{s | idle_called: true, wakeup_after: wakeup})

      {"idle", {:ok, %{}}} ->
        run_calls(
          tool_result(
            s,
            call,
            started,
            false,
            "Error: wakeup_after must be an integer from 0 to 4294967295 (ms)."
          )
        )

      _ ->
        error =
          "Error: cannot call #{inspect(name)} with arguments #{inspect(raw)}. Tools: eval(code), idle(wakeup_after)."

        run_calls(tool_result(s, call, started, false, error))
    end
  end

  defp arm_wakeup(s) do
    id = make_ref()
    Process.send_after(self(), {s.tag, :wakeup, id}, s.wakeup_after)
    id
  end

  ## Compaction

  @doc """
  The current transcript's hash, as `compact/3` takes it for `expected_transcript_hash:`.
  Read it, summarize, then compact with the guard: if the agent's history changed in between,
  the compaction returns `{:error, :stale}` instead of overwriting the newer history.
  """
  def transcript_hash(name)

  def transcript_hash(name) when is_binary(name) do
    case Nano.StateStore.get(name) do
      %{transcript: transcript} -> hash_transcript(transcript)
      _ -> nil
    end
  end

  def transcript_hash(%{transcript: transcript}), do: hash_transcript(transcript)

  defp hash_transcript(transcript) when is_list(transcript), do: :erlang.phash2(transcript)

  defp validate_compaction(summary, opts) do
    cond do
      not is_binary(summary) ->
        {:error, :invalid_summary}

      byte_size(summary) not in 1..@compact_max_summary ->
        {:error, :invalid_summary}

      not String.valid?(summary) or String.trim(summary) == "" ->
        {:error, :invalid_summary}

      not is_list(opts) ->
        {:error, :invalid_option}

      not Keyword.keyword?(opts) ->
        {:error, :invalid_option}

      Enum.any?(opts, fn {k, v} ->
        case k do
          :expected_transcript_hash -> not (is_integer(v) and v >= 0 and v < 134_217_728)
          :retained -> not is_list(v)
          _ -> true
        end
      end) ->
        {:error, :invalid_option}

      true ->
        :ok
    end
  end

  # Check identities, ordering and uniqueness, not merely equal counts.
  defp paired_transcript?(transcript) do
    Enum.reduce_while(transcript, {MapSet.new(), MapSet.new()}, fn message, {pending, seen} ->
      case message do
        %{"role" => "assistant", "tool_calls" => calls} when is_list(calls) ->
          ids =
            Enum.map(calls, fn
              %{"id" => id} -> id
              _ -> nil
            end)

          if MapSet.size(pending) == 0 and Enum.all?(ids, &is_binary/1) and
               length(ids) == MapSet.size(MapSet.new(ids)) and
               Enum.all?(ids, &(not MapSet.member?(seen, &1))) do
            {:cont, {MapSet.new(ids), MapSet.union(seen, MapSet.new(ids))}}
          else
            {:halt, :invalid}
          end

        %{"role" => "tool", "tool_call_id" => id} ->
          if MapSet.member?(pending, id),
            do: {:cont, {MapSet.delete(pending, id), seen}},
            else: {:halt, :invalid}

        _ ->
          if MapSet.size(pending) == 0, do: {:cont, {pending, seen}}, else: {:halt, :invalid}
      end
    end)
    |> case do
      {pending, _} -> MapSet.size(pending) == 0
      _ -> false
    end
  end

  # Rewrites the transcript to a single summary message, keeping everything else. The summary
  # is the first user message of the new history and is treated as a normal delivery from then
  # on; the next turn's notes and events, if any, follow it. Logged as its own entry so the
  # durable record shows that and why the history was rewritten; tool calls in the old
  # transcript are kept as a count in the log, and no call is left unanswered.
  defp do_compact(s, summary, opts) do
    {calls, results} = count_calls(s.transcript)
    before = length(s.transcript)

    # A valid transcript: the summary stands in for the conversation the model no longer sees.
    # Every recorded tool call already had its result (checked below); the new history has none,
    # so pairing cannot break. The events received but not yet delivered are left in :pending.
    text =
      "<harness>Earlier in this conversation, an operator compacted your history to keep within " <>
        "the context budget. The summary that replaced it:</harness>\n\n" <> summary

    logged =
      log(s, :compacted, %{
        summary: summary,
        transcript_hash_before: hash_transcript(s.transcript),
        transcript_before: before,
        transcript_after: 1,
        tool_calls: calls,
        tool_results: results,
        context_used_before: budget(s).context_used,
        pending_events: length(s.pending),
        retained: Keyword.get(opts, :retained, []),
        approx_input_tokens: div(byte_size(s.system_prompt) + byte_size(summary) + 64, 4)
      })

    # The provider measures the context from the prompt it is sent; with a one-message history
    # the size is the system prompt plus this message (approximated at 4 bytes per token, as
    # the request path does), so the budget check is honest about the new, small context.
    # The provider measures the context from the prompt it is sent; the next request is the
    # system prompt plus this one message, so the budget reflects the new, small history.
    messages = [
      %{"role" => "system", "content" => s.system_prompt},
      %{"role" => "user", "content" => text}
    ]

    context = approx_tokens(messages)

    if logged == :ok do
      {:ok, %{s | transcript: [%{"role" => "user", "content" => text}], context_used: context}}
    else
      {:error, :log_failed}
    end
  end

  # Counts assistant tool calls and tool results in the transcript, so the log can show that
  # the compaction kept every call paired. `unanswered/1` already finds a dangling call (the
  # case a crash leaves behind); compaction is idle-only, so none should remain.
  defp count_calls(transcript) do
    {calls, results} =
      Enum.reduce(transcript, {0, 0}, fn
        %{"tool_calls" => calls}, {c, r} when is_list(calls) -> {c + length(calls), r}
        %{"role" => "tool"}, {c, r} -> {c, r + 1}
        _, acc -> acc
      end)

    {calls, results}
  end

  defp end_turn(s, reason) do
    log(s, :turn_ended, %{reason: reason})
    maybe_start_turn(%{s | status: :idle, calls: [], idle_called: false})
  end

  @doc """
  Evaluates `code` against `bindings` in the calling process, with IO captured through a
  `StringIO` group leader and compiler diagnostics collected. Never raises. Returns
  `{result, output, spawned}`:

    * `result`: `{:ok, inspected_value, new_bindings}` or `{:error, formatted}`, where
      `formatted` reads as IEx would show it: the blamed exception banner, any compiler
      diagnostics, then the stacktrace of the evaluated code and what it called
    * `output`: captured IO, followed on success by any compiler warnings
    * `spawned`: pids of processes the code started that are still alive; their later
      output goes to the caller's group leader

  The harness itself runs `eval/3` in a task with a device it owns, so that it also gets the
  output and the processes of an eval that times out.
  """
  def run_eval(code, bindings) do
    gl = Process.group_leader()
    {:ok, io} = StringIO.open("")
    result = eval(code, bindings, io)
    Process.group_leader(self(), gl)
    {output, spawned} = release(io, gl, self())

    case result do
      {:ok, value, bindings, warnings} -> {{:ok, value, bindings}, output <> warnings, spawned}
      error -> {error, output, spawned}
    end
  end

  @doc false
  # {:ok, inspected, bindings, warnings} | {:error, formatted}, with io as the group leader.
  def eval(code, bindings, io) do
    Process.group_leader(self(), io)

    # Compiler errors and warnings would go to stderr, out of the model's sight; collect them.
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {value, bindings} = Code.eval_string(code, bindings)
          {:ok, inspect(value, [pretty: true] ++ inspect_opts()), bindings}
        catch
          kind, reason -> {:error, kind, reason, __STACKTRACE__}
        end
      end)

    diagnostics = Enum.map_join(diagnostics, &"#{&1.severity}: #{&1.message}#{where(&1)}\n")

    case result do
      {:ok, value, bindings} -> {:ok, value, bindings, diagnostics}
      {:error, kind, reason, stack} -> {:error, format_error(kind, reason, stack, diagnostics)}
    end
  end

  # Closes an eval's capture device and returns what was written to it, first pointing the
  # processes the eval started (all that still use the device) at gl.
  defp release(io, gl, eval_pid) do
    spawned = adopt(io, gl, eval_pid)

    # The eval may have closed (or otherwise ended) its own device.
    output =
      try do
        {:ok, {_, output}} = StringIO.close(io)
        output
      catch
        :exit, _ -> ""
      end

    {output, spawned}
  end

  # Points the processes still using device io (other than eval_pid) at gl; returns them.
  defp adopt(io, gl, eval_pid \\ nil) do
    for p <- Process.list(),
        p != eval_pid,
        Process.info(p, :group_leader) == {:group_leader, io} do
      try do
        Process.group_leader(p, gl)
      catch
        _, _ -> :ok
      end

      p
    end
  end

  # As IEx.Evaluator does: blame the exception for a richer message, and show the stack of the
  # evaluated code and what it called. Diagnostics go straight under the banner, where
  # truncation cannot reach them first.
  defp format_error(kind, reason, stack, diagnostics) do
    {reason, stack} =
      case reason do
        %CompileError{file: "nofile", description: "cannot compile file" <> _} ->
          {%CompileError{description: "cannot compile code"}, []}

        _ ->
          Exception.blame(kind, reason, stack)
      end

    # From the outside in: drop the harness and evaluator frames at the bottom (stacks are cut
    # at 8 frames, so there may be none), then Elixir's compiler internals anywhere; the
    # evaluated code's own "(file)" frames stay.
    frames =
      stack
      |> Enum.reverse()
      |> Enum.drop_while(&(elem(&1, 0) in [NanoAgent, Code, Task.Supervised] or internal?(&1)))
      |> Enum.reverse()
      |> Enum.reject(&internal?/1)

    stacktrace = if frames == [], do: "", else: Exception.format_stacktrace(frames)
    Exception.format_banner(kind, reason, stack) <> "\n" <> diagnostics <> stacktrace
  end

  defp internal?({:elixir_compiler, :__FILE__, _, _}), do: false

  defp internal?({mod, _, _, _}),
    do:
      mod in [:elixir, :erl_eval, Module.ParallelChecker] or
        match?("elixir_" <> _, Atom.to_string(mod))

  defp where(%{file: file, position: position}) do
    line = with {line, _column} <- position, do: line

    cond do
      file not in [nil, "nofile"] -> " (#{Path.relative_to_cwd(file)}:#{line})"
      is_integer(line) and line > 0 -> " (line #{line})"
      true -> ""
    end
  end

  defp eval_done(s, %{call: call, started: started, io: io, task: task}, result) do
    {output, spawned} = release(io, Process.group_leader(), task.pid)
    s = %{s | spawned: s.spawned ++ spawned}

    case result do
      {:ok, value, bindings, warnings} ->
        Nano.StateStore.put_bindings(s.name, bindings)
        tool_result(%{s | bindings: bindings}, call, started, true, value, output <> warnings)

      {:error, error} ->
        tool_result(s, call, started, false, error, output)

      :timeout ->
        timeout = "Timeout: the eval was killed after #{env(:eval_timeout_ms)} ms."
        tool_result(s, call, started, false, timeout, output)

      {:exit, reason} ->
        tool_result(s, call, started, false, inspect({:exit, reason}, inspect_opts()), output)
    end
    |> save()
    |> run_calls()
  end

  # The model sees the result followed by any captured IO, truncated as a whole; the log
  # keeps result and IO apart for the dashboard.
  defp tool_result(s, call, started, ok, result, io \\ "") do
    whole = if io == "", do: result, else: result <> "\n\nCaptured IO:\n" <> io
    {text, truncated, spill} = truncate(whole, {s.id, "call-#{s.call_seq}"})

    log(
      s,
      :tool_result,
      spilled(spill, %{
        call_id: call["id"],
        name: call["function"]["name"],
        duration_ms: System.monotonic_time(:millisecond) - started,
        ok: ok,
        result: elem(truncate(result), 0),
        io: elem(truncate(io), 0),
        truncated: truncated
      })
    )

    append(s, tool_message(call, text))
  end

  defp tool_message(call, text),
    do: %{"role" => "tool", "tool_call_id" => call["id"], "content" => text}

  ## Helpers

  defp append(s, message), do: %{s | transcript: s.transcript ++ [message]}
  # The request-size estimate the harness uses throughout: bytes of the encoded messages at
  # ~4 bytes per token. Used for a request's logged approx_input_tokens and for the context a
  # compaction leaves.
  defp approx_tokens(messages), do: div(byte_size(Jason.encode!(messages)), 4)

  # The most of an event or result that is printed and kept in a spill file.
  @ceiling 8_388_608

  # Cuts text at RESULT_MAX_BYTES: {text, cut?, spill path}. Given a spill name, the whole
  # text (up to @ceiling bytes) is first written to <spill_dir>/<agent id>/<name>.txt and
  # the marker names it.
  defp truncate(text, spill \\ nil) do
    text = if String.valid?(text), do: text, else: inspect(text)
    {max, size} = {env(:result_max_bytes), byte_size(text)}

    if size <= max do
      {text, false, nil}
    else
      kept = if size > @ceiling, do: prefix(text, @ceiling), else: text
      path = spill && spill(spill, kept)

      marker =
        cond do
          path && size > @ceiling ->
            "[cut at #{max} bytes; the whole text was over #{@ceiling} bytes, and the first " <>
              "#{byte_size(kept)} are in #{path}]"

          path ->
            "[cut at #{max} of #{size} bytes; the whole text is in #{path}]"

          true ->
            "[truncated at #{max} bytes]"
        end

      {prefix(text, max) <> "\n" <> marker, true, path}
    end
  end

  # The longest valid UTF-8 prefix of text of at most n bytes.
  defp prefix(text, n) do
    case :unicode.characters_to_binary(binary_part(text, 0, n)) do
      {_, valid, _} -> valid
      valid -> valid
    end
  end

  defp spill({id, name}, text) do
    path = Path.expand(Path.join([env(:spill_dir), id, name <> ".txt"]))

    with :ok <- File.mkdir_p(Path.dirname(path)), :ok <- File.write(path, text) do
      path
    else
      {:error, reason} ->
        Logger.error(
          "#{id}: could not keep the whole of a cut text in #{path}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp spilled(nil, fields), do: fields
  defp spilled(path, fields), do: Map.put(fields, :spill, path)

  # A short rendering of an exit reason or error, for notes: harness stacktraces stay in the log.
  defp brief(term) do
    text = if is_binary(term), do: term, else: inspect(term, limit: 10, printable_limit: 300)
    if String.length(text) > 300, do: String.slice(text, 0, 300) <> "…", else: text
  end

  # Bounded only where the printed text would pass @ceiling anyway (a printed item takes at
  # least 2 bytes), so truncate/2 can tell when it was: an event or result is never printed
  # much past 8 MB, in the agent or in an eval task.
  defp inspect_opts, do: [limit: div(@ceiling, 2), printable_limit: @ceiling]

  # Best effort: a log that cannot be written must not take the agent down.
  # :ok, or :error when the entry could not be written to disk (Nano.Log still broadcasts it).
  defp log(s, type, fields) do
    if Map.has_key?(Nano.Log.write(s, type, fields), :log_error), do: :error, else: :ok
  catch
    kind, reason ->
      Logger.error("#{s.name}: could not log #{type}: " <> Exception.format_banner(kind, reason))
      :error
  end

  # Bindings are saved apart, when an eval changes them (Nano.StateStore.put_bindings/2).
  defp save(s) do
    s = %{s | spawned: Enum.filter(s.spawned, &Process.alive?/1)}
    Nano.StateStore.put(s.name, Map.delete(s, :bindings))
    s
  end

  defp noreply(s), do: {:noreply, save(s)}

  defp env(key), do: Application.fetch_env!(:nano, key)
end

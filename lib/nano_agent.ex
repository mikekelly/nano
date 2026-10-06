defmodule NanoAgent do
  @moduledoc """
  One LLM agent as a GenServer (SPEC.md "Agent GenServer"). The harness does three things:
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

  @template ~S"""
  I am the GenServer you are running in: deterministic code, not a person, so I
  can't converse with you. Everything on the other side of this conversation
  comes from me: an <event> relays a message that arrived in your process's
  mailbox, and a <harness> note is something I am telling you myself.

  Nothing you write in a response reaches whoever sent you a message, or any
  other process. I am deterministic code: all I do with your words is log
  them, and the people who run this node may read that log later.

  You are process {{pid}}, named "{{name}}", on BEAM node {{node}}
  ({{otp_release}}, Elixir {{elixir_version}}). The variable `me` holds your pid.

  Any message sent to your process is relayed to you as an <event>. Erlang
  messages carry no sender, so you only know where one came from if its
  contents say so. An event shows the message as Elixir prints it, and that
  is not always valid Elixir source: a pid is printed as #PID<0.123.0>, and
  in source code a # begins a comment. Messages that arrive while you are
  working are queued and delivered together when your current turn ends.

  You have two tools. eval runs Elixir code on this node and returns the
  result. The code must be valid Elixir source, exactly as it would have to
  be in a file: anything else fails to compile, and you get the error back
  instead of a result. Variables you bind persist between calls, and Erlang
  modules are available as atoms. idle ends your turn; I will wake you when the next
  message arrives. Optionally pass wakeup_after (milliseconds) and I will
  wake you after that long if no message arrives first. If you respond without calling a tool, that also ends
  your turn. Running code with eval is the only way you can affect anything
  outside this conversation: to reach another process, send it a message
  from eval.

  This node runs in a disposable Docker container. You run as {{os_user}}
  on {{os}}. Network access: {{network_policy}}. Your limits: {{max_turns}}
  turns, {{max_tokens}} tokens in total, and a context of {{max_context}}
  tokens. Each call to the model counts as one turn, tokens are counted
  across all calls, and the context is the size of this conversation, which
  only grows. When a limit is reached I stop calling the model. Whenever I
  deliver events or a note of my own, I tell you how much of each you have
  used.

  If your process dies, I restart it, restore your history and bindings,
  and tell you what happened. Your pid will change; your name will not.

  The source code for this node, including your own module, is in /app
  (a git repository). Modules can be recompiled and reloaded while the
  node runs.
  """

  @log_failed "I could not write the harness log, the durable record of what you do"

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
  `system_prompt:` (a template replacing the default; same `{{placeholders}}`), `max_turns:`,
  `max_tokens:`, `max_context:` (non-negative integers; 0 means no limit), `reasoning:` (one of `reasoning_levels/0`, default
  `REASONING`). Returns `{:error, :invalid_name | :invalid_option |
  :missing_model | :missing_openrouter_api_key}` or the supervisor's result.
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

      env(:openrouter_api_key) in [nil, ""] ->
        {:error, :missing_openrouter_api_key}

      true ->
        spec = {__MODULE__, Keyword.merge(opts, model: model, id: new_id(name))}

        case DynamicSupervisor.start_child(Nano.AgentSupervisor, spec) do
          :ignore -> {:error, :start_failed}
          result -> result
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
      Enum.all?([:model, :system_prompt], &(opts[&1] == nil or is_binary(opts[&1])))
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
  while the agent is busy or suspended. `halted` is nil, `:budget`, `:node_budget`,
  `:restart_brake`, `:start_failed` or `:log_failed`; `cache_hit_rate` is nil until the first
  response.
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
      opts = s |> Map.take(keys) |> Map.put(:system_prompt, s.template) |> Keyword.new()
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
      template: opts[:system_prompt],
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

    log(
      s,
      :agent_started,
      Map.take(s, [:id, :name, :pid, :model, :reasoning, :system_prompt])
      |> Map.put(:restarted, false)
    )

    if opts[:start_idle] == false,
      do: note(s, "Your process has just started. No message has arrived yet."),
      else: s
  end

  defp restore(saved) do
    reason = Nano.StateStore.exit_reason(saved.name, saved.pid) || :unknown
    kill_tasks(saved.pid)
    now = System.monotonic_time(:millisecond)
    restarts = Enum.filter([now | saved.restarts], &(&1 > now - 60_000))
    brake? = saved.halted == nil and length(restarts) >= 3

    # An eval in flight when the process died left its spawned processes on a dead device.
    orphans = with %{io: io} <- saved.task, do: adopt(io, Process.group_leader()), else: (_ -> [])

    s = %{
      new_process(saved)
      | restart_count: saved.restart_count + 1,
        restarts: restarts,
        spawned: saved.spawned ++ orphans
    }

    s = %{s | system_prompt: render(s)}
    started = Map.take(s, [:id, :name, :pid, :model, :reasoning, :system_prompt, :restart_count])

    log(
      s,
      :agent_started,
      Map.merge(started, %{
        restarted: true,
        exit_reason: brief(reason),
        halted: if(brake?, do: :restart_brake, else: s.halted)
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
        "Your process exited with reason #{brief(reason)} #{doing(saved)} and was restarted. " <>
          "Your pid is now #{inspect(self())}; your registered name is unchanged."
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
      "max_context" => limit(budget(s).max_context)
    }

    Enum.reduce(vars, s.template || @template, fn {k, v}, acc ->
      String.replace(acc, "{{#{k}}}", to_string(v))
    end)
  end

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

  @impl true
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
    {text, truncated} = truncate(inspect(term, inspect_opts()))
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    s = %{
      s
      | event_seq: seq,
        wakeup: nil,
        pending: s.pending ++ [~s(<event seq="#{seq}" at="#{at}">#{text}</event>)]
    }

    # queue_length: events waiting for the next turn, this one included.
    queued = Enum.count(s.pending, &String.starts_with?(&1, "<event"))

    log(s, :event_received, %{
      event_seq: seq,
      message: text,
      queue_length: queued,
      truncated: truncated
    })

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
        size = div(byte_size(Jason.encode!(messages)), 4)
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

    case Nano.OpenRouter.chat(model, messages, @tools, reasoning) do
      {:ok, response} ->
        {:ok, Map.put(response, :latency_ms, System.monotonic_time(:millisecond) - started)}

      {:error, error} ->
        retry = attempt < 3 and Nano.OpenRouter.transient?(error)

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
    {text, truncated} =
      truncate(if io == "", do: result, else: result <> "\n\nCaptured IO:\n" <> io)

    log(s, :tool_result, %{
      call_id: call["id"],
      name: call["function"]["name"],
      duration_ms: System.monotonic_time(:millisecond) - started,
      ok: ok,
      result: elem(truncate(result), 0),
      io: elem(truncate(io), 0),
      truncated: truncated
    })

    append(s, tool_message(call, text))
  end

  defp tool_message(call, text),
    do: %{"role" => "tool", "tool_call_id" => call["id"], "content" => text}

  ## Helpers

  defp append(s, message), do: %{s | transcript: s.transcript ++ [message]}

  defp truncate(text) do
    text = if String.valid?(text), do: text, else: inspect(text)
    max = env(:result_max_bytes)

    if byte_size(text) <= max do
      {text, false}
    else
      head =
        case :unicode.characters_to_binary(binary_part(text, 0, max)) do
          {_, valid, _} -> valid
          valid -> valid
        end

      {head <> "\n[truncated at #{max} bytes]", true}
    end
  end

  # A short rendering of an exit reason or error, for notes: harness stacktraces stay in the log.
  defp brief(term) do
    text = if is_binary(term), do: term, else: inspect(term, limit: 10, printable_limit: 300)
    if String.length(text) > 300, do: String.slice(text, 0, 300) <> "…", else: text
  end

  defp inspect_opts, do: [limit: 500, printable_limit: env(:result_max_bytes)]

  # Best effort: a log that cannot be written must not take the agent down.
  # :ok, or :error when the entry could not be written to disk (Nano.Log still broadcasts it).
  defp log(s, type, fields) do
    if Map.has_key?(Nano.Log.write(s, type, fields), :log_error), do: :error, else: :ok
  catch
    kind, reason ->
      Logger.error("#{s.name}: could not log #{type}: " <> Exception.format_banner(kind, reason))
      :error
  end

  defp save(s) do
    s = %{s | spawned: Enum.filter(s.spawned, &Process.alive?/1)}
    Nano.StateStore.put(s.name, s)
    s
  end

  defp noreply(s), do: {:noreply, save(s)}

  defp env(key), do: Application.fetch_env!(:nano, key)
end

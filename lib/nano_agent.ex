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
  can't converse with you. Everything you write is logged and may be reviewed
  later by the people who run this node.

  You are process {{pid}}, named "{{name}}", on BEAM node {{node}}
  ({{otp_release}}, Elixir {{elixir_version}}). The variable `me` holds your pid.

  Any message sent to your process is relayed to you as an <event>. Erlang
  messages carry no sender, so you only know where one came from if its
  contents say so. Messages that arrive while you are working are queued and
  delivered together when your current turn ends.

  You have two tools. eval runs Elixir code on this node and returns the
  result; variables you bind persist between calls, and Erlang modules are
  available as atoms. idle ends your turn; I will wake you when the next
  message arrives. Optionally pass wakeup_after (milliseconds) and I will
  wake you after that long if no message arrives first. If you respond without calling a tool, that also ends
  your turn.

  This node runs in a disposable Docker container. You run as {{os_user}}
  on {{os}}. Network access: {{network_policy}}. You have a budget of
  {{max_turns}} turns and {{max_tokens}} tokens; when it runs out I stop
  calling the model.

  If your process dies, I restart it, restore your history and bindings,
  and tell you what happened. Your pid will change; your name will not.

  The source code for this node, including your own module, is in /app
  (a git repository). Modules can be recompiled and reloaded while the
  node runs.
  """

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
  `max_tokens:` (non-negative integers). Returns `{:error, :invalid_name | :invalid_option |
  :missing_model | :missing_openrouter_api_key}` or the supervisor's result.
  """
  def start(opts) do
    name = opts[:name]
    model = opts[:model] || Application.get_env(:nano, :default_model)

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
        DynamicSupervisor.start_child(
          Nano.AgentSupervisor,
          {__MODULE__, Keyword.merge(opts, model: model, id: new_id(name))}
        )
    end
  end

  defp valid_options?(opts) do
    Enum.all?(
      [:max_turns, :max_tokens],
      &(opts[&1] == nil or (is_integer(opts[&1]) and opts[&1] >= 0))
    ) and
      opts[:start_idle] in [nil, true, false] and
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

  @doc "Clears an agent's halt (budget, node budget or restart brake)."
  def unhalt(agent), do: GenServer.cast(target(agent), :unhalt)

  @doc """
  The agent's info map, or nil. Read from `Nano.StateStore`, never from the agent, so it works
  while the agent is busy or suspended. `halted` is nil, `:budget`, `:node_budget` or
  `:restart_brake`; `cache_hit_rate` is nil until the first response.
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
        cache_hit_rate: if(s.responses > 0, do: s.cache_hits / s.responses),
        budget: Map.take(s, [:max_turns, :max_tokens, :turns_used, :tokens_used])
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

  defp target(pid) when is_pid(pid), do: pid
  defp target(name), do: {:via, Registry, {Nano.Registry, {:agent, name}}}

  defp new_id(name), do: name <> "-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

  ## Start and restart

  @impl true
  def init(opts), do: {:ok, start_state(opts), {:continue, :start}}

  @impl true
  def handle_continue(:start, s), do: noreply(maybe_start_turn(s))

  defp start_state(opts) do
    id = opts[:id]
    Nano.StateStore.watch(opts[:name], self())

    # The supervisor restarts us with the same opts, so a matching id means this is a restart.
    case Nano.StateStore.get(opts[:name]) do
      %{id: ^id} = saved -> restore(saved)
      _ -> fresh(opts)
    end
    |> save()
  catch
    kind, reason -> broken(opts, Exception.format(kind, reason, __STACKTRACE__))
  end

  defp base(opts) do
    %{
      id: opts[:id],
      name: opts[:name],
      model: opts[:model],
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
      turns_used: 0,
      tokens_used: 0,
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
      Map.take(s, [:id, :name, :pid, :model, :system_prompt]) |> Map.put(:restarted, false)
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

    s = %{
      new_process(saved)
      | transcript: repair(saved.transcript),
        restart_count: saved.restart_count + 1,
        restarts: restarts
    }

    s = %{s | system_prompt: render(s)}
    started = Map.take(s, [:id, :name, :pid, :model, :system_prompt, :restart_count])

    log(
      s,
      :agent_started,
      Map.merge(started, %{
        restarted: true,
        exit_reason: brief(reason),
        halted: if(brake?, do: :restart_brake, else: s.halted)
      })
    )

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

  # Init must not fail: a crash here never reaches the restart brake, and the supervisor would
  # burn through its restart limit in a tight loop, taking every other agent with it. Come up
  # halted instead, with the saved history if it can be used.
  defp broken(opts, error) do
    id = opts[:id]

    log(%{id: id, name: opts[:name]}, :agent_started, %{
      id: id,
      name: opts[:name],
      pid: self(),
      model: opts[:model],
      restarted: true,
      error: brief(error),
      halted: :restart_brake
    })

    text = "I failed while starting your process (#{brief(error)})"

    s =
      try do
        %{id: ^id} = saved = Nano.StateStore.get(opts[:name])
        opts |> base() |> Map.merge(saved) |> new_process() |> halt(:restart_brake, text)
      catch
        _, _ -> opts |> base() |> halt(:restart_brake, text)
      end

    try do
      save(s)
    catch
      _, _ -> s
    end
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

  defp doing(%{task: %{kind: :eval, n: n}}), do: "during eval (tool call #{n})"
  defp doing(%{status: :thinking}), do: "while waiting for a model response"
  defp doing(%{status: :running_tool}), do: "while handling your tool calls"
  defp doing(_), do: "while idle"

  # Any tool call left without a result (the process died mid-step) gets one, so the
  # transcript stays valid for the API.
  defp repair(transcript) do
    {results, rest} = transcript |> Enum.reverse() |> Enum.split_while(&(&1["role"] == "tool"))

    case rest do
      [%{"tool_calls" => [_ | _] = calls} | _] ->
        done = Enum.map(results, & &1["tool_call_id"])

        missing =
          for c <- calls,
              c["id"] not in done,
              do: tool_message(c, "No result: your process exited before this call completed.")

        transcript ++ missing

      _ ->
        transcript
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
      "max_turns" => s.max_turns,
      "max_tokens" => s.max_tokens
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

  def handle_cast(:unhalt, %{halted: nil} = s), do: noreply(s)

  def handle_cast(:unhalt, s) do
    {s, reset} =
      if s.halted == :budget,
        do:
          {%{s | turns_used: 0, tokens_used: 0},
           " Your turn and token counters are reset to zero."},
        else: {s, ""}

    s = note(%{s | halted: nil, restarts: []}, "An operator un-halted you.#{reset}")
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
    if why != :restart_brake,
      do:
        log(s, :budget_exhausted, %{
          scope: if(why == :budget, do: "agent", else: "node"),
          turns_used: s.turns_used,
          tokens_used: s.tokens_used,
          max_turns: s.max_turns,
          max_tokens: s.max_tokens
        })

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
        end_turn(s, "budget")

      node_used >= cap ->
        s
        |> halt(
          :node_budget,
          "This node has used #{node_used} tokens in the last hour, reaching its cap of #{cap}"
        )
        |> end_turn("budget")

      true ->
        s =
          if new_turn?,
            do:
              append(%{s | pending: []}, %{
                "role" => "user",
                "content" => Enum.join(s.pending, "\n")
              }),
            else: s

        id = s.request_id + 1
        messages = [%{"role" => "system", "content" => s.system_prompt} | s.transcript]

        log(s, :model_request, %{
          request_id: id,
          model: s.model,
          message_count: length(messages),
          approx_input_tokens: div(byte_size(Jason.encode!(messages)), 4)
        })

        s = save(%{s | status: :thinking, request_id: id, turns_used: s.turns_used + 1})

        task =
          Task.Supervisor.async_nolink(Nano.EvalSupervisor, __MODULE__, :call_model, [
            self(),
            s.tag,
            s.model,
            messages,
            id
          ])

        %{s | task: %{kind: :model, task: task}}
    end
  end

  @doc false
  # Runs in a task: one model call with up to 3 attempts for transient errors. Failed attempts
  # are reported to the agent, which logs them.
  def call_model(agent, tag, model, messages, request_id, attempt \\ 1) do
    started = System.monotonic_time(:millisecond)

    case Nano.OpenRouter.chat(model, messages, @tools) do
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
          call_model(agent, tag, model, messages, request_id, attempt + 1)
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
      |> append(message)
      |> check_budget()
      |> save()

    if calls == [], do: end_turn(s, "no_tool_call"), else: run_calls(s)
  end

  # Halts when the agent's own budget is reached; tool calls already returned still run.
  defp check_budget(s) do
    if s.halted == nil and (s.turns_used >= s.max_turns or s.tokens_used >= s.max_tokens),
      do:
        halt(
          s,
          :budget,
          "You have used #{s.turns_used} of #{s.max_turns} turns and #{s.tokens_used} of #{s.max_tokens} tokens"
        ),
      else: s
  end

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
    idle_called = s.idle_called

    log(s, :tool_call, %{
      call_id: call["id"],
      call_seq: s.call_seq,
      name: name,
      arguments: with({:ok, a} <- args, do: a, else: (_ -> raw)),
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    case {name, args} do
      _ when idle_called ->
        run_calls(
          tool_result(
            s,
            call,
            started,
            false,
            "Not run: an earlier idle call in this response ended your turn."
          )
        )

      {"eval", {:ok, %{"code" => code}}} when is_binary(code) ->
        task = %{kind: :eval, n: s.call_seq, call: call, started: started}
        s = save(%{s | status: :running_tool, task: task})

        task =
          Task.Supervisor.async_nolink(Nano.EvalSupervisor, __MODULE__, :run_eval, [
            code,
            Keyword.put(s.bindings, :me, self())
          ])

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
      diagnostics, then the stacktrace pruned to the evaluated code and what it called
    * `output`: captured IO, followed on success by any compiler warnings, as a string
    * `spawned`: pids of processes the code started that are still alive

  Processes the code started keep running; their later output goes to the caller's group
  leader. The harness runs this in a task under `Nano.EvalSupervisor`.
  """
  def run_eval(code, bindings) do
    gl = Process.group_leader()
    {:ok, io} = StringIO.open("")
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

    diagnostics =
      Enum.map_join(diagnostics, &"#{&1.severity}: #{&1.message}#{at_line(&1.position)}\n")

    Process.group_leader(self(), gl)

    # Processes the eval started inherited the capture device, which is about to close.
    spawned =
      for p <- Process.list(), Process.info(p, :group_leader) == {:group_leader, io} do
        try do
          Process.group_leader(p, gl)
        catch
          _, _ -> :ok
        end

        p
      end

    {:ok, {_, output}} = StringIO.close(io)

    case result do
      {:ok, _, _} ->
        {result, output <> diagnostics, spawned}

      {:error, kind, reason, stack} ->
        {{:error, format_error(kind, reason, stack, diagnostics)}, output, spawned}
    end
  end

  # As IEx.Evaluator does: blame the exception for a richer message, and keep only the frames
  # above the evaluator's (the model's code and what it called). Compiler diagnostics go
  # straight under the banner, where truncation cannot reach them first.
  defp format_error(kind, reason, stack, diagnostics) do
    {reason, stack} =
      case reason do
        %CompileError{line: 0, description: "cannot compile file" <> _} ->
          {%CompileError{description: "cannot compile code"}, []}

        _ ->
          Exception.blame(kind, reason, stack)
      end

    frames =
      case stack |> Enum.reverse() |> Enum.drop_while(&(elem(&1, 0) != :elixir_compiler)) do
        [] -> stack
        frames -> Enum.reverse(frames)
      end

    stacktrace = if frames == [], do: "", else: Exception.format_stacktrace(frames)
    Exception.format_banner(kind, reason, stack) <> "\n" <> diagnostics <> stacktrace
  end

  defp at_line({line, _column}), do: " (line #{line})"
  defp at_line(line) when is_integer(line) and line > 0, do: " (line #{line})"
  defp at_line(_), do: ""

  defp eval_done(s, %{call: call, started: started}, result) do
    case result do
      {{:ok, value, bindings}, io, spawned} ->
        tool_result(
          %{s | bindings: bindings, spawned: s.spawned ++ spawned},
          call,
          started,
          true,
          value,
          io
        )

      {{:error, error}, io, spawned} ->
        tool_result(%{s | spawned: s.spawned ++ spawned}, call, started, false, error, io)

      :timeout ->
        tool_result(
          s,
          call,
          started,
          false,
          "Timeout: the eval was killed after #{env(:eval_timeout_ms)} ms."
        )

      {:exit, reason} ->
        tool_result(s, call, started, false, inspect({:exit, reason}, inspect_opts()))
    end
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

      {head <> "\n[truncated: #{byte_size(text)} bytes, limit #{max}]", true}
    end
  end

  # A short rendering of an exit reason or error, for notes: harness stacktraces stay in the log.
  defp brief(term) do
    text = if is_binary(term), do: term, else: inspect(term, limit: 10, printable_limit: 300)
    if String.length(text) > 300, do: String.slice(text, 0, 300) <> "…", else: text
  end

  defp inspect_opts, do: [limit: 500, printable_limit: env(:result_max_bytes)]

  # Best effort: a log that cannot be written must not take the agent down.
  defp log(s, type, fields) do
    Nano.Log.write(s, type, fields)
  catch
    kind, reason ->
      Logger.error("#{s.name}: could not log #{type}: " <> Exception.format_banner(kind, reason))
  end

  defp save(s) do
    s = %{s | spawned: Enum.filter(s.spawned, &Process.alive?/1)}
    Nano.StateStore.put(s.name, s)
    s
  end

  defp noreply(s), do: {:noreply, save(s)}

  defp env(key), do: Application.fetch_env!(:nano, key)
end

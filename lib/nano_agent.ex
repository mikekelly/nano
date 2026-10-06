defmodule NanoAgent do
  @moduledoc """
  One LLM agent as a GenServer (SPEC.md "Agent GenServer"). The harness does three things:
  deliver mailbox messages as events, run the model's tool calls, and log everything.

  Model requests and evals run in tasks under `Nano.EvalSupervisor` and come back as messages,
  so the agent stays responsive (and suspendable) while they run. Internal messages carry
  the task refs or a per-process `tag` ref; everything else that arrives is an event.

  State is a plain map. It is written to `Nano.StateStore` after every callback and before
  every model request and eval, and a restarted process resumes from it. Nothing in state
  is a closure, so this module can be recompiled under running agents as long as new code
  accepts the same map.
  """
  use GenServer

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
  `_`, `.`, `-`), `model:` (default `DEFAULT_MODEL`), `start_idle:` (default true),
  `system_prompt:` (a template replacing the default; same `{{placeholders}}`), `max_turns:`,
  `max_tokens:`.
  """
  def start(opts) do
    name = opts[:name]
    model = opts[:model] || Application.get_env(:nano, :default_model)

    cond do
      not (is_binary(name) and name =~ ~r/^[\w.-]+$/) ->
        {:error, :invalid_name}

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

  @doc false
  def start_link(opts),
    do:
      GenServer.start_link(__MODULE__, opts,
        name: {:via, Registry, {Nano.Registry, {:agent, opts[:name]}}}
      )

  @doc "The agent's pid, or nil (Registry lookup; no call to the agent)."
  def whereis(name) do
    case Registry.lookup(Nano.Registry, {:agent, name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Casts a term to an agent (pid or name); it arrives as an event, like a plain `send/2`."
  def notify(agent, term), do: GenServer.cast(target(agent), {:notify, term})

  @doc "Clears an agent's halt (budget or restart brake)."
  def unhalt(agent), do: GenServer.cast(target(agent), :unhalt)

  @doc """
  The agent's info map, or nil. Read from `Nano.StateStore`, never from the agent, so it works
  while the agent is busy or suspended. `cache_hit_rate` is nil until the first response.
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

  defp target(pid) when is_pid(pid), do: pid
  defp target(name), do: {:via, Registry, {Nano.Registry, {:agent, name}}}

  defp new_id(name), do: name <> "-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

  ## Start and restart

  @impl true
  def init(opts) do
    Nano.StateStore.watch(opts[:name], self())

    # The supervisor restarts us with the same opts, so a matching id means this is a restart.
    id = opts[:id]

    state =
      case Nano.StateStore.get(opts[:name]) do
        %{id: ^id} = saved -> restore(saved)
        _ -> fresh(opts)
      end

    {:ok, save(state), {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, s), do: noreply(maybe_start_turn(s))

  defp fresh(opts) do
    s = %{
      id: opts[:id],
      name: opts[:name],
      model: opts[:model],
      pid: self(),
      tag: make_ref(),
      system_prompt: nil,
      transcript: [],
      bindings: [me: self()],
      status: :idle,
      activity: :idle,
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
      model_task: nil,
      eval: nil
    }

    s = %{s | system_prompt: render(opts[:system_prompt] || @template, s)}

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
    # A model request or eval still running for the previous process has no one to report to.
    for %Task{pid: pid} <- [saved.model_task, saved.eval && saved.eval.task],
        do: Process.exit(pid, :kill)

    now = System.monotonic_time(:millisecond)
    restarts = if reason == :operator_restart, do: saved.restarts, else: [now | saved.restarts]
    restarts = Enum.filter(restarts, &(&1 > now - 60_000))

    s = %{
      saved
      | pid: self(),
        tag: make_ref(),
        transcript: repair(saved.transcript),
        bindings: Keyword.put(saved.bindings, :me, self()),
        status: :idle,
        activity: :idle,
        restart_count: saved.restart_count + 1,
        restarts: restarts,
        halted: saved.halted || if(length(restarts) >= 3, do: :restart_brake),
        calls: [],
        idle_called: false,
        wakeup: nil,
        model_task: nil,
        eval: nil
    }

    log(
      s,
      :agent_started,
      Map.take(s, [:id, :name, :pid, :model, :system_prompt, :restart_count, :halted])
      |> Map.merge(%{restarted: true, exit_reason: inspect(reason, inspect_opts())})
    )

    note(
      s,
      "Your process exited with reason #{inspect(reason, inspect_opts())} #{doing(saved.activity)} and was restarted. " <>
        "Your pid is now #{inspect(self())}; your registered name is unchanged."
    )
  end

  defp doing({:eval, n}), do: "during eval call #{n}"
  defp doing(:model_request), do: "while waiting for a model response"
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

  defp render(template, s) do
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

    Enum.reduce(vars, template, fn {k, v}, acc ->
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
    {why, s} =
      case s.halted do
        :budget ->
          {"your budget ran out. Your turn and token counters are now reset",
           %{s | turns_used: 0, tokens_used: 0}}

        :restart_brake ->
          {"your process was restarted 3 times within 60 seconds", s}
      end

    s =
      note(
        %{s | halted: nil, restarts: []},
        "An operator un-halted you. I had stopped calling the model because #{why}."
      )

    noreply(maybe_start_turn(s))
  end

  # Not internal either: a stray cast or call is relayed exactly as it arrived.
  def handle_cast(msg, s), do: noreply(event(s, {:"$gen_cast", msg}))

  @impl true
  def handle_call(msg, from, s), do: noreply(event(s, {:"$gen_call", from, msg}))

  @impl true
  def handle_info({ref, result}, %{model_task: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])
    noreply(model_done(%{s | model_task: nil}, result))
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{model_task: %Task{ref: ref}} = s) do
    error = %{status: nil, body: "model request task exited: " <> inspect(reason, inspect_opts())}

    log(
      s,
      :model_error,
      Map.merge(error, %{request_id: s.request_id, attempt: nil, retry: false})
    )

    noreply(model_done(%{s | model_task: nil}, {:error, error}))
  end

  def handle_info({ref, result}, %{eval: %{task: %Task{ref: ref}}} = s) do
    Process.demonitor(ref, [:flush])
    noreply(eval_done(s, result))
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{eval: %{task: %Task{ref: ref}}} = s),
    do: noreply(eval_done(s, {:exit, reason}))

  def handle_info(
        {tag, :eval_timeout, ref},
        %{tag: tag, eval: %{task: %Task{ref: ref} = task}} = s
      ) do
    result =
      case Task.shutdown(task, :brutal_kill) do
        nil -> :timeout
        {:ok, result} -> result
        exit -> exit
      end

    noreply(eval_done(s, result))
  end

  def handle_info({tag, :wakeup, id}, %{tag: tag, wakeup: id} = s) do
    s =
      note(
        %{s | wakeup: nil},
        "No message arrived within #{s.wakeup_after} ms, so I am waking you as you asked."
      )

    noreply(maybe_start_turn(s))
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
        pending: s.pending ++ [~s(<event seq="#{seq}" at="#{at}">#{text}</event>)],
        wakeup: nil
    }

    log(s, :event_received, %{
      event_seq: seq,
      message: text,
      queue_length: length(s.pending),
      truncated: truncated
    })

    maybe_start_turn(s)
  end

  # Harness notes go ahead of any pending events and are delivered with them.
  defp note(s, text) do
    log(s, :harness_note, %{text: text})
    %{s | pending: ["<harness>#{text}</harness>" | s.pending]}
  end

  ## The loop

  defp maybe_start_turn(%{status: :idle, halted: nil, pending: [_ | _]} = s), do: request(s, true)
  defp maybe_start_turn(s), do: s

  defp request(s, new_turn?) do
    node_used = Nano.StateStore.node_tokens_last_hour()

    cond do
      s.turns_used >= s.max_turns or s.tokens_used >= s.max_tokens ->
        exhausted(s, "agent", node_used)

      node_used >= env(:node_max_tokens_per_hour) ->
        exhausted(s, "node", node_used)

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

        s =
          save(%{
            s
            | status: :thinking,
              activity: :model_request,
              request_id: id,
              turns_used: s.turns_used + 1
          })

        task =
          Task.Supervisor.async_nolink(Nano.EvalSupervisor, __MODULE__, :call_model, [
            Map.take(s, [:id, :name]),
            s.model,
            messages,
            id
          ])

        %{s | model_task: task}
    end
  end

  defp exhausted(s, scope, node_used) do
    log(s, :budget_exhausted, %{
      scope: scope,
      turns_used: s.turns_used,
      tokens_used: s.tokens_used,
      max_turns: s.max_turns,
      max_tokens: s.max_tokens,
      node_tokens_last_hour: node_used,
      node_max_tokens_per_hour: env(:node_max_tokens_per_hour)
    })

    end_turn(%{s | halted: :budget}, "budget")
  end

  @doc false
  # Runs in a task: one model call with up to 3 attempts for transient errors.
  def call_model(agent, model, messages, request_id, attempt \\ 1) do
    started = System.monotonic_time(:millisecond)

    case Nano.OpenRouter.chat(model, messages, @tools) do
      {:ok, response} ->
        {:ok, Map.put(response, :latency_ms, System.monotonic_time(:millisecond) - started)}

      {:error, error} ->
        retry = attempt < 3 and Nano.OpenRouter.transient?(error)

        Nano.Log.write(
          agent,
          :model_error,
          Map.merge(error, %{request_id: request_id, attempt: attempt, retry: retry})
        )

        if retry do
          Process.sleep(Application.get_env(:nano, :openrouter_backoff_ms, 1_000) * attempt)
          call_model(agent, model, messages, request_id, attempt + 1)
        else
          {:error, error}
        end
    end
  end

  defp model_done(s, {:error, _}), do: end_turn(s, "error")

  defp model_done(s, {:ok, r}) do
    usage = r.usage
    prompt = usage["prompt_tokens"] || 0
    completion = usage["completion_tokens"] || 0
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0
    calls = r.message["tool_calls"] || []
    Nano.StateStore.add_node_tokens(prompt + completion)

    log(s, :model_response, %{
      request_id: s.request_id,
      latency_ms: r.latency_ms,
      finish_reason: r.finish_reason,
      text: r.message["content"],
      tool_calls: calls,
      provider: r.provider,
      prompt_tokens: prompt,
      completion_tokens: completion,
      cached_tokens: cached,
      cost: r.cost
    })

    s = %{
      s
      | tokens_used: s.tokens_used + prompt + completion,
        cost: s.cost + (r.cost || 0),
        responses: s.responses + 1,
        cache_hits: s.cache_hits + if(cached > 0, do: 1, else: 0)
    }

    s = append(s, Map.take(r.message, ["role", "content", "tool_calls"]))
    if calls == [], do: end_turn(s, "no_tool_call"), else: run_calls(%{s | calls: calls})
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
    args = if raw in [nil, ""], do: {:ok, %{}}, else: Jason.decode(raw)
    started = System.monotonic_time(:millisecond)

    log(s, :tool_call, %{
      call_id: call["id"],
      call_seq: s.call_seq,
      name: name,
      arguments: with({:ok, map} <- args, do: map, else: (_ -> raw)),
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    case {name, args} do
      {"eval", {:ok, %{"code" => code}}} when is_binary(code) ->
        s = save(%{s | status: :running_tool, activity: {:eval, s.call_seq}})

        task =
          Task.Supervisor.async_nolink(Nano.EvalSupervisor, __MODULE__, :run_eval, [
            code,
            Keyword.put(s.bindings, :me, self())
          ])

        Process.send_after(self(), {s.tag, :eval_timeout, task.ref}, env(:eval_timeout_ms))
        %{s | eval: %{task: task, call: call, started: started}}

      {"idle", {:ok, %{"wakeup_after" => ms}}} when not is_integer(ms) or ms < 0 ->
        error = "Error: wakeup_after must be a non-negative integer (ms)."
        run_calls(tool_result(s, call, started, false, error))

      {"idle", {:ok, %{} = a}} ->
        s = tool_result(s, call, started, true, "")
        run_calls(%{s | idle_called: true, wakeup_after: a["wakeup_after"]})

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
    maybe_start_turn(%{s | status: :idle, activity: :idle, calls: [], idle_called: false})
  end

  @doc false
  # Runs in a task under Nano.EvalSupervisor, with IO captured through a StringIO group leader.
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
          kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
        end
      end)

    Process.group_leader(self(), gl)

    # Processes the eval spawned inherited the capture device; send their later output to the node's.
    for p <- Process.list(), Process.info(p, :group_leader) == {:group_leader, io} do
      try do
        Process.group_leader(p, gl)
      catch
        _, _ -> :ok
      end
    end

    {:ok, {_, output}} = StringIO.close(io)
    {result, output <> Enum.map_join(diagnostics, &"#{&1.severity}: #{&1.message}\n")}
  end

  defp eval_done(%{eval: %{call: call, started: started}} = s, result) do
    s = %{s | eval: nil}

    case result do
      {{:ok, value, bindings}, io} ->
        tool_result(%{s | bindings: bindings}, call, started, true, value, io)

      {{:error, error}, io} ->
        tool_result(s, call, started, false, error, io)

      :timeout ->
        timeout = "Timeout: the eval was killed after #{env(:eval_timeout_ms)} ms."
        tool_result(s, call, started, false, timeout)

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

  defp inspect_opts, do: [limit: 500, printable_limit: env(:result_max_bytes)]

  defp log(s, type, fields), do: Nano.Log.write(s, type, fields)

  defp save(s) do
    Nano.StateStore.put(s.name, s)
    s
  end

  defp noreply(s), do: {:noreply, save(s)}

  defp env(key), do: Application.fetch_env!(:nano, key)
end

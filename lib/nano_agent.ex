defmodule NanoAgent do
  @moduledoc """
  One LLM agent as a GenServer. The harness does three things:
  deliver mailbox messages as events, run the model's tool calls, and log everything.

  Model requests and evals run in tasks under `Nano.EvalSupervisor` and come back as messages,
  so the agent stays responsive (and suspendable) while they run. Internal messages carry
  the task refs or a per-process `tag` ref; everything else that arrives is an event.

  State is a plain map. It is written to `Nano.StateStore` after every callback, after each
  model response, and before every model request and eval, and a restarted process resumes
  from it. Nothing in state is a closure, so this module can be recompiled under running
  agents as long as new code accepts the same map. `init/1` cannot fail: if restoring
  crashes, the agent comes up halted, so a broken edit cannot loop the supervisor.

  ## Where things are

  The seed's prompt sends every agent here first, so this is the front page of the node's
  code. Each entry leads further in.

    * `Nano.Tools`: bounded file read/write/edit/list/find/search and synchronous shell.
    * `Nano.Background`: independent shell jobs, durable results, completion events.
    * `Compaction`: automatic checkpoints and voluntary summaries.
    * `Nano.Web`: cached readable pages, exact evidence and Lightpanda JavaScript/CDP wrappers.
    * `Nano.Search`: bounded Exa search, cited answers and durable named-owner Agent research.
    * `Goals`: durable goal trees, reasons, status and cheap review; dashboard goals.
    * `FrontMind`: own short durable note; `Nano.ContextBob` re-shows sources by token distance.
    * `Nano.Decision`: reusable typed Jev decisions and probabilities (optional credentials).
    * `Delegation`: composed prompts, isolated sub-agents, and durable lifecycle/result events.
    * `Nano.MCP`: stdio/Streamable HTTP tools, resources, prompts and durable named subscriptions.
    * `Nano.Ops`: everything an operator can do with agents and users; the dashboard and the
      HTTP API are skins over it.
    * `Nano.Images`: immutable validated image attachments; `look(path, me)` opens a file.
    * `Nano.Model`: which provider serves a model (`Nano.ChatGPT`, `Nano.OpenRouter`) and
      what each model allows.
    * `Nano.Safety`: independent recovery watchdog, served-boot attestation and credential copies.
    * `Nano.Settings`: the node's settings: keys, limits, what new agents' prompts state.
    * `Nano.User`: named identities for people and outside agents.
    * `Nano.Log` and `Nano.StateStore`: each agent's log and its saved state.
    * `Nano.Application`: the supervision tree, and what comes back after a restart.
    * `NanoWeb.Router`: every route: the dashboard and the JSON API.
    * `/app/prompts/seed.txt`: the system prompt template, a truthful account of this module.
    * `/app/seeding-docs` and `/app/seedling-docs`: specs for capabilities to grow, and
      methods for putting a grown harness to work.
  """
  # The front page of a wiki: keep "Where things are" a short list of entry points, each
  # leading further in. Detail belongs in the modules and docs it names, which agents read
  # only when they need them.
  use GenServer
  require Logger

  @log_failed "I could not write the harness log, the durable record of what you do"

  # The least room for its response a request must leave in the context; with less, the agent
  # is halted instead of called. Enough for a tool call after some reasoning.
  @reply_room 4_096

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
  Starts an agent under `Nano.AgentSupervisor`. There are no defaults for what an agent runs on
  or may spend; these are required:

    * `name:` letters, digits, `_`, `.`, `-`
    * `model:` a slug its provider lists (`Nano.Model.check/3`)
    * `reasoning:` one of the model's reasoning levels
    * `max_turns:`, `max_tokens:` whole numbers; 0 means no limit
    * `max_context:` from 1 to the model's context window

  Optional: `start_idle:` (boolean, default true), `system_prompt:` (a template string
  replacing the default; same `{{placeholders}}`), `system_prompt_file:` (a template file,
  instead of the `system_prompt_file` setting). Returns the supervisor's result, or
  `{:error, message}` saying what was missing or wrong and what to give instead.
  """
  def start(opts) do
    name = opts[:name]

    with :ok <-
           if(is_binary(name) and name =~ ~r/^[\w.-]+$/,
             do: :ok,
             else:
               {:error,
                "name must be letters, digits, _ . or - (it is how the agent is addressed), " <>
                  "not #{inspect(name)}"}
           ),
         {:ok, entry} <- Nano.Model.check(opts[:model], opts[:reasoning], opts[:max_context]),
         :ok <- limit_option(opts, :max_turns, "the number of model calls"),
         :ok <- limit_option(opts, :max_tokens, "prompt and completion tokens, summed"),
         :ok <- other_options(opts),
         {:ok, template, file} <- template(opts) do
      more = [
        id: new_id(name),
        template: template,
        prompt_file: file,
        context_window: entry.context_length,
        input_modalities: entry[:input_modalities] || ["text"],
        max_output: entry[:max_output],
        # Called from an agent's eval: the eval task's first caller is that agent.
        started_by:
          with [pid | _] <- Process.get(:"$callers"),
               [n | _] <- for({{:agent, n}, ^pid} <- Nano.Names.all(), do: n) do
            n
          else
            _ -> nil
          end
      ]

      case DynamicSupervisor.start_child(
             Nano.AgentSupervisor,
             {__MODULE__, Keyword.merge(opts, more)}
           ) do
        :ignore -> {:error, "the agent's process failed to start; the node's log says why"}
        result -> result
      end
    end
  end

  @doc "The `reasoning:` settings an agent can be started with: `\"off\"`, then effort levels, lowest first."
  defdelegate reasoning_levels, to: Nano.OpenRouter

  defp limit_option(opts, key, what) do
    case opts[key] do
      nil -> {:error, "missing #{key}: #{what} before the agent is halted, or 0 for no limit"}
      n when is_integer(n) and n >= 0 -> :ok
      n -> {:error, "#{key} must be a whole number, 0 or more (0 = no limit), not #{inspect(n)}"}
    end
  end

  defp other_options(opts) do
    text =
      Enum.find(
        [:system_prompt, :system_prompt_file],
        &(opts[&1] != nil and not is_binary(opts[&1]))
      )

    cond do
      text -> {:error, "#{text} must be a string, not #{inspect(opts[text])}"}
      opts[:start_idle] in [nil, true, false] -> :ok
      true -> {:error, "start_idle must be true or false, not #{inspect(opts[:start_idle])}"}
    end
  end

  # The template: the agent's own string, or a file read now (and again at each restart).
  defp template(opts) do
    file =
      if opts[:system_prompt],
        do: nil,
        else: opts[:system_prompt_file] || Nano.Settings.get(:system_prompt_file)

    case if(file, do: File.read(file), else: {:ok, opts[:system_prompt]}) do
      {:ok, template} ->
        {:ok, template, file}

      {:error, e} ->
        {:error, "cannot read the system prompt file #{file}: #{:file.format_error(e)}"}
    end
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: target(opts[:name]))

  @doc "The agent's live pid, or nil (`Nano.Names` lookup; no call to the agent)."
  def whereis(name) do
    with :undefined <- Nano.Names.whereis_name({:agent, name}), do: nil
  end

  @doc "Casts a term to an agent (pid or name); it arrives as an event, like a plain `send/2`."
  def notify(agent, term), do: GenServer.cast(target(agent), {:notify, term})

  @doc "Clears an agent's halt, whatever the reason; for `:start_failed` that retries the start."
  def unhalt(agent), do: GenServer.cast(target(agent), :unhalt)

  @doc """
  Has every agent whose model's provider has been turned off (`Nano.Model.off?/1`) halt now,
  `:provider_unavailable`, rather than at its next model call. Returns `:ok`.
  """
  def check_providers do
    for name <- list(), pid = whereis(name), do: GenServer.cast(pid, :check_provider)
    :ok
  end

  @doc """
  The agent's info map, or nil. Read from `Nano.StateStore`, never from the agent, so it works
  while the agent is busy or suspended. `status` is `:idle`, `:thinking`, `:running_tool` or
  `:waiting_retry` (a model call failed and the agent will call again at `retry_at`, an
  ISO 8601 time, else nil). `halted` is nil, `:budget`, `:context`, `:node_budget`,
  `:usage_limit`, `:provider_unavailable`, `:model_refused`, `:restart_brake`, `:start_failed`
  or `:log_failed` or `:compaction_failed`; `context_window` is the model's, as its provider listed it at start (nil if
  it could not be had for an agent saved before it was recorded); `cache_hit_rate` is nil until
  the first response.
  """
  def info(name) do
    with %{} = s <- Nano.StateStore.get(name) do
      pid = whereis(name)

      %{
        id: s.id,
        name: s.name,
        pid: pid,
        model: s.model,
        input_modalities: Map.get(s, :input_modalities, ["text"]),
        status: s.status,
        retry_at:
          with(:waiting_retry <- s.status, %{at: at} <- s[:retry], do: at, else: (_ -> nil)),
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
        context_window: Map.get(s, :context_window),
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
  Starts, under `sup`, every agent saved in `Nano.StateStore` that has no live process; each
  comes back through the restart path, with its history and the options it was started with.
  """
  def revive(sup) do
    for s <- Nano.StateStore.all(), whereis(s.name) == nil do
      opts = s |> Map.take([:name, :id]) |> Keyword.new()
      DynamicSupervisor.start_child(sup, {__MODULE__, opts})
    end

    :ok
  end

  defp target(pid) when is_pid(pid), do: pid
  defp target(name), do: {:via, Nano.Names, {:agent, name}}

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
      reasoning: opts[:reasoning],
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
      pending_images: [],
      pending_image_delivery: false,
      input_modalities: opts[:input_modalities] || ["text"],
      halted: nil,
      max_turns: opts[:max_turns],
      max_tokens: opts[:max_tokens],
      max_context: opts[:max_context],
      turns_used: 0,
      tokens_used: 0,
      # The conversation's size in tokens as the provider last measured it.
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
      # Model calls failing in a row: %{failures, since, at, timer}, or nil (wait/2).
      retry: nil,
      task: nil,
      spawned: []
    }
  end

  defp fresh(opts) do
    # Not in base/1, so that a stand-in built over an entry saved before these existed still
    # lacks them, and upgrade/1 fills them in when the entry is restored.
    s =
      opts
      |> base()
      |> Map.merge(%{
        # The model's, as its provider listed them at start: the context window, which
        # max_context cannot exceed, and the most it generates in one response (or nil).
        context_window: opts[:context_window],
        max_output: opts[:max_output],
        # The size in bytes of the conversation context_used measured: what a request adds
        # is estimated from the growth since (estimate/1).
        measured_bytes: 0
      })
      |> stated()

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
    saved = saved |> upgrade() |> stated()
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

  # State saved before the model's limits were recorded at start. The window and output bound
  # come from the model's list if it can be had, and the window then caps max_context (which
  # could be 0, no limit); if it cannot, max_context is the ceiling. What the provider last
  # measured is the conversation up to its last response.
  defp upgrade(%{context_window: _} = s) do
    s =
      if Map.has_key?(s, :input_modalities) do
        s
      else
        modalities =
          with {:ok, entry} <- Nano.Model.lookup(s.model),
               do: entry[:input_modalities] || ["text"],
               else: (_ -> ["text"])

        s
        |> Map.put(:input_modalities, modalities)
        |> Map.update(:system_prompt, nil, fn prompt ->
          if prompt, do: prompt <> "\n\n" <> Nano.ImageInput.notice(modalities), else: nil
        end)
      end

    s |> Map.put_new(:pending_images, []) |> Map.put_new(:pending_image_delivery, false)
  end

  defp upgrade(s) do
    entry = with {:ok, entry} <- Nano.Model.lookup(s.model), do: entry, else: (_ -> %{})
    window = entry[:context_length]
    max = Map.get(s, :max_context, 0)
    measured = s.transcript |> Enum.reverse() |> Enum.drop_while(&(&1["role"] != "assistant"))

    Map.merge(s, %{
      context_window: window,
      input_modalities: entry[:input_modalities] || ["text"],
      pending_images: Map.get(s, :pending_images, []),
      pending_image_delivery: Map.get(s, :pending_image_delivery, false),
      max_output: entry[:max_output],
      max_context: if(window && (max == 0 or max > window), do: window, else: max),
      context_used: Map.get(s, :context_used, 0),
      measured_bytes:
        if(measured == [], do: 0, else: bytes(s.system_prompt, Enum.reverse(measured)))
    })
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
  defp doing(%{status: :waiting_retry}), do: "while waiting to call the model again"
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

  # The settings the system prompt states (and the harness then acts on) are the agent's own,
  # as they were when it started, so its prompt stays true whatever the node's become.
  # State saved before they were kept takes them from the node's settings, once restored.
  @stated [:network_policy, :result_max_bytes]

  defp stated(s), do: Enum.reduce(@stated, s, &Map.put_new(&2, &1, Nano.Settings.get(&1)))
  defp stated(s, key), do: Map.get_lazy(s, key, fn -> Nano.Settings.get(key) end)

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
      "network_policy" => stated(s, :network_policy),
      "max_turns" => limit(s.max_turns),
      "max_tokens" => limit(s.max_tokens),
      "max_context" => limit(budget(s).max_context),
      "result_max_bytes" => stated(s, :result_max_bytes)
    }

    rendered =
      Enum.reduce(vars, s.template, fn {k, v}, acc ->
        String.replace(acc, "{{#{k}}}", to_string(v))
      end)

    rendered <> "\n\n" <> Nano.ImageInput.notice(Map.get(s, :input_modalities, ["text"]))
  end

  # The template file an agent's prompt comes from, or nil for one given as a string. State
  # saved before this was recorded used the default file unless it had a string.
  defp prompt_file(s),
    do:
      Map.get_lazy(s, :prompt_file, fn ->
        if s.template, do: nil, else: Nano.Settings.get(:system_prompt_file)
      end)

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

  def handle_cast(:check_provider, s), do: noreply(check_provider(s))

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
             "#{used(b.context_used, b.max_context, "tokens")}, so unless your limit has been " <>
             "raised I will halt you again before my next call to the model, without making it."}

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

  # The wait after a failed model call is over (wait/2); the note saying so is pending.
  def handle_info(
        {tag, :retry, id},
        %{tag: tag, status: :waiting_retry, retry: %{timer: id}} = s
      ),
      do: noreply(maybe_start_turn(s))

  # Failed attempts reported by the model request task, logged here so entries stay in seq order.
  def handle_info({tag, :model_error, fields}, %{tag: tag} = s) do
    log(s, :model_error, fields)
    noreply(s)
  end

  # A stale timer (its eval finished, or an event cancelled the wakeup).
  def handle_info({tag, _, _}, %{tag: tag} = s), do: noreply(s)

  def handle_info(msg, s), do: noreply(event(s, msg))

  defp event(s, term) do
    s = upgrade(s)
    {term, images, image_notice} = Nano.ImageInput.event(term, s.input_modalities)
    visible = if "image" in s.input_modalities, do: images, else: []

    s = %{
      s
      | pending_images: s.pending_images ++ visible,
        pending_image_delivery: s.pending_image_delivery or images != [] or image_notice != ""
    }

    seq = s.event_seq + 1

    {text, truncated, spill} =
      truncate(
        inspect(term, inspect_opts()) <> image_notice,
        stated(s, :result_max_bytes),
        {s.id, "event-#{seq}"}
      )

    at = timestamp(DateTime.utc_now())

    s = %{
      s
      | event_seq: seq,
        wakeup: nil,
        pending: s.pending ++ [~s(<event seq="#{seq}" at="#{at}">#{text}</event>)]
    }

    if_child = child_report?(s.name, term)

    s =
      if if_child,
        do:
          Map.update(s, :child_reports, [List.last(s.pending)], &(&1 ++ [List.last(s.pending)])),
        else: s

    # queue_length: events waiting for the next turn, this one included.
    queued = Enum.count(s.pending, &String.starts_with?(&1, "<event"))

    log(
      s,
      :event_received,
      spilled(spill, %{
        event_seq: seq,
        message: text,
        images: images,
        queue_length: queued,
        truncated: truncated
      })
    )

    maybe_start_turn(s)
  end

  # Erlang messages have no sender. Only explicit attribution can identify child reports.
  defp child_report?(parent, %{from: from}) do
    Enum.any?(Nano.StateStore.all(), fn child ->
      child[:started_by] == parent and (child[:name] == from or child[:pid] == from)
    end)
  end

  defp child_report?(_, _), do: false

  # Harness notes queue up with events, in the order things happened.
  defp note(s, text) do
    log(s, :harness_note, %{text: text})
    %{s | pending: s.pending ++ ["<harness>#{text}</harness>"]}
  end

  # A halt also ends a wait to call the model again (an operator turned the provider off).
  defp halt(s, why, text) do
    status = if s.status == :waiting_retry, do: :idle, else: s.status

    note(
      %{s | halted: why, status: status},
      text <> ", so I have halted you: I will not call the model until an operator un-halts you."
    )
  end

  ## The loop

  # Waiting to call the model again after a failure (wait/2), the next turn need not wait for
  # the timer: a message starts it as soon as it arrives.
  defp maybe_start_turn(%{status: status, halted: nil, pending: [_ | _]} = s)
       when status in [:idle, :waiting_retry],
       do: request(s, true)

  defp maybe_start_turn(s), do: s

  defp request(s, new_turn?) do
    # State from an older version of this module, still running after a reload.
    s = s |> upgrade() |> check_provider()
    node_used = Nano.StateStore.node_tokens_last_hour()
    cap = Nano.Settings.get(:node_max_tokens_per_hour)

    cond do
      s.halted ->
        end_turn(
          s,
          if(s.halted in [:log_failed, :provider_unavailable, :model_refused],
            do: "error",
            else: "budget"
          )
        )

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

        deliver? = new_turn? or s.pending_image_delivery
        content = Nano.ImageInput.content(Enum.join(s.pending ++ [line], "\n"), s.pending_images)
        user = %{"role" => "user", "content" => content}

        next =
          if deliver?,
            do: %{
              append(s, user)
              | pending: [],
                pending_images: [],
                pending_image_delivery: false
            },
            else: s

        next = Nano.Attention.before_request(next)
        estimate = estimate(next)
        room = b.max_context - estimate

        cond do
          b.max_context > 0 and room < @reply_room ->
            s |> context_halt(estimate) |> end_turn("budget")

          b.max_context > 0 and room < min(Compaction.reserve(), div(b.max_context, 4)) ->
            start_compaction(next)

          true ->
            call(next, new_turn? && line, estimate, room)
        end
    end
  end

  # An operator can turn a provider off (remove OpenRouter's key) at any time; an agent on it
  # halts rather than fail at every call, and un-halting halts it again until it is back.
  defp check_provider(%{halted: nil} = s) do
    if Nano.Model.off?(s.model),
      do:
        halt(
          s,
          :provider_unavailable,
          "OpenRouter, the provider of your model #{s.model}, has been turned off by an " <>
            "operator: this node no longer has its API key"
        ),
      else: s
  end

  defp check_provider(s), do: s

  # Tokens a request for this conversation may take, at most: what the provider measured for
  # the conversation at its last response, plus one token for every 2 bytes it has grown by
  # since, as JSON (before a first response, all of it). Tokenizers average 3.5 to 4.5 bytes
  # a token on English and code, about 3 on JSON, hex, base64 and CJK text, so this
  # overestimates all but byte sequences built to tokenize badly; the overestimate lasts only
  # until the next response measures the conversation again.
  defp estimate(s),
    do:
      s.context_used + div(max(bytes(s.system_prompt, s.transcript) - s.measured_bytes, 0) + 1, 2)

  # The size, as JSON, of the tools and messages of a request: what the estimate scales.
  defp bytes(system_prompt, transcript),
    do:
      Nano.ImageInput.estimated_bytes([
        @tools,
        %{"role" => "system", "content" => system_prompt} | transcript
      ])

  defp context_halt(s, estimate) do
    b = budget(s)
    log(s, :budget_exhausted, Map.merge(b, %{scope: "context", estimate: estimate}))

    halt(
      s,
      :context,
      "Your next call to the model might not fit in your context of #{b.max_context} tokens: " <>
        "with what has arrived since your last response, this conversation could now be up to " <>
        "about #{estimate} tokens, which leaves less than #{@reply_room} for your reply"
    )
  end

  # Starts the model request. The response is bounded by the room left in the context (and
  # by what the model generates at most), so that the request and its response fit.
  defp call(s, line, estimate, room) do
    messages = [%{"role" => "system", "content" => s.system_prompt} | s.transcript]
    id = s.request_id + 1
    output = if s.max_context > 0, do: min(room, s.max_output || room), else: s.max_output

    fields = %{
      request_id: id,
      model: s.model,
      message_count: length(messages),
      approx_input_tokens: estimate,
      max_output: output
    }

    fields = if line, do: Map.put(fields, :budget_note, line), else: fields
    # Recorded byte for byte (Nano.RawLog): the first attempt's request file is named here.
    raw = if Nano.RawLog.on?(s.name), do: "#{s.id}/#{id}"
    fields = if raw, do: Map.put(fields, :raw, ["#{raw}-1.request.txt"]), else: fields

    # No model call whose record could not be written.
    if log(s, :model_request, fields) == :ok do
      s = save(%{s | status: :thinking, request_id: id, turns_used: s.turns_used + 1})
      # Map.get: state saved by an older version of this module has no :reasoning.
      how = {s.model, Map.get(s, :reasoning, "off"), output, raw}
      args = [self(), s.tag, how, messages, id]
      fun = if Map.has_key?(s, :compacting), do: :call_compaction_model, else: :call_model
      task = Task.Supervisor.async_nolink(Nano.EvalSupervisor, __MODULE__, fun, args)
      %{s | task: %{kind: :model, task: task}}
    else
      s |> halt(:log_failed, @log_failed) |> end_turn("error")
    end
  end

  # A model call makes up to @attempts attempts while it fails transiently (Nano.Model.chat/5),
  # pausing between them for the `openrouter_backoff_ms` app env (1 s by default), doubling,
  # or as long as the provider asks if that is longer, up to @longest_pause. If the provider
  # asks for longer, or every attempt fails, the turn ends and the harness itself calls again
  # after a wait (wait/2): the `model_wait_ms` app env (30 s by default), doubling with each
  # call that fails in a row, up to 20 times that (10 minutes), or as long as the provider
  # asks, up to a day. Pauses and waits are ±10%, so agents that failed together do not all
  # call again together.
  @attempts 3
  @longest_pause 60_000

  @doc false
  # Runs in a task: one model call, with its attempts. Failed attempts are reported to the
  # agent, which logs them; the last failure is returned with the number of attempts made.
  # With `raw` (Nano.RawLog), each attempt is recorded as "<raw>-<attempt>", and the response
  # and each failure name their attempt's files (`raw:`).
  def call_compaction_model(agent, tag, how, messages, id) do
    Process.put(:compaction_request, true)
    call_model(agent, tag, how, messages, id)
  end

  def call_model(
        agent,
        tag,
        {model, reasoning, max_output, raw} = how,
        messages,
        request_id,
        attempt \\ 1
      ) do
    started = System.monotonic_time(:millisecond)

    {result, files} =
      within_max(raw && "#{raw}-#{attempt}", fn ->
        Nano.Model.chat(model, messages, @tools, reasoning, max_output)
      end)

    case result do
      {:ok, response} ->
        response = if files != [], do: Map.put(response, :raw, files), else: response
        {:ok, Map.put(response, :latency_ms, System.monotonic_time(:millisecond) - started)}

      {:error, error} ->
        error = if files != [], do: Map.put(error, :raw, files), else: error

        pause =
          if attempt < @attempts and not Process.get(:compaction_request, false) and
               error.class == :transient,
             do: pause(error, attempt)

        send(
          agent,
          {tag, :model_error,
           Map.merge(error, %{request_id: request_id, attempt: attempt, retry: pause != nil})}
        )

        if pause do
          Process.sleep(pause)
          call_model(agent, tag, how, messages, request_id, attempt + 1)
        else
          {:error, Map.put(error, :attempts, attempt)}
        end
    end
  end

  # One attempt, recorded under `raw` (Nano.RawLog.recording/2), in a task of its own that is
  # killed once it has run for the `model_call_max_ms` setting: the attempt then fails as
  # transient, so it is retried like any other. Req's receive_timeout only bounds each wait for
  # more of the reply (10 minutes; the Codex CLI's stream idle timeout is 5,
  # DEFAULT_STREAM_IDLE_TIMEOUT_MS in codex-rs/model-provider-info/src/lib.rs), so a reply that
  # keeps trickling in would otherwise hold the agent forever. The killed task held its HTTP/1
  # connection checked out of the pool: the pool sees it die and closes that connection; its
  # idle connections are left alone.
  defp within_max(raw, fun) do
    max = Nano.Settings.get(:model_call_max_ms)
    task = Task.async(fn -> Nano.RawLog.recording(raw, fun) end)

    case Task.yield(task, max) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        body = "the model call took longer than #{duration(max)}, so I cancelled it"

        {{:error, %{status: nil, body: body, class: :transient}},
         Nano.RawLog.cancelled(raw, body)}

      # Not reached: the task is linked, so its crash is this process's.
      {:exit, reason} ->
        exit(reason)
    end
  end

  defp pause(error, attempt) do
    first = Application.get_env(:nano, :openrouter_backoff_ms, 1_000)
    backoff = jitter(first * 2 ** (attempt - 1))

    case error[:retry_after] do
      nil -> backoff
      ms when ms <= @longest_pause -> max(ms, backoff)
      _ -> nil
    end
  end

  # The wait before calling again, after `failures` calls in a row have failed.
  defp wait_ms(failures, retry_after) do
    first = Application.get_env(:nano, :model_wait_ms, 30_000)
    max(jitter(min(first * 2 ** (failures - 1), first * 20)), min(retry_after || 0, 86_400_000))
  end

  defp jitter(ms), do: round(ms * (0.9 + :rand.uniform() / 5))

  defp task_done(%{task: %{kind: :model}} = s, result), do: model_done(%{s | task: nil}, result)

  defp task_done(%{task: %{kind: :eval} = t} = s, result),
    do: eval_done(%{s | task: nil}, t, result)

  defp start_compaction(s) do
    compaction_call(Map.put(s, :compacting, %{base: s.transcript, attempt: 1, reason: nil}), nil)
  end

  defp compaction_call(s, reason) do
    s = s |> check_budget() |> check_provider()

    cond do
      s.halted ->
        end_turn(s, "budget")

      reached?(
        Nano.StateStore.node_tokens_last_hour(),
        Nano.Settings.get(:node_max_tokens_per_hour)
      ) ->
        s
        |> halt(:node_budget, "This node has reached its hourly token cap during compaction")
        |> end_turn("budget")

      true ->
        do_compaction_call(s, reason)
    end
  end

  defp do_compaction_call(s, reason) do
    s = %{
      s
      | transcript:
          s.compacting.base ++ [%{"role" => "user", "content" => Compaction.note(reason)}]
    }

    s = Nano.Attention.before_request(s)
    n = estimate(s)

    if s.max_context - n < @reply_room do
      s
      |> Map.delete(:compacting)
      |> halt(
        :compaction_failed,
        "Automatic compaction request cannot fit; full history remains in the log"
      )
      |> end_turn("error")
    else
      call(s, false, n, min(s.max_context - n, Compaction.reserve()))
    end
  end

  defp model_done(%{compacting: c} = s, result) do
    {s, parsed} =
      case result do
        {:ok, r} ->
          p = r.usage["prompt_tokens"] || 0
          o = r.usage["completion_tokens"] || 0
          Nano.StateStore.add_node_tokens(p + o)

          logged =
            log(s, :model_response, %{
              request_id: s.request_id,
              compaction: true,
              text: r.message["content"],
              tool_calls: r.message["tool_calls"] || [],
              prompt_tokens: p,
              completion_tokens: o,
              cached_tokens: get_in(r.usage, ["prompt_tokens_details", "cached_tokens"]) || 0,
              cost: r.cost,
              latency_ms: r.latency_ms,
              provider: r.provider,
              raw: r[:raw],
              finish_reason: r.finish_reason
            })

          s = if logged == :error, do: halt(s, :log_failed, @log_failed), else: s

          s = %{
            s
            | tokens_used: s.tokens_used + p + o,
              cost: s.cost + (r.cost || 0),
              responses: s.responses + 1,
              cache_hits:
                s.cache_hits +
                  if((get_in(r.usage, ["prompt_tokens_details", "cached_tokens"]) || 0) > 0,
                    do: 1,
                    else: 0
                  )
          }

          parsed =
            with [call] <- r.message["tool_calls"],
                 "eval" <- call["function"]["name"],
                 {:ok, args} <- summary_args(call["function"]["arguments"]),
                 code when is_binary(code) <- args["code"] do
              Compaction.parse(code)
            else
              _ -> {:error, "Expected exactly one eval summary call."}
            end

          {s, parsed}

        _ ->
          {s, {:error, "Model call failed: #{inspect(result)}"}}
      end

    case parsed do
      {:ok, text} ->
        s
        |> Map.put(:transcript, c.base)
        |> apply_summary(text)
        |> check_budget()
        |> then(&request(&1, &1.pending != []))

      {:error, reason} when c.attempt < 3 ->
        s
        |> Map.put(
          :compacting,
          Map.merge(c, %{
            attempt: c.attempt + 1,
            reason: if(match?({:ok, _}, result), do: reason, else: Map.get(c, :reason))
          })
        )
        |> then(&compaction_call(&1, &1.compacting.reason))

      {:error, reason} ->
        s
        |> Map.put(:transcript, c.base)
        |> Map.delete(:compacting)
        |> halt(
          :compaction_failed,
          "Automatic compaction failed after three attempts: #{reason}; full record remains in the log"
        )
        |> end_turn("error")
    end
  end

  defp model_done(s, {:exit, reason}) do
    body = "model request task exited: " <> brief(reason)

    log(s, :model_error, %{
      request_id: s.request_id,
      status: nil,
      body: body,
      class: :transient,
      attempt: nil,
      retry: false
    })

    model_done(s, {:error, %{status: nil, body: body, class: :transient}})
  end

  # The call counted, so a limit may halt the agent first. Otherwise the failure's class
  # (Nano.Model.chat/5) decides: call again after a wait, or halt and say why.
  defp model_done(s, {:error, error}) do
    s = check_budget(s)

    cond do
      s.halted -> end_turn(s, "error")
      error.class == :transient -> wait(s, error)
      true -> s |> refused(error) |> end_turn("error")
    end
  end

  defp model_done(s, {:ok, %{message: msg} = r}) do
    prompt = r.usage["prompt_tokens"] || 0
    completion = r.usage["completion_tokens"] || 0
    cached = get_in(r.usage, ["prompt_tokens_details", "cached_tokens"]) || 0
    calls = msg["tool_calls"] || []
    Nano.StateStore.add_node_tokens(prompt + completion)

    # raw: the files Nano.RawLog recorded the answering attempt in.
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
      cost: r.cost,
      raw: r[:raw]
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
      # Calls no longer fail in a row.
      |> Map.put(:retry, nil)
      |> append(message)

    s =
      %{s | measured_bytes: bytes(s.system_prompt, s.transcript)}
      |> check_budget()
      |> save()

    if calls == [], do: end_turn(s, "no_tool_call"), else: run_calls(s)
  end

  defp summary_args(a) when is_map(a), do: {:ok, a}
  defp summary_args(a) when is_binary(a), do: Jason.decode(a)
  defp summary_args(_), do: :error

  defp apply_summary(%{halted: halted} = s, _text) when not is_nil(halted), do: s

  defp apply_summary(s, text) do
    path = Path.join(Application.fetch_env!(:nano, :log_dir), s.id <> ".jsonl")

    if log(s, :compaction_completed, %{summary: text, full_record: path}) == :error do
      halt(s, :log_failed, @log_failed)
    else
      rebuild_summary(s, text, path)
    end
  end

  defp rebuild_summary(s, text, path) do
    t =
      Compaction.rebuild(s.transcript, text, s.max_context, path, Map.get(s, :child_reports, []))

    s
    |> Map.delete(:compacting)
    |> Map.merge(%{transcript: t, context_used: 0, measured_bytes: 0, child_reports: []})
    |> Nano.Attention.after_compaction()
    |> save()
  end

  defp refused(s, %{class: :usage_limit, limit: text}), do: halt(s, :usage_limit, text)

  defp refused(s, error) do
    provider = upcase_first(Nano.Model.provider(s.model))
    what = failure(error)

    case error.class do
      :auth ->
        halt(
          s,
          :provider_unavailable,
          "#{provider} refused this node's credentials for your model #{s.model} (#{what})"
        )

      :context ->
        halt(
          s,
          :context,
          "#{provider} refused my request because this conversation does not fit in the " <>
            "context of your model #{s.model} (#{what})"
        )

      :refused ->
        halt(
          s,
          :model_refused,
          "#{provider} refused my request to your model #{s.model} as invalid, and sending " <>
            "it again would not change that (#{what})"
        )
    end
  end

  # A failure that may pass ends the turn, but the agent is not left idle: it is told, and I
  # wake it myself after a wait (wait_ms/2), with the same request and the note, or sooner if a
  # message arrives (maybe_start_turn/1). The wait grows until a call succeeds.
  defp wait(s, error) do
    what = failure(error)
    r = Map.get(s, :retry) || %{failures: 0, since: timestamp(DateTime.utc_now())}
    n = r.failures + 1
    ms = wait_ms(n, error[:retry_after])
    at = timestamp(DateTime.add(DateTime.utc_now(), ms, :millisecond))
    id = make_ref()
    Process.send_after(self(), {s.tag, :retry, id}, ms)
    tries = if (error[:attempts] || 1) > 1, do: " (#{error[:attempts]} attempts)", else: ""

    text =
      if n == 1,
        do:
          "My call to the model failed#{tries}: #{what}. I will call it again at #{at} (in " <>
            "#{duration(ms)}) without waiting for a message, or as soon as one arrives; while " <>
            "calls keep failing I keep calling, waiting longer each time.",
        else:
          "My call to the model failed again#{tries}: #{what}. #{n} calls in a row have failed " <>
            "since #{r.since}. I will call it again at #{at} (in #{duration(ms)}), or as " <>
            "soon as a message arrives."

    s = note(s, text)
    log(s, :turn_ended, %{reason: "error"})
    retry = %{failures: n, since: r.since, at: at, timer: id}
    s = Map.merge(s, %{status: :waiting_retry, calls: [], idle_called: false, retry: retry})

    # Messages that arrived during the failed call do not wait.
    if Enum.any?(s.pending, &String.starts_with?(&1, "<event")),
      do: maybe_start_turn(s),
      else: s
  end

  # What went wrong, for a note: the status (none, or a 200 whose stream failed) and what the
  # provider said.
  defp failure(error) do
    said = brief(Nano.Model.message(error.body))

    case error.status do
      nil -> "no response: #{said}"
      200 -> "the response failed: #{said}"
      status -> "HTTP #{status}: #{said}"
    end
  end

  defp duration(ms) when ms < 1_000, do: "#{ms} ms"
  defp duration(ms) when ms < 120_000, do: "#{round(ms / 1_000)} s"
  defp duration(ms), do: "#{Float.round(ms / 60_000, 1)} minutes"

  defp upcase_first(<<c::utf8, rest::binary>>), do: String.upcase(<<c::utf8>>) <> rest

  # Halts when one of the agent's own limits is reached; tool calls already returned still run.
  # The context limit is held before each call (request/2); this catches a response that went
  # past it anyway (the estimate fell short, or the provider takes no bound on the response).
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

  # Limits and use. State saved by an older version of this module may have no context fields
  # until the agent is restarted (upgrade/1).
  defp budget(s) do
    s
    |> Map.take([:max_turns, :max_tokens, :turns_used, :tokens_used])
    |> Map.merge(%{
      max_context: Map.get(s, :max_context, 0),
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
  defp run_calls(%{calls: [], pending_summary: text} = s) do
    s |> Map.delete(:pending_summary) |> apply_summary(text) |> run_calls()
  end

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
        case Compaction.parse(code) do
          {:ok, text} ->
            s
            |> tool_result(
              call,
              started,
              true,
              "Summary accepted; applied after this response's tools finish."
            )
            |> Map.put(:pending_summary, text)
            |> run_calls()

          _ ->
            start_eval(s, call, started, code)
        end

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

  defp start_eval(s, call, started, code) do
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
    timeout = Nano.Settings.get(:eval_timeout_ms)
    Process.send_after(self(), {s.tag, :eval_timeout, task.ref}, timeout)
    %{s | task: Map.merge(s.task, %{task: task, timeout: timeout})}
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

  defp eval_done(s, %{call: call, started: started, io: io, task: task} = t, result) do
    {output, spawned} = release(io, Process.group_leader(), task.pid)
    s = %{s | spawned: s.spawned ++ spawned}

    case result do
      {:ok, value, bindings, warnings} ->
        Nano.StateStore.put_bindings(s.name, bindings)
        tool_result(%{s | bindings: bindings}, call, started, true, value, output <> warnings)

      {:error, error} ->
        tool_result(s, call, started, false, error, output)

      :timeout ->
        timeout = "Timeout: the eval was killed after #{t[:timeout]} ms."
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
    max = stated(s, :result_max_bytes)
    {text, truncated, spill} = truncate(whole, max, {s.id, "call-#{s.call_seq}"})

    log(
      s,
      :tool_result,
      spilled(spill, %{
        call_id: call["id"],
        name: call["function"]["name"],
        duration_ms: System.monotonic_time(:millisecond) - started,
        ok: ok,
        result: elem(truncate(result, max), 0),
        io: elem(truncate(io, max), 0),
        truncated: truncated
      })
    )

    append(s, tool_message(call, text))
  end

  defp tool_message(call, text),
    do: %{"role" => "tool", "tool_call_id" => call["id"], "content" => text}

  ## Helpers

  defp append(s, message), do: %{s | transcript: s.transcript ++ [message]}

  defp timestamp(time), do: time |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # The most of an event or result that is printed and kept in a spill file.
  @ceiling 8_388_608

  # Cuts text at max bytes (the agent's result_max_bytes): {text, cut?, spill path}. Given a
  # spill name, the whole text (up to @ceiling bytes) is first written to
  # <spill_dir>/<agent id>/<name>.txt and the marker names it.
  defp truncate(text, max, spill \\ nil) do
    text = if String.valid?(text), do: text, else: inspect(text)
    size = byte_size(text)

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

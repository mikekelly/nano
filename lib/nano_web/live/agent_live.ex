defmodule NanoWeb.AgentLive do
  @moduledoc """
  One agent: a header read from `Nano.Ops.agent/1` every second (ETS, never a call to the
  agent), the lifecycle buttons, the send form, and a live timeline of its log entries.

  The timeline is a LiveView stream: the backlog from `Nano.Log.read/2`, then entries as
  they are broadcast. Live entries are round-tripped through JSON so both have the shape on
  disk (string keys). An eval's `tool_result` is folded into its `tool_call` item, so the
  call shows its code followed by result, IO and duration. If the agent is stopped and
  started again under the same name it gets a new id, and the timeline switches to it.

  Open goals are read from `Goals.open/2` on refresh, capped at 20 entries, independently
  of the agent process. Stopped owners retain their panel; failed reads are explicit.
  `goals_panel/1` renders a snapshot, and `refresh_goals/2` accepts a Memory `root:`
  for isolated callers/tests (the dashboard uses `Memory.default_root/0`).

  Two views of the same entries: the reading view (default) tells the story — events, the
  model's text, each tool call with its result, restarts, halts — and leaves out the plumbing;
  `?view=debug` shows every entry with its details, and links the raw files of a model
  request, response or error when the `raw_model_log` setting recorded them. Streamed items
  are not kept on the server, so switching views re-reads the log. Front-of-mind bob,
  drift, configuration and error events remain visible in reading view, labelled as
  agent-owned working-note metadata rather than new instructions.
  """
  use Phoenix.LiveView

  import NanoWeb.Components

  @refresh_ms 1_000
  @front_of_mind_types ~w(front_of_mind_bob front_of_mind_drift front_of_mind_configuration front_of_mind_error)
  def mount(%{"name" => name} = params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    socket =
      socket
      |> assign(page_title: name, name: name, id: nil, last_seq: 0, open_calls: %{}, notice: nil)
      |> assign(view: view(params))
      |> stream_configure(:entries, dom_id: &"e-#{&1["seq"]}")
      |> stream(:entries, [])
      |> mount_shared()
      |> sync()
      |> refresh_goals()

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    view = view(params)
    reload? = view != socket.assigns.view and socket.assigns.id != nil
    socket = assign(socket, view: view)
    {:noreply, if(reload?, do: load(socket, socket.assigns.id), else: socket)}
  end

  defp view(%{"view" => "debug"}), do: "debug"
  defp view(_), do: "reading"

  def handle_info(:refresh, socket), do: {:noreply, socket |> sync() |> refresh_goals()}
  def handle_info({:nano_user, _}, socket), do: {:noreply, refresh_unread(socket)}

  def handle_info({:nano_log, %{agent_id: id, seq: seq} = entry}, socket)
      when id == socket.assigns.id and seq > socket.assigns.last_seq do
    entry = entry |> Jason.encode!() |> Jason.decode!()
    {:noreply, socket |> assign(last_seq: seq) |> insert(entry) |> sync()}
  end

  def handle_info({:nano_log, _}, socket), do: {:noreply, socket}

  # A send from the bar's panels: on success the panel closes and the bar says what was sent.
  def handle_event("send", params, socket) do
    socket = handle_shared("send", params, socket)
    panel = if Map.has_key?(params, "text"), do: "say-menu", else: "raw-menu"

    case socket.assigns.sent do
      {:ok, _} = sent ->
        {:noreply, socket |> assign(notice: sent) |> push_event("close", %{id: panel})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("draft", params, socket),
    do: {:noreply, handle_shared("draft", params, socket)}

  def handle_event("stop", _, socket),
    do: lifecycle(socket, Nano.Ops.stop_agent(socket.assigns.name), "stopped")

  def handle_event("restart", _, socket),
    do: lifecycle(socket, Nano.Ops.restart_agent(socket.assigns.name), "restarting")

  def handle_event("resume", _, socket),
    do: lifecycle(socket, Nano.Ops.resume(socket.assigns.name), "resumed")

  def handle_event("unhalt", _, socket),
    do: lifecycle(socket, Nano.Ops.unhalt(socket.assigns.name), "un-halted")

  defp lifecycle(socket, result, done) do
    notice =
      case result do
        {:error, :not_found} -> {:error, "#{socket.assigns.name} is not running"}
        {:error, reason} -> {:error, inspect(reason)}
        _ -> {:ok, done}
      end

    {:noreply, socket |> assign(notice: notice) |> sync()}
  end

  # Re-reads the header; on first sight of an agent id (or a new one), loads its timeline.
  defp sync(socket) do
    name = socket.assigns.name
    agent = Nano.Ops.agent(name)
    spawned = for %{kind: {:spawned_by, ^name}} = row <- Nano.Ops.processes(), do: row
    socket = assign(socket, agent: agent, spawned: spawned)

    if agent && agent.id != socket.assigns.id && connected?(socket),
      do: load(socket, agent.id),
      else: socket
  end

  defp load(socket, id) do
    # Subscribe first, then read: anything logged in between arrives live with seq > last_seq.
    Nano.Log.subscribe(id)
    entries = Nano.Log.read(id)
    results = for %{"type" => "tool_result"} = r <- entries, into: %{}, do: {r["call_id"], r}
    calls = for %{"type" => "tool_call"} = c <- entries, into: MapSet.new(), do: c["call_id"]

    items =
      for e <- entries, not (e["type"] == "tool_result" and e["call_id"] in calls) do
        if e["type"] == "tool_call", do: Map.put(e, "result", results[e["call_id"]]), else: e
      end

    open =
      for %{"type" => "tool_call", "result" => nil} = c <- items, into: %{}, do: {c["call_id"], c}

    socket
    |> assign(
      id: id,
      last_seq: Enum.max(Enum.map(entries, & &1["seq"]), fn -> 0 end),
      open_calls: open
    )
    |> stream(:entries, Enum.filter(items, &shown?(socket, &1)), reset: true)
  end

  defp insert(socket, %{"type" => "tool_call"} = call) do
    socket
    |> update(:open_calls, &Map.put(&1, call["call_id"], call))
    |> put(Map.put(call, "result", nil))
  end

  defp insert(socket, %{"type" => "tool_result"} = result) do
    case Map.pop(socket.assigns.open_calls, result["call_id"]) do
      {nil, _} ->
        put(socket, result)

      {call, open} ->
        socket
        |> assign(open_calls: open)
        |> put(Map.put(call, "result", result))
    end
  end

  defp insert(socket, entry), do: put(socket, entry)

  defp put(socket, item),
    do: if(shown?(socket, item), do: stream_insert(socket, :entries, item), else: socket)

  # The reading view leaves out the plumbing: requests and their budget line, turn ends,
  # retried model errors, responses that only call tools, and anything it does not know.
  defp shown?(%{assigns: %{view: "debug"}}, _), do: true

  defp shown?(_, %{"type" => type} = e) do
    case type do
      t when t in ~w(event_received harness_note agent_started tool_call tool_result) -> true
      t when t in @front_of_mind_types -> true
      "model_response" -> present?(e["text"]) or present?(e["reasoning"])
      "model_error" -> e["retry"] != true
      _ -> false
    end
  end

  defp shown?(_, _), do: false

  defp present?(value), do: value not in [nil, ""]

  def render(assigns) do
    ~H"""
    <header class="top">
      <h1><.link navigate="/">nano</.link> / {@name}</h1>
      <span :if={@agent} class="dim">{@agent.id} · {inspect(@agent.pid)}</span>
      <.inbox_link unread={@unread} />
    </header>
    <div class="layout">
      <main>
        <section :if={@agent} class="bar">
          <dl>
            <div>
              <dt>model</dt><dd>{@agent.model}</dd>
            </div>
            <div>
              <dt>reasoning</dt><dd>{txt(Map.get(@agent, :reasoning) || "off")}</dd>
            </div>
            <div>
              <dt>status</dt><dd><.status agent={@agent} /></dd>
            </div>
            <div :for={{label, used, max} <- limits()}>
              <dt>{label}</dt>
              <dd>{limit(@agent.budget[used], @agent.budget[max])}</dd>
            </div>
            <div>
              <dt>cost</dt><dd>{cost(@agent.cost)}</dd>
            </div>
            <div>
              <dt>cache hits</dt><dd>{percent(@agent.cache_hit_rate)}</dd>
            </div>
            <div>
              <dt>restarts</dt><dd>{@agent.restart_count}</dd>
            </div>
          </dl>
          <div class="controls">
            <details id="procs-menu" class="dropdown" phx-mounted={keep_open()}>
              <summary class="button" title="processes this agent's evals started">
                <.icon name="cpu" /> {length(@spawned)}
              </summary>
              <div class="panel processes-panel">
                <h3>processes started by {@name}'s evals</h3>
                <p :if={@spawned == []} class="dim">None running.</p>
                <ul>
                  <li :for={row <- @spawned}>
                    <span class="pid">{inspect(row.pid)}</span>
                    <span class="mono">{mfa(row.current_function)}</span>
                    <span class="dim">{bytes(row.memory)} · queue {row.message_queue_len}</span>
                  </li>
                </ul>
              </div>
            </details>
            <details id="say-menu" class="dropdown" phx-mounted={keep_open()}>
              <summary class="button"><.icon name="send" /> Send message</summary>
              <div class="panel">
                <.send_form id="send" to={@name} draft={@draft} sent={@sent} boxes={["text"]} />
              </div>
            </details>
            <details id="raw-menu" class="dropdown" phx-mounted={keep_open()}>
              <summary class="button"><.icon name="code" /> Advanced message</summary>
              <div class="panel">
                <.send_form id="send-raw" to={@name} draft={@draft} sent={@sent} boxes={["term"]} />
              </div>
            </details>
            <button phx-click="stop"><.icon name="stop" /> Stop</button>
            <button phx-click="restart" disabled={@agent.pid == nil}><.icon name="restart" /> Restart</button>
            <button :if={@agent.suspended} phx-click="resume" class="warn"><.icon name="play" />
            Resume</button>
            <button :if={@agent.halted} phx-click="unhalt" class="warn"><.icon name="unlock" />
            Un-halt</button>
            <span :if={@notice} class={["sent", elem(@notice, 0)]}>{elem(@notice, 1)}</span>
          </div>
          <p :if={@agent.suspended} class="flag suspended">
            Suspended (in <code>:sys</code>'s suspend loop): it receives messages but handles none until resumed.
          </p>
          <p :if={@agent.halted} class="flag halted">
            Halted ({halt_reason(@agent.halted)}): it still receives and queues messages but makes no model calls until un-halted.
          </p>
        </section>
        <section :if={!@agent} class="bar">
          <p class="flag down">
            No agent named "{@name}" is running{if @id, do: " (it was stopped)"}. Start one from <.link navigate="/">the process view</.link>.
          </p>
          <span :if={@notice} class={["sent", elem(@notice, 0)]}>{elem(@notice, 1)}</span>
        </section>

        <details :if={@agent} id="system-prompt" class="prompt" phx-mounted={keep_open()}>
          <summary>
            system prompt<span :if={Map.get(@agent, :prompt_source)}> · from {txt(
              @agent.prompt_source
            )}</span>
          </summary>
          <pre>{@agent.system_prompt}</pre>
        </details>

        <.goals_panel result={@goals} />

        <nav class="views">
          <.link
            :for={{v, icon} <- [{"reading", "book"}, {"debug", "list"}]}
            patch={"/agents/#{@name}" <> if(v == "debug", do: "?view=debug", else: "")}
            class={@view == v && "current"}
          >
            <.icon name={icon} /> {v}
          </.link>
        </nav>
        <ol
          id="timeline"
          class={["timeline", @view]}
          phx-update="stream"
          phx-hook="Follow"
          data-view={@view}
        >
          <%= for {dom_id, e} <- @streams.entries do %>
            <.entry :if={@view == "debug"} id={dom_id} e={e} />
            <.read :if={@view != "debug"} id={dom_id} e={e} />
          <% end %>
        </ol>
        <div id="follow" phx-update="ignore">
          <button id="jump" type="button" hidden>jump to latest ↓</button>
        </div>
      </main>
    </div>
    """
  end

  @doc "Refresh the bounded open-goal snapshot without contacting the owner; accepts Memory root:."
  def refresh_goals(socket, opts \\ []) do
    assign(socket, :goals, Goals.open(socket.assigns.name, Keyword.put(opts, :limit, 20)))
  end

  attr :result, :any, required: true, doc: "The tagged result of Goals.open/2."

  @doc "Render a bounded Goals.open/2 snapshot, including unavailable and empty states."
  def goals_panel(assigns) do
    ~H"""
    <section id="open-goals" class="prompt" aria-labelledby="open-goals-heading">
      <h2 id="open-goals-heading">Open goals</h2>
      <%= case @result do %>
        <% {:ok, snapshot} -> %>
          <p class="dim">
            {snapshot.total} open · showing {length(snapshot.goals)} · {snapshot.omitted} omitted
          </p>
          <p :if={snapshot.goals == []}>No open goals.</p>
          <ol>
            <li :for={goal <- snapshot.goals}>
              <strong>{goal["title"]}</strong>
              <dl>
                <div>
                  <dt>Status</dt><dd>{goal["status"]}</dd>
                </div>
                <div>
                  <dt>Goal ID</dt><dd><code>{goal["id"]}</code></dd>
                </div>
                <div>
                  <dt>Parent ID</dt><dd><code>{goal["parent_id"] || "none (root)"}</code></dd>
                </div>
                <div>
                  <dt>Why</dt><dd style="white-space: pre-wrap; overflow-wrap: anywhere">
                    {goal["why"]}
                  </dd>
                </div>
              </dl>
            </li>
          </ol>
          <p :if={snapshot.omitted > 0} class="dim">
            Panel truncated: {snapshot.omitted} additional open goals not shown. Use Goals.list/2 to review all goals.
          </p>
        <% {:error, _reason} -> %>
          <p class="error" role="status">
            Goals unavailable: the goal store could not be read or is corrupt.
          </p>
      <% end %>
    </section>
    """
  end

  # Read with budget[key]: state saved before a limit existed lacks its keys.
  defp limits do
    [
      {"turns", :turns_used, :max_turns},
      {"tokens", :tokens_used, :max_tokens},
      {"context", :context_used, :max_context}
    ]
  end

  ## Timeline entries (string-keyed, as on disk)

  attr :id, :string, required: true
  attr :e, :map, required: true

  defp entry(%{e: %{"type" => "event_received"}} = assigns) do
    ~H"""
    <li id={@id} class="entry event">
      <.meta e={@e} label={"event #{txt(@e["event_seq"])}"}>
        queue {txt(@e["queue_length"])}<span :if={@e["truncated"]}> · truncated</span>
      </.meta>
      <pre>{printed(@e["message"])}</pre>
    </li>
    """
  end

  defp entry(%{e: %{"type" => "harness_note"}} = assigns) do
    ~H"""
    <li id={@id} class="entry note">
      <.meta e={@e} label="harness note" />
      <pre>{txt(@e["text"])}</pre>
    </li>
    """
  end

  defp entry(%{e: %{"type" => "agent_started"}} = assigns) do
    ~H"""
    <li id={@id} class="entry started">
      <.meta e={@e} label={if @e["restarted"], do: "restarted", else: "started"}>
        {txt(@e["pid"])} · {txt(@e["model"])}
        <span :if={@e["restarted"]}>
          · exit reason {txt(@e["exit_reason"])} · restart {txt(@e["restart_count"])}
        </span>
        <span :if={@e["halted"]} class="badge halted">halted: {txt(@e["halted"])}</span>
      </.meta>
    </li>
    """
  end

  defp entry(%{e: %{"type" => "model_request"}} = assigns) do
    ~H"""
    <li id={@id} class="entry request">
      <.meta e={@e} label={"model request #{txt(@e["request_id"])}"}>
        {txt(@e["model"])} · {txt(@e["message_count"])} messages · ~{int(@e["approx_input_tokens"])} tokens in
        <.raw_links files={@e["raw"]} />
      </.meta>
    </li>
    """
  end

  defp entry(%{e: %{"type" => "model_response"}} = assigns) do
    assigns = assign(assigns, calls: tool_calls(assigns.e["tool_calls"]))

    ~H"""
    <li id={@id} class="entry response">
      <.meta e={@e} label={"model turn #{txt(@e["request_id"])}"}>
        {int(@e["prompt_tokens"])} in ({int(@e["cached_tokens"])} cached) · {int(
          @e["completion_tokens"]
        )} out · {cost(@e["cost"])} · {txt(@e["latency_ms"])} ms · {txt(@e["provider"])} · {txt(
          @e["finish_reason"]
        )}<.raw_links files={@e["raw"]} />
      </.meta>
      <div :if={@e["reasoning"] not in [nil, ""]} class="reasoning">{txt(@e["reasoning"])}</div>
      <div :if={@e["text"] not in [nil, ""]} class="assistant">{txt(@e["text"])}</div>
      <details :if={@calls != []} class="calls">
        <summary>
          {length(@calls)} tool call{if length(@calls) > 1, do: "s"}: {Enum.map_join(
            @calls,
            ", ",
            &elem(&1, 0)
          )}
        </summary>
        <pre :for={{name, args} <- @calls}>{name}({args})</pre>
      </details>
    </li>
    """
  end

  defp entry(
         %{e: %{"type" => "tool_call", "name" => "eval", "arguments" => %{"code" => code}}} =
           assigns
       )
       when is_binary(code) do
    assigns = assign(assigns, code: code, result: assigns.e["result"])

    ~H"""
    <li id={@id} class={["entry eval", @result && !@result["ok"] && "failed"]}>
      <.meta e={@e} label={"eval call #{txt(@e["call_seq"])}"}>
        <span :if={!@result}>running…</span>
        <span :if={@result}>{txt(@result["duration_ms"])} ms · {if @result["ok"],
          do: "ok",
          else: "error"}</span>
      </.meta>
      <.code code={@code} />
      <.eval_result :if={@result} result={@result} />
    </li>
    """
  end

  defp entry(%{e: %{"type" => "tool_call", "name" => "idle"}} = assigns) do
    ~H"""
    <li id={@id} class="entry idle">
      <.meta e={@e} label="idle">
        <span :if={is_map(@e["arguments"]) && @e["arguments"]["wakeup_after"]}>
          wakeup after {txt(@e["arguments"]["wakeup_after"])} ms
        </span>
        <span :if={@e["result"] && !@e["result"]["ok"]} class="error">
          {txt(@e["result"]["result"])}
        </span>
      </.meta>
    </li>
    """
  end

  defp entry(%{e: %{"type" => "tool_call"}} = assigns) do
    ~H"""
    <li id={@id} class="entry eval failed">
      <.meta e={@e} label={"tool call #{txt(@e["call_seq"])}: #{inspect(@e["name"])}"} />
      <pre>{show(@e["arguments"])}</pre>
      <pre :if={@e["result"]} class="error">{txt(@e["result"]["result"])}</pre>
    </li>
    """
  end

  defp entry(%{e: %{"type" => "tool_result"}} = assigns) do
    ~H"""
    <li id={@id} class={["entry eval", !@e["ok"] && "failed"]}>
      <.meta e={@e} label={"#{txt(@e["name"])} result"}>{txt(@e["duration_ms"])} ms</.meta>
      <pre class={if !@e["ok"], do: "error"}>{txt(@e["result"])}</pre>
      <pre :if={@e["io"] not in [nil, ""]}>{txt(@e["io"])}</pre>
    </li>
    """
  end

  defp entry(%{e: %{"type" => "model_error"}} = assigns) do
    ~H"""
    <li id={@id} class="entry error">
      <.meta e={@e} label={"model error, request #{txt(@e["request_id"])}"}>
        status {txt(@e["status"] || "none")} · attempt {txt(@e["attempt"] || "–")} · {if @e["retry"],
          do: "retrying",
          else: "not retried"}<.raw_links files={@e["raw"]} />
      </.meta>
      <pre>{body(@e["body"])}</pre>
    </li>
    """
  end

  defp entry(%{e: %{"type" => "turn_ended"}} = assigns) do
    ~H"""
    <li id={@id} class="entry turn-ended">
      <.meta e={@e} label="turn ended">{txt(@e["reason"])}</.meta>
    </li>
    """
  end

  defp entry(%{e: %{"type" => "budget_exhausted"}} = assigns) do
    ~H"""
    <li id={@id} class="entry error">
      <.meta e={@e} label="budget exhausted">
        scope {txt(@e["scope"])} · turns {limit(@e["turns_used"], @e["max_turns"])} · tokens {limit(
          @e["tokens_used"],
          @e["max_tokens"]
        )}<span :if={@e["context_used"]}> · context {limit(@e["context_used"], @e["max_context"])}</span>
      </.meta>
    </li>
    """
  end

  defp entry(assigns) do
    ~H"""
    <li id={@id} class="entry">
      <.meta e={@e} label={txt(@e["type"])} />
      <pre>{show(Map.drop(@e, ~w(seq at agent_id agent type)))}</pre>
    </li>
    """
  end

  attr :result, :map, required: true

  # A tool result: its value (marked if it failed), captured IO, and whether it was truncated.
  defp eval_result(assigns) do
    ~H"""
    <div class="result">
      <pre class={if !@result["ok"], do: "error"}>{txt(@result["result"])}</pre>
      <div :if={@result["io"] not in [nil, ""]} class="io">
        <span class="dim">captured IO</span>
        <pre>{txt(@result["io"])}</pre>
      </div>
      <span :if={@result["truncated"]} class="dim">truncated for the model</span>
    </div>
    """
  end

  ## Reading view items

  attr :id, :string, required: true
  attr :e, :map, required: true

  defp read(%{e: %{"type" => "event_received"}} = assigns) do
    ~H"""
    <li id={@id} class="r event">
      <div class="r-label">received <time>{time(@e["at"])}</time></div>
      <pre>{printed(@e["message"])}</pre>
    </li>
    """
  end

  defp read(%{e: %{"type" => "harness_note"}} = assigns) do
    ~H"""
    <li id={@id} class={["r note", halt_note?(@e["text"]) && "halt"]}>{txt(@e["text"])}</li>
    """
  end

  defp read(%{e: %{"type" => "agent_started"}} = assigns) do
    ~H"""
    <li id={@id} class="r state">
      {if @e["restarted"], do: "restarted", else: "started"} <time>{time(@e["at"])}</time>
      <span :if={@e["restarted"]}>· exit reason {txt(@e["exit_reason"])}</span>
      <span :if={@e["halted"]} class="badge halted">halted: {txt(@e["halted"])}</span>
    </li>
    """
  end

  defp read(%{e: %{"type" => "model_response"}} = assigns) do
    ~H"""
    <li id={@id} class="r says">
      <span class="bot"><.icon name="bot" size={22} /></span>
      <div class="bubble">
        <div :if={present?(@e["text"])} class="prose">{txt(@e["text"])}</div>
        <details :if={present?(@e["reasoning"])} class="reasoning">
          <summary>reasoning</summary>
          <div class="prose">{txt(@e["reasoning"])}</div>
        </details>
      </div>
    </li>
    """
  end

  defp read(
         %{e: %{"type" => "tool_call", "name" => "eval", "arguments" => %{"code" => code}}} =
           assigns
       )
       when is_binary(code) do
    assigns = assign(assigns, code: code, result: assigns.e["result"])

    ~H"""
    <li id={@id} class={["r eval", !@result && "running", @result && !@result["ok"] && "failed"]}>
      <div class="r-label">
        eval <span :if={!@result}>running…</span>
        <span :if={@result}>
          {if @result["ok"], do: "ok", else: "failed"} · {txt(@result["duration_ms"])} ms
        </span>
      </div>
      <.code code={@code} />
      <.eval_result :if={@result} result={@result} />
    </li>
    """
  end

  defp read(%{e: %{"type" => "tool_call", "name" => "idle"}} = assigns) do
    ~H"""
    <li id={@id} class="r idle">
      idle<span :if={is_map(@e["arguments"]) && @e["arguments"]["wakeup_after"]}>
        · wake after {txt(@e["arguments"]["wakeup_after"])} ms if nothing arrives
      </span>
      <span :if={@e["result"] && !@e["result"]["ok"]} class="error">
        · {txt(@e["result"]["result"])}
      </span>
    </li>
    """
  end

  defp read(%{e: %{"type" => type}} = assigns) when type in ~w(tool_call tool_result) do
    ~H"""
    <li id={@id} class="r eval failed">
      <div class="r-label">{String.replace(txt(@e["type"]), "_", " ")} {inspect(@e["name"])}</div>
      <pre :if={@e["type"] == "tool_call"}>{show(@e["arguments"])}</pre>
      <.eval_result :if={@e["type"] == "tool_result"} result={@e} />
      <.eval_result :if={is_map(@e["result"])} result={@e["result"]} />
    </li>
    """
  end

  defp read(%{e: %{"type" => "model_error"}} = assigns) do
    ~H"""
    <li id={@id} class="r state error">
      model error, not retried: status {txt(@e["status"] || "none")} · {body(@e["body"])}
    </li>
    """
  end

  defp read(%{e: %{"type" => type}} = assigns) when type in @front_of_mind_types do
    ~H"""
    <li id={@id} class="r front-of-mind">
      <div class="r-label">
        {String.replace(@e["type"], "_", " ")} <time>{time(@e["at"])}</time>
      </div>
      <p class="dim">Agent-owned working note and review metadata, not a new instruction.</p>
      <pre>{show(Map.drop(@e, ~w(seq at agent_id agent type)))}</pre>
    </li>
    """
  end

  defp read(assigns), do: ~H|<li id={@id} hidden></li>|

  # The harness's own notes about halting and un-halting say "halted you".
  defp halt_note?(text), do: is_binary(text) and String.contains?(text, "halted you")

  attr :e, :map, required: true
  attr :label, :string, required: true
  slot :inner_block

  defp meta(assigns) do
    ~H"""
    <div class="meta">
      <span class="seq">#{txt(@e["seq"])}</span>
      <time>{time(@e["at"])}</time>
      <strong>{@label}</strong>
      <span class="dim">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  attr :files, :any, required: true, doc: "an entry's raw field: paths under Nano.RawLog.dir/0"

  # Links to the raw_model_log files an entry names, each in a tab of its own.
  defp raw_links(assigns) do
    ~H"""
    <span :if={is_list(@files) and @files != []}>
      · raw:
      <a :for={f <- @files} :if={is_binary(f)} href={"/api/raw/" <> f} target="_blank">
        {Path.basename(f)}
      </a>
    </span>
    """
  end

  defp body(body), do: txt(body)

  # A response's tool calls as {name, arguments} text, whatever shape the provider sent.
  defp tool_calls(calls) when is_list(calls) do
    for call <- calls do
      case call do
        %{"function" => %{"name" => name} = function} -> {txt(name), txt(function["arguments"])}
        other -> {"?", show(other)}
      end
    end
  end

  defp tool_calls(nil), do: []
  defp tool_calls(other), do: [{"?", show(other)}]
end

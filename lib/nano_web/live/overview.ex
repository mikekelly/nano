defmodule NanoWeb.Overview do
  @moduledoc """
  The home page's default view: agent cards (status, limits, what each is doing now, how many
  processes it spawned; an agent started by another follows its starter's card and says so),
  users, and the processes worth a look.
  Presentation only: everything comes from `Nano.Ops`, `Nano.User` and the agents' latest
  log entries, which `NanoWeb.ProcessLive` keeps.
  """
  use Phoenix.Component

  import NanoWeb.Components

  attr :agents, :list, required: true
  attr :rows, :list, required: true, doc: "Nano.Ops.processes/0"
  attr :recent, :map, required: true, doc: "agent id => its last few log entries, oldest first"
  attr :users, :list, required: true, doc: "[%{name, pid, messages, unread}]"
  attr :standard, :integer, required: true, doc: "how many processes are in the standard set"

  def overview(assigns) do
    spawned = for %{kind: {:spawned_by, name}} = row <- assigns.rows, do: {name, row}

    assigns =
      assign(assigns,
        cards: flatten(tree(assigns.agents), nil),
        spawned: Enum.group_by(spawned, &elem(&1, 0), &elem(&1, 1)),
        others: Enum.filter(assigns.rows, &(&1.kind == :other))
      )

    ~H"""
    <section class="overview">
      <h2>agents <span class="dim">{length(@agents)}</span></h2>
      <p :if={@agents == []} class="empty dim">
        No agents yet. Start one with the form above; it will appear here.
      </p>
      <div class="cards">
        <.card
          :for={{agent, parent} <- @cards}
          agent={agent}
          parent={parent}
          recent={@recent}
          spawned={@spawned}
        />
      </div>

      <h2>users <span class="dim">{length(@users)}</span></h2>
      <div class="cards users">
        <article :for={user <- @users} class="card user-card">
          <.link navigate={"/messages?user=#{URI.encode_www_form(user.name)}"} class="name">
            {user.name}
          </.link>
          <span class="dim">{user.pid && inspect(user.pid)}</span>
          <span>
            {user.messages} message{if user.messages != 1, do: "s"}<span :if={user.unread > 0}> · {user.unread} unread</span>
          </span>
        </article>
      </div>

      <h2>other processes <span class="dim">{length(@others)}</span></h2>
      <p class="dim">
        Appeared since boot and belong to no agent: usually the interesting ones. Newest first.
      </p>
      <ul class="others">
        <li :for={row <- @others |> Enum.reverse() |> Enum.take(30)}>
          <span class="pid">{inspect(row.pid)}</span>
          <span :if={row.name}>{if is_binary(row.name), do: row.name, else: inspect(row.name)}</span>
          <span class="dim mono">{mfa(row.current_function)}</span>
        </li>
      </ul>
      <p :if={length(@others) > 30} class="dim">
        … and {length(@others) - 30} more in the debug view.
      </p>
      <p class="dim">{@standard} processes of the standard set are not shown (see the debug view).</p>
    </section>
    """
  end

  # Each agent followed by the agents it started (depth first), with the name of its starter.
  defp flatten(nodes, parent) do
    Enum.flat_map(nodes, fn {agent, children} ->
      [{agent, parent} | flatten(children, agent.name)]
    end)
  end

  attr :agent, :map, required: true
  attr :parent, :string, default: nil, doc: "the agent that started this one, if it is shown"
  attr :recent, :map, required: true
  attr :spawned, :map, required: true

  # One agent. Cards follow the agents that started them, and say so.
  defp card(assigns) do
    agent = assigns.agent
    assigns = assign(assigns, mine: assigns.spawned[agent.name] || [])

    assigns = assign(assigns, now: now(agent, assigns.recent[agent.id] || []))

    # Every line has a fixed slot, so cards in a row stay the same height whatever they say.
    ~H"""
    <article class={["card agent-card", state(@agent), @parent && "child"]} id={"card-#{@agent.name}"}>
      <header>
        <.link navigate={"/agents/#{@agent.name}"} class="name" title={@agent.name}>{@agent.name}</.link>
        <.status agent={@agent} />
      </header>
      <div class="line dim">
        {txt(@agent.model)} · reasoning {txt(Map.get(@agent, :reasoning) || "off")}
      </div>
      <%!-- One slot: why it is halted, or else who started it. --%>
      <p :if={@agent.halted} class="line halt" title={halt_reason(@agent.halted)}>
        {halt_reason(@agent.halted)}
      </p>
      <p :if={!@agent.halted} class="line started-by">
        <span :if={@parent}>↳ started by <.link navigate={"/agents/#{@parent}"}>{@parent}</.link></span>
      </p>
      <div class="meters">
        <.meter label="turns" used={@agent.budget[:turns_used]} max={@agent.budget[:max_turns]} />
        <.meter label="tokens" used={@agent.budget[:tokens_used]} max={@agent.budget[:max_tokens]} />
        <.meter label="context" used={@agent.budget[:context_used]} max={@agent.budget[:max_context]} />
      </div>
      <div class="line dim">
        {cost(@agent.cost)} · {txt(@agent.restart_count)} restarts<span :if={@mine != []}> · <span class="spawned"><.icon
          name="cpu"
          size={13}
        /> {length(@mine)} spawned</span></span>
      </div>
      <div class="now line" title={@now}>{@now}</div>
    </article>
    """
  end

  defp state(agent) do
    cond do
      agent.pid == nil -> "down"
      agent.halted -> "halted"
      agent.suspended -> "suspended"
      true -> txt(agent.status)
    end
  end

  attr :label, :string, required: true
  attr :used, :any, required: true
  attr :max, :any, required: true

  # used / max as a bar; a max of 0 means no limit, so there is nothing to fill.
  defp meter(assigns) do
    %{used: used, max: max} = assigns

    fill =
      if is_number(used) and is_number(max) and max > 0,
        do: min(100, round(used * 100 / max)),
        else: 0

    assigns = assign(assigns, fill: fill)

    ~H"""
    <div class={["meter", @fill >= 90 && "high"]}>
      <span class="label">{@label}</span>
      <span class="bar"><span style={"width: #{@fill}%"}></span></span>
      <span class="value">{limit(@used, @max)}</span>
    </div>
    """
  end

  @doc """
  Agents as `[{agent, children}]`: an agent started by another (its `started_by`) sits under
  it. Agents whose parent is gone, or that start each other in a cycle, become roots.
  """
  def tree(agents) do
    names = MapSet.new(agents, & &1.name)
    kids = Enum.group_by(agents, &Map.get(&1, :started_by))
    roots = Enum.reject(agents, &MapSet.member?(names, Map.get(&1, :started_by)))
    {nodes, seen} = grow(roots, kids, MapSet.new())
    {cycles, _} = grow(Enum.reject(agents, &MapSet.member?(seen, &1.name)), kids, seen)
    nodes ++ cycles
  end

  defp grow(agents, kids, seen) do
    Enum.flat_map_reduce(agents, seen, fn agent, seen ->
      if MapSet.member?(seen, agent.name) do
        {[], seen}
      else
        {children, seen} = grow(Map.get(kids, agent.name, []), kids, MapSet.put(seen, agent.name))
        {[{agent, children}], seen}
      end
    end)
  end

  @doc "What an agent is doing now, in a few words, from its state and last log entries."
  def now(agent, recent) do
    cond do
      agent.pid == nil -> "down: its process is not running"
      agent.halted -> "halted: #{txt(agent.halted)}"
      agent.suspended -> "suspended"
      agent.status == :waiting_retry -> "a model call failed; calling again at #{agent.retry_at}"
      true -> recent |> Enum.reverse() |> doing()
    end
  end

  defp doing([%{"type" => "turn_ended", "reason" => "idle"} = ended | earlier]) do
    case Enum.find(earlier, &match?(%{"type" => "tool_call", "name" => "idle"}, &1)) do
      %{"arguments" => %{"wakeup_after" => ms}} when is_integer(ms) ->
        left = div(ms, 1000) - since(ended["at"])
        if left > 0, do: "idle, wakes in #{duration(left)}", else: "idle, waking"

      _ ->
        "idle, waiting for a message"
    end
  end

  defp doing([%{"type" => type, "name" => "idle"} | _]) when type in ~w(tool_call tool_result),
    do: "going idle"

  defp doing([%{"type" => type} = e | _]) do
    case type do
      "turn_ended" ->
        "turn ended: #{txt(e["reason"])}"

      "tool_call" ->
        "#{txt(e["name"])} running · #{duration(since(e["at"]))}"

      "tool_result" ->
        "#{txt(e["name"])} #{if e["ok"], do: "ok", else: "failed"} · #{txt(e["duration_ms"])} ms"

      "model_request" ->
        "thinking · #{duration(since(e["at"]))}"

      "model_response" ->
        said(e["text"])

      "event_received" ->
        "received #{clip(txt(e["message"]))}"

      "harness_note" ->
        clip(txt(e["text"]))

      "model_error" ->
        "model error, status #{txt(e["status"] || "none")}"

      "agent_started" ->
        if e["restarted"], do: "restarted", else: "started"

      "budget_exhausted" ->
        "budget exhausted (#{txt(e["scope"])})"

      other ->
        txt(other)
    end
  end

  defp doing(_), do: "no activity yet"

  defp said(text) when is_binary(text) and text != "", do: "said: " <> clip(text)
  defp said(_), do: "calling tools"

  defp clip(text) do
    line = text |> String.split("\n", parts: 2) |> hd()
    if String.length(line) > 90, do: String.slice(line, 0, 90) <> "…", else: line
  end

  defp since(at) do
    case is_binary(at) && DateTime.from_iso8601(at) do
      {:ok, at, _} -> max(DateTime.diff(DateTime.utc_now(), at), 0)
      _ -> 0
    end
  end

  defp duration(s) when s < 60, do: "#{s} s"
  defp duration(s) when s < 3600, do: "#{div(s, 60)} min"
  defp duration(s), do: "#{div(s, 3600)} h #{div(rem(s, 3600), 60)} min"
end

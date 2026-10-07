defmodule NanoWeb.ProcessLive do
  @moduledoc """
  Home page. Every second it re-reads `Nano.Ops.processes/0` (standard set already excluded,
  agents first) and `Nano.Ops.agents/0`. The default view is `NanoWeb.Overview`: agent cards,
  users, the processes worth a look. `?view=debug` is the process table, with reductions per
  second as the delta since the previous read and a send form on every row. The Start agent
  form calls `Nano.Ops.start_agent/2`.

  For the cards' "now" line the page keeps each agent's last three log entries: read once when
  the agent is first seen, then followed on its PubSub topic. Users' message counts are read
  once and then counted from their topics.
  """
  use Phoenix.LiveView

  import NanoWeb.Components

  @refresh_ms 1_000

  def mount(params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    socket =
      socket
      |> assign(page_title: "nano", prev: %{}, prev_at: nil, send_to: nil, view: view(params))
      |> assign(recent: %{}, counts: %{})
      |> assign(start: %{}, start_error: nil)
      |> mount_shared()
      |> refresh()

    {:ok, socket}
  end

  def handle_params(params, _uri, socket), do: {:noreply, assign(socket, view: view(params))}

  defp view(%{"view" => "debug"}), do: "debug"
  defp view(_), do: "overview"

  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  def handle_info({:nano_log, %{agent_id: id, seq: seq} = entry}, socket) do
    recent =
      case socket.assigns.recent do
        %{^id => [_ | _] = last} = recent ->
          if seq > List.last(last)["seq"],
            do: Map.put(recent, id, Enum.take(last ++ [json(entry)], -3)),
            else: recent

        %{^id => []} = recent ->
          Map.put(recent, id, [json(entry)])

        recent ->
          recent
      end

    {:noreply, assign(socket, recent: recent)}
  end

  def handle_info({:nano_user, %{dir: :received, to: to}}, socket) do
    socket = if to == socket.assigns.inbox_pid, do: refresh_inbox(socket), else: socket
    name = Enum.find_value(socket.assigns.users, fn {name, pid, _} -> pid == to && name end)

    {:noreply,
     update(
       socket,
       :counts,
       &if(&1[name], do: Map.update!(&1, name, fn n -> n + 1 end), else: &1)
     )}
  end

  def handle_info({:nano_user, _}, socket), do: {:noreply, socket}

  def handle_event(event, params, socket) when event in ~w(draft send clear_inbox),
    do: {:noreply, handle_shared(event, params, socket)}

  def handle_event("open_send", %{"to" => to}, socket) do
    to = if socket.assigns.send_to == to, do: nil, else: to
    {:noreply, assign(socket, send_to: to, sent: nil)}
  end

  # Inputs are held in assigns so the once-a-second re-render does not reset them.
  def handle_event("start_draft", params, socket), do: {:noreply, assign(socket, start: params)}

  def handle_event("start", params, socket) do
    name = String.trim(params["name"] || "")

    opts =
      [
        model: blank_to_nil(params["model"]),
        start_idle: params["start_idle"] != "false",
        max_turns: number(params["max_turns"]),
        max_tokens: number(params["max_tokens"]),
        max_context: number(params["max_context"]),
        system_prompt: blank_to_nil(params["system_prompt"]),
        system_prompt_file: blank_to_nil(params["system_prompt_file"]),
        reasoning: params["reasoning"]
      ]
      |> Enum.reject(fn {_, v} -> v == nil end)

    case Nano.Ops.start_agent(name, opts) do
      {:ok, _pid} ->
        {:noreply, push_navigate(socket, to: "/agents/#{name}")}

      {:error, reason} ->
        {:noreply, assign(socket, start: params, start_error: start_error(reason))}
    end
  end

  def handle_event("resume", %{"name" => name}, socket) do
    Nano.Ops.resume(name)
    {:noreply, refresh(socket)}
  end

  def handle_event("unhalt", %{"name" => name}, socket) do
    Nano.Ops.unhalt(name)
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    now = System.monotonic_time(:millisecond)
    %{prev: prev, prev_at: prev_at} = socket.assigns

    rows =
      for row <- Nano.Ops.processes() do
        rate =
          case prev[row.pid] do
            nil -> nil
            before -> div((row.reductions - before) * 1000, max(now - prev_at, 1))
          end

        Map.put(row, :rate, rate)
      end

    socket
    |> assign(
      rows: rows,
      prev: Map.new(rows, &{&1.pid, &1.reductions}),
      prev_at: now,
      refreshed_at: DateTime.utc_now(),
      agents: Nano.Ops.agents(),
      standard: length(Process.list()) - length(rows)
    )
    |> follow()
  end

  # First sight of an agent (by id) or user: subscribe and read what is there once; from then on
  # their topics keep it current. Agents that are gone are dropped.
  defp follow(socket) do
    %{agents: agents, recent: recent, counts: counts} = socket.assigns
    live? = connected?(socket)

    recent =
      Map.new(agents, fn %{id: id} ->
        case recent do
          %{^id => last} -> {id, last}
          _ when live? -> {id, tail(id)}
          _ -> {id, []}
        end
      end)

    users = for name <- Enum.sort(Nano.User.list()), do: {name, Nano.User.pid(name)}

    counts =
      Map.new(users, fn {name, _} ->
        case counts do
          %{^name => n} -> {name, n}
          _ when live? -> {name, first_count(name)}
          _ -> {name, nil}
        end
      end)

    users =
      for {name, pid} <- users do
        count =
          if name == "dashboard" and socket.assigns.inbox,
            do: length(socket.assigns.inbox),
            else: counts[name]

        {name, pid, count}
      end

    assign(socket, recent: recent, counts: counts, users: users)
  end

  defp tail(id) do
    Nano.Log.subscribe(id)
    Enum.take(Nano.Log.read(id), -3)
  end

  defp first_count(name) do
    Phoenix.PubSub.subscribe(Nano.PubSub, "user:" <> name)

    case Nano.User.inbox(name) do
      messages when is_list(messages) -> length(messages)
      {:error, _} -> nil
    end
  end

  # Broadcast entries have atom keys; the log on disk, string keys. Cards read the latter.
  defp json(entry), do: entry |> Jason.encode!() |> Jason.decode!()

  defp limit_fields do
    [
      {"max_turns", "max turns", :agent_max_turns},
      {"max_tokens", "max tokens", :agent_max_tokens},
      {"max_context", "max context", :agent_max_context}
    ]
  end

  defp placeholder(env) do
    case Application.get_env(:nano, env) do
      nil -> "0 = no limit"
      default -> "default #{default}; 0 = no limit"
    end
  end

  # What the form shows selected: what was chosen, or until then the node's default (REASONING).
  defp reasoning(%{"reasoning" => level}), do: level
  defp reasoning(_), do: Application.get_env(:nano, :reasoning, "off")

  defp blank_to_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      value -> value
    end
  end

  # A whole number as an integer; anything else typed is passed on as typed, for
  # `NanoAgent.start/1` to reject as it would from the API. Blank means the default.
  defp number(value) do
    value = blank_to_nil(value)

    case value && Integer.parse(value) do
      {n, ""} -> n
      _ -> value
    end
  end

  defp start_error(:invalid_name), do: "name must be letters, digits, _ . or -"
  defp start_error({:already_started, _}), do: "an agent with that name is already running"

  defp start_error(:missing_openrouter_api_key),
    do: "OPENROUTER_API_KEY is not set on this node"

  defp start_error(:missing_model), do: "no model given and DEFAULT_MODEL is not set"

  defp start_error(:invalid_option),
    do: "max turns, max tokens and max context must be whole numbers, 0 or more (0 = no limit)"

  defp start_error(reason), do: NanoWeb.Components.refusal(reason)

  defp kind(%{kind: {:spawned_by, agent}} = assigns) do
    assigns = assign(assigns, agent: agent)
    ~H|spawned by <.link navigate={"/agents/#{@agent}"}>{@agent}</.link>|
  end

  defp kind(assigns), do: ~H|{@row.kind}|

  def render(assigns) do
    ~H"""
    <header class="top">
      <h1>nano</h1>
      <span class="dim">
        {node()} · {length(@rows)} {if length(@rows) == 1, do: "process", else: "processes"} outside the standard set · refreshed {time(
          @refreshed_at
        )} UTC
      </span>
      <.inbox_menu inbox={@inbox} pid={@inbox_pid} />
    </header>
    <div class="layout">
      <main>
        <form id="start" class="start" phx-change="start_draft" phx-submit="start">
          <h2>Start agent</h2>
          <label>
            name <input type="text" name="name" value={@start["name"]} required autocomplete="off" />
          </label>
          <label>
            model
            <input
              type="text"
              name="model"
              value={@start["model"]}
              placeholder={Application.get_env(:nano, :default_model)}
              autocomplete="off"
            />
          </label>
          <label class="check">
            <input type="hidden" name="start_idle" value="false" />
            <input
              type="checkbox"
              name="start_idle"
              value="true"
              checked={@start["start_idle"] != "false"}
            /> Start idle
          </label>
          <button>Start</button>
          <details id="start-options" phx-mounted={keep_open()}>
            <summary>options</summary>
            <label :for={{field, label, env} <- limit_fields()}>
              {label}
              <input
                type="number"
                name={field}
                value={@start[field]}
                min="0"
                placeholder={placeholder(env)}
              />
            </label>
            <label>
              reasoning
              <select name="reasoning">
                <option
                  :for={level <- reasoning_levels()}
                  value={level}
                  selected={level == reasoning(@start)}
                >
                  {level}
                </option>
              </select>
            </label>
            <label class="wide">
              system prompt file
              <input
                type="text"
                name="system_prompt_file"
                value={@start["system_prompt_file"]}
                placeholder={"blank = #{Application.get_env(:nano, :system_prompt_file)}; relative to the app directory; the template below wins if both are filled"}
                autocomplete="off"
              />
            </label>
            <label class="wide">
              system prompt template (blank = the file above; same placeholders) <textarea
                name="system_prompt"
                rows="4"
              >{@start["system_prompt"]}</textarea>
            </label>
          </details>
          <p :if={@start_error} class="error">{@start_error}</p>
        </form>

        <nav class="views">
          <.link
            :for={v <- ~w(overview debug)}
            patch={if v == "debug", do: "/?view=debug", else: "/"}
            class={@view == v && "current"}
          >
            {v}
          </.link>
        </nav>

        <NanoWeb.Overview.overview
          :if={@view == "overview"}
          agents={@agents}
          rows={@rows}
          recent={@recent}
          users={@users}
          standard={@standard}
        />

        <table :if={@view == "debug"} class="processes">
          <thead>
            <tr>
              <th>PID</th>
              <th>Name</th>
              <th>Kind</th>
              <th>Current function</th>
              <th class="num">Msg queue</th>
              <th class="num">Memory</th>
              <th class="num">Reductions/s</th>
              <th></th>
            </tr>
          </thead>
          <tbody
            :for={row <- @rows}
            id={"p-" <> pid_id(row.pid)}
            class={[row_class(row.kind), @send_to == inspect(row.pid) && "open"]}
          >
            <tr>
              <td class="pid">{inspect(row.pid)}</td>
              <td>
                <.link :if={row.kind == :agent} navigate={"/agents/#{row.name}"} class="agent">
                  {row.name}
                </.link>
                <.status :if={row.agent} agent={row.agent} />
                <span :if={row.kind != :agent}>{name(row.name)}</span>
              </td>
              <td><.kind row={row} kind={row.kind} /></td>
              <td class="mono">{mfa(row.current_function)}</td>
              <td class="num">{row.message_queue_len}</td>
              <td class="num">{bytes(row.memory)}</td>
              <td class="num">{int(row.rate)}</td>
              <td class="actions">
                <button
                  :if={row.agent && row.agent.suspended}
                  phx-click="resume"
                  phx-value-name={row.name}
                  class="small"
                >
                  Resume
                </button>
                <button
                  :if={row.agent && row.agent.halted}
                  phx-click="unhalt"
                  phx-value-name={row.name}
                  class="small"
                >
                  Un-halt
                </button>
                <button phx-click="open_send" phx-value-to={inspect(row.pid)} class="small">
                  send
                </button>
              </td>
            </tr>
            <tr :if={@send_to == inspect(row.pid)} class="send-row">
              <td colspan="8">
                <.send_form
                  id={"send" <> pid_id(row.pid)}
                  to={inspect(row.pid)}
                  draft={@draft}
                  sent={@sent}
                />
              </td>
            </tr>
          </tbody>
        </table>
        <p
          :if={@view == "debug" && @send_to && !Enum.any?(@rows, &(inspect(&1.pid) == @send_to))}
          class="dim"
        >
          {@send_to} has exited.
        </p>
        <p :if={@view == "debug"} class="legend dim">
          <span class="other-key">highlighted</span>
          = appeared since boot, belongs to no agent: usually the interesting ones.
        </p>
      </main>
    </div>
    """
  end

  defp row_class(:other), do: "other"
  defp row_class(:agent), do: "agent"
  defp row_class(:user), do: "user"
  defp row_class(_), do: "spawned"

  defp name(nil), do: ""
  defp name(name) when is_binary(name), do: name
  defp name(name), do: inspect(name)

  defp pid_id(pid), do: pid |> inspect() |> String.replace(~r/\D+/, "-")
end

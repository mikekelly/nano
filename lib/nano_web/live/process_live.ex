defmodule NanoWeb.ProcessLive do
  @moduledoc """
  Home page: the process view. Every second it re-reads `Nano.Ops.processes/0` (standard set
  already excluded, agents first) and shows reductions per second as the delta since the
  previous read. Processes of kind `:other` are highlighted. Any row opens the send form;
  the Start agent form calls `Nano.Ops.start_agent/2`.
  """
  use Phoenix.LiveView

  import NanoWeb.Components

  @refresh_ms 1_000

  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    socket =
      socket
      |> assign(page_title: "nano", prev: %{}, prev_at: nil, send_to: nil)
      |> assign(start: %{}, start_error: nil)
      |> mount_shared()
      |> refresh()

    {:ok, socket}
  end

  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}
  def handle_info({:nano_user, _}, socket), do: {:noreply, refresh_inbox(socket)}

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
        max_turns: positive(params["max_turns"]),
        max_tokens: positive(params["max_tokens"]),
        system_prompt: blank_to_nil(params["system_prompt"])
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

    assign(socket,
      rows: rows,
      prev: Map.new(rows, &{&1.pid, &1.reductions}),
      prev_at: now,
      refreshed_at: DateTime.utc_now()
    )
  end

  defp blank_to_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      value -> value
    end
  end

  defp positive(value) do
    case Integer.parse(String.trim(value || "")) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp start_error(:invalid_name), do: "name must be letters, digits, _ . or -"
  defp start_error({:already_started, _}), do: "an agent with that name is already running"

  defp start_error(:missing_openrouter_api_key),
    do: "OPENROUTER_API_KEY is not set on this node"

  defp start_error(:missing_model), do: "no model given and DEFAULT_MODEL is not set"
  defp start_error(reason), do: inspect(reason)

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
            <label>
              max turns <input type="number" name="max_turns" value={@start["max_turns"]} min="1" />
            </label>
            <label>
              max tokens
              <input type="number" name="max_tokens" value={@start["max_tokens"]} min="1" />
            </label>
            <label class="wide">
              system prompt template (blank = default; same placeholders) <textarea
                name="system_prompt"
                rows="4"
              >{@start["system_prompt"]}</textarea>
            </label>
          </details>
          <p :if={@start_error} class="error">{@start_error}</p>
        </form>

        <table class="processes">
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
        <p :if={@send_to && !Enum.any?(@rows, &(inspect(&1.pid) == @send_to))} class="dim">
          {@send_to} has exited.
        </p>
        <p class="legend dim">
          <span class="other-key">highlighted</span>
          = appeared since boot, belongs to no agent: usually the interesting ones.
        </p>
      </main>
      <aside>
        <.inbox inbox={@inbox} pid={@inbox_pid} />
      </aside>
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

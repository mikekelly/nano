defmodule NanoWeb.BotsLive do
  @moduledoc "Consumer chat; durable messages only, never operator transcripts."
  use Phoenix.LiveView
  alias Seedling.Bots

  def mount(_, _, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Nano.PubSub, "seedling:bots")
      :timer.send_interval(1500, :bots_updated)
    end

    {:ok,
     socket
     |> assign(page_title: "Bots", selected: nil, error: nil, answer_to: nil, seen_messages: nil)
     |> refresh()}
  end

  def handle_info(:bots_updated, socket), do: {:noreply, refresh(socket)}

  def handle_event("select", %{"id" => id}, socket),
    do: {:noreply, socket |> assign(selected: id, answer_to: nil, error: nil) |> refresh()}

  def handle_event("create_bot", attrs, socket), do: result(socket, Bots.create_bot(attrs))

  def handle_event("create_session", attrs, socket) do
    case Bots.create_session(List.wrap(Map.get(attrs, "bots", [])), Map.take(attrs, ["title"])) do
      {:ok, s} ->
        {:noreply, socket |> assign(selected: s["id"], answer_to: nil, error: nil) |> refresh()}

      {:error, reason} ->
        failure(socket, reason)
    end
  end

  def handle_event("answer_to", %{"id" => id}, socket) do
    if socket.assigns.session &&
         Enum.any?(
           socket.assigns.session["messages"],
           &(&1["request_id"] == id and &1["role"] == "bot")
         ) do
      {:noreply, assign(socket, answer_to: id, error: nil)}
    else
      failure(socket, :not_found)
    end
  end

  def handle_event("cancel_answer", _, socket), do: {:noreply, assign(socket, answer_to: nil)}

  def handle_event("say", %{"text" => text}, socket) do
    outcome =
      if socket.assigns.answer_to,
        do: Bots.answer(socket.assigns.answer_to, text),
        else: Bots.say(socket.assigns.selected, text)

    case outcome do
      {:ok, _} -> {:noreply, socket |> assign(answer_to: nil, error: nil) |> refresh()}
      {:error, reason} -> failure(socket, reason)
    end
  end

  def handle_event("quiet", _, socket) do
    if s = socket.assigns.session,
      do: result(socket, Bots.settings(s["id"], %{quiet: !s["settings"]["quiet"]})),
      else: failure(socket, :not_found)
  end

  def handle_event("notifications", %{"enabled" => enabled, "session_id" => id}, socket)
      when is_boolean(enabled) do
    if socket.assigns.session && socket.assigns.session["id"] == id,
      do: result(socket, Bots.settings(id, %{notifications: enabled})),
      else: failure(socket, :not_found)
  end

  defp result(socket, {:ok, _}), do: {:noreply, socket |> assign(error: nil) |> refresh()}
  defp result(socket, {:error, reason}), do: failure(socket, reason)

  defp failure(socket, reason),
    do: {:noreply, assign(socket, error: "Could not complete that action: #{reason}")}

  defp refresh(socket) do
    sessions = Enum.sort_by(Bots.sessions(), & &1["title"])
    seen = socket.assigns.seen_messages

    socket =
      if is_map(seen) do
        Enum.reduce(sessions, socket, fn session, socket ->
          if session["settings"]["notifications"] and not session["settings"]["quiet"] do
            Enum.reduce(session["messages"], socket, fn msg, socket ->
              if msg["role"] == "bot" and
                   not MapSet.member?(Map.get(seen, session["id"], MapSet.new()), msg["id"]) do
                push_event(socket, "bot-notification", %{
                  title: session["title"],
                  body: String.slice(msg["text"], 0, 200),
                  id: msg["id"],
                  session_id: session["id"]
                })
              else
                socket
              end
            end)
          else
            socket
          end
        end)
      else
        socket
      end

    seen = Map.new(sessions, fn s -> {s["id"], MapSet.new(s["messages"], & &1["id"])} end)

    assign(socket,
      bots: Enum.sort_by(Bots.bots(), & &1["name"]),
      sessions: sessions,
      seen_messages: seen,
      session: Bots.session(socket.assigns.selected)
    )
  end

  defp name(bots, id),
    do: Enum.find_value(bots, "Bot", fn b -> if b["id"] == id, do: b["name"] end)

  defp answered?(messages, id),
    do: Enum.any?(messages, &(&1["role"] == "human" and &1["request_id"] == id))

  defp thinking?(session, id) do
    case NanoAgent.info("bot-#{id}-#{session["id"]}") do
      %{status: status, halted: nil} when status in [:thinking, :running_tool] -> true
      _ -> false
    end
  end

  def render(assigns) do
    ~H"""
    <main id="bots" phx-hook="BotNotifications" style="max-width:1100px;margin:auto;padding:1rem">
      <header>
        <h1>Bots</h1><a href="/">Operator dashboard</a>
      </header>
      <p :if={@error} role="alert">{@error}</p>
      <div style="display:flex;flex-wrap:wrap;gap:2rem">
        <aside aria-label="Sessions" style="flex:1;min-width:240px">
          <h2>Conversations</h2>
          <p :if={@sessions == []}>Start your first conversation below.</p>
          <ul>
            <li :for={s <- @sessions}>
              <button
                phx-click="select"
                phx-value-id={s["id"]}
                aria-current={if @selected == s["id"], do: "true", else: "false"}
              >{s["title"]}</button>
              <small>{Enum.map_join(s["bot_ids"], ", ", &name(@bots, &1))}</small>
            </li>
          </ul>
          <h2>New conversation</h2>
          <form id="session-form" phx-submit="create_session">
            <label>Title <input name="title" value="New conversation" maxlength="200" required /></label>
            <fieldset>
              <legend>Choose one or more bots (up to eight)</legend>
              <label :for={bot <- @bots} style="display:block">
                <input type="checkbox" name="bots[]" value={bot["id"]} /> {bot["name"]}
                <small>{bot["description"]}</small>
              </label>
            </fieldset>
            <button disabled={@bots == []}>Start conversation</button>
          </form>
          <h2>Create a bot</h2>
          <form id="bot-form" phx-submit="create_bot">
            <label>Name <input name="name" required maxlength="100" /></label>
            <label>Description <textarea name="description" maxlength="1000" required></textarea></label>
            <button>Create bot</button>
          </form>
        </aside>
        <section aria-label="Chat" style="flex:2;min-width:280px">
          <%= if @session do %>
            <h2>{@session["title"]}</h2>
            <p>{Enum.map_join(@session["bot_ids"], ", ", &name(@bots, &1))}</p>
            <button phx-click="quiet" aria-pressed={to_string(@session["settings"]["quiet"])}>Quiet mode: {if @session[
                                                                                                                "settings"
                                                                                                              ][
                                                                                                                "quiet"
                                                                                                              ],
                                                                                                              do:
                                                                                                                "on",
                                                                                                              else:
                                                                                                                "off"}</button>
            <p>
              <button
                type="button"
                data-session-id={@session["id"]}
                data-bot-notifications={
                  if @session["settings"]["notifications"], do: "disable", else: "enable"
                }
              >
                Browser notifications: {if @session["settings"]["notifications"],
                  do: "on",
                  else: "off"}
              </button>
              <small id="bot-notification-status" role="status">Requires browser permission; only while this page is open. Quiet mode suppresses notifications.</small>
            </p>
            <p :for={id <- @session["bot_ids"]} :if={thinking?(@session, id)} role="status">
              {name(@bots, id)} is thinking…
            </p>
            <ol id="chat-messages" aria-live="polite" style="list-style:none;padding:0">
              <li
                :for={msg <- @session["messages"]}
                id={"message-" <> msg["id"]}
                style="margin:1rem 0;padding:1rem;border:1px solid #888;border-radius:12px"
              >
                <strong>{if msg["role"] == "human", do: "You", else: name(@bots, msg["bot_id"])}</strong>
                <NanoWeb.BotMessage.message text={msg["text"]} />
                <%= if msg["role"] == "bot" && msg["request_id"] do %>
                  <%= if answered?(@session["messages"], msg["request_id"]) do %>
                    <small>Answered</small>
                  <% else %>
                    <button phx-click="answer_to" phx-value-id={msg["request_id"]}>Answer this request</button>
                  <% end %>
                <% end %>
              </li>
            </ol>
            <form id="chat-form" phx-submit="say">
              <p :if={@answer_to}>
                Answering a request <button type="button" phx-click="cancel_answer">Cancel</button>
              </p>
              <label>Message <textarea name="text" required maxlength="32000" rows="4"></textarea></label>
              <button>{if @answer_to, do: "Send answer", else: "Send"}</button>
            </form>
          <% else %>
            <h2>Welcome</h2><p>Select a conversation or create one to start chatting.</p>
          <% end %>
        </section>
      </div>
    </main>
    """
  end
end

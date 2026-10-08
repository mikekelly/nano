defmodule NanoWeb.SeedBotsLive do
  @moduledoc """
  Consumer chat surface. Integrate with `live "/bots", SeedBotsLive` in the browser
  scope. Model text is escaped plain text, including code: never raw HTML.
  Browser integrations may listen for `phx:seed-bots:message` (title, body) and
  `seed-bots:notifications` (a permission-request gesture). No notification permission
  or delivery is claimed without such a client listener.
  """
  use Phoenix.LiveView
  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket) do
    if connected?(socket) do
      SeedBots.subscribe()
      :timer.send_interval(1000, :statuses)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Bots",
       bots: [],
       sessions: [],
       current: nil,
       selected: [],
       query: "",
       search: "",
       draft: "",
       creating: false,
       error: nil,
       notice: nil,
       statuses: %{},
       requests: %{},
       notifications: false
     )
     |> refresh()}
  end

  def handle_info(:statuses, socket) do
    statuses =
      if socket.assigns.current, do: SeedBots.statuses(socket.assigns.current.id), else: %{}

    {:noreply, assign(socket, statuses: statuses)}
  end

  def handle_info({:seed_bots, _}, socket) do
    previous = for s <- socket.assigns.sessions, m <- s.messages, into: MapSet.new(), do: m.id
    socket = refresh(socket)

    fresh =
      for s <- socket.assigns.sessions,
          m <- s.messages,
          not MapSet.member?(previous, m.id),
          m.author not in [:user, "user"],
          do: {s, m}

    socket =
      Enum.reduce(fresh, socket, fn {s, m}, acc ->
        acc = assign(acc, notice: "New message in #{s.title}")

        if acc.assigns.notifications,
          do:
            push_event(acc, "seed-bots:message", %{
              title: s.title,
              body: String.slice(m.text, 0, 160)
            }),
          else: acc
      end)

    {:noreply, socket}
  end

  def handle_event("new-chat", _, socket),
    do:
      {:noreply,
       assign(socket,
         current: nil,
         selected: [],
         query: "",
         draft: "",
         error: nil,
         creating: false
       )}

  def handle_event("search", %{"search" => q}, socket), do: {:noreply, assign(socket, search: q)}
  def handle_event("query", %{"query" => q}, socket), do: {:noreply, assign(socket, query: q)}

  def handle_event("select", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.bots, &(&1.id == id)),
      do:
        {:noreply,
         assign(socket,
           selected: Enum.uniq(socket.assigns.selected ++ [id]),
           query: "",
           error: nil
         )},
      else: {:noreply, assign(socket, error: "That bot is no longer available.")}
  end

  def handle_event("remove", %{"id" => id}, socket),
    do: {:noreply, assign(socket, selected: List.delete(socket.assigns.selected, id))}

  def handle_event("open", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.sessions, &(&1.id == id)) do
      nil -> {:noreply, assign(socket, error: "That chat is no longer available.")}
      session -> {:noreply, assign(socket, current: session, draft: "", error: nil, notice: nil)}
    end
  end

  def handle_event("show-create", _, socket), do: {:noreply, assign(socket, creating: true)}
  def handle_event("cancel-create", _, socket), do: {:noreply, assign(socket, creating: false)}

  def handle_event("create-bot", %{"bot" => attrs}, socket) do
    case SeedBots.create_bot(Map.take(attrs, ["name", "description", "color"])) do
      {:ok, bot} ->
        {:noreply,
         socket
         |> refresh()
         |> assign(
           creating: false,
           query: "",
           selected: Enum.uniq(socket.assigns.selected ++ [bot.id]),
           error: nil
         )}

      {:error, _} ->
        {:noreply,
         assign(socket, error: "Could not create the bot. Check its name and try again.")}
    end
  end

  def handle_event("draft", %{"text" => text}, socket),
    do: {:noreply, assign(socket, draft: text)}

  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, assign(socket, error: "Write a message first.")}

      socket.assigns.current == nil and socket.assigns.selected == [] ->
        {:noreply, assign(socket, error: "Choose at least one bot first.", draft: text)}

      true ->
        case ensure_session(socket) do
          {:ok, session} ->
            # Keep a newly created session on failure; retrying must not create duplicates.
            socket = assign(socket, current: session, draft: text)

            case SeedBots.post(session.id, text) do
              {:ok, _} ->
                {:noreply, socket |> refresh() |> assign(draft: "", error: nil)}

              {:error, _} ->
                {:noreply,
                 assign(socket, error: "Message not sent. Your draft is saved; please try again.")}
            end

          {:error, _} ->
            {:noreply,
             assign(socket, draft: text, error: "Could not start this chat. Please try again.")}
        end
    end
  end

  def handle_event("notifications", _, socket),
    do: {:noreply, assign(socket, notifications: not socket.assigns.notifications)}

  def handle_event("stop", _, socket) do
    if socket.assigns.current, do: SeedBots.stop(socket.assigns.current.id)
    {:noreply, socket}
  end

  def handle_event("answer", %{"request" => rid, "text" => text}, socket) do
    case SeedBots.answer(rid, text) do
      :ok ->
        {:noreply, refresh(socket)}

      _ ->
        {:noreply,
         assign(socket, error: "Could not submit answer; request may already be answered.")}
    end
  end

  def handle_event("dismiss", _, socket), do: {:noreply, assign(socket, notice: nil)}

  defp ensure_session(%{assigns: %{current: nil, selected: ids}}),
    do: SeedBots.create_session(ids)

  defp ensure_session(%{assigns: %{current: s}}), do: {:ok, s}

  defp refresh(socket) do
    sessions = SeedBots.sessions()

    current =
      if socket.assigns.current, do: Enum.find(sessions, &(&1.id == socket.assigns.current.id))

    requests =
      for s <- sessions,
          m <- s.messages,
          rid = Map.get(m, :request_id),
          rid != nil,
          into: %{},
          do: {rid, SeedBots.request(rid)}

    assign(socket,
      bots: SeedBots.bots(),
      sessions: sessions,
      current: current,
      requests: requests
    )
  end

  defp matches?(text, query), do: String.contains?(String.downcase(text), String.downcase(query))

  defp bot(bots, id),
    do: Enum.find(bots, &(&1.id == id)) || %{id: id, name: "Bot", color: "#818cf8"}

  defp initials(name),
    do:
      name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()

  defp safe_color(color) do
    if is_binary(color) and Regex.match?(~r/^#[0-9a-fA-F]{6}$/, color), do: color, else: "#818cf8"
  end

  defp preview(%{messages: messages}) do
    case List.last(messages) do
      nil -> "Start a conversation"
      message -> String.slice(message.text, 0, 100)
    end
  end

  defp author_name(author, _) when author in [:user, "user"], do: "You"
  defp author_name("system", _), do: "Chat"
  defp author_name(author, bots), do: bot(bots, author).name
  attr :bot, :map, required: true

  defp face(assigns) do
    ~H"""
    <span class="sb-face" style={"background: #{safe_color(@bot.color)}"} aria-hidden="true">{initials(
      @bot.name
    )}</span>
    """
  end

  def render(assigns) do
    ~H"""
    <div id="seed-bots" class="sb-app">
      <style>
        #seed-bots{font-family:system-ui,sans-serif;color:#263247;background:#fff;display:grid;grid-template-columns:290px minmax(0,1fr);height:calc(100dvh - 2rem);min-height:500px;border:1px solid #e7eaf0;border-radius:24px;overflow:hidden;max-width:1400px;margin:1rem auto;box-shadow:0 12px 45px #2732470a}#seed-bots *{box-sizing:border-box}#seed-bots button,#seed-bots input,#seed-bots textarea{font:inherit}#seed-bots button{cursor:pointer;border:0;border-radius:16px;padding:10px 14px;background:#eef1f7;color:#263247}#seed-bots button:hover{background:#e2e7f2}#seed-bots button:focus-visible,#seed-bots input:focus-visible,#seed-bots textarea:focus-visible{outline:3px solid #818cf8;outline-offset:2px}.sb-sidebar{padding:24px 16px;background:#f7f8fc;border-right:1px solid #e7eaf0;display:flex;flex-direction:column;gap:16px;overflow:auto}.sb-toolbar{display:flex;justify-content:space-between;align-items:center}.sb-toolbar h1{font-size:22px;margin:0}.sb-face{width:40px;height:40px;border-radius:15px;display:inline-flex;align-items:center;justify-content:center;font-size:13px;font-weight:700;color:#fff;flex-shrink:0}.sb-main-bot{display:flex;align-items:center;gap:12px;padding:12px 0}.sb-main-bot .sb-face{width:58px;height:58px;border-radius:22px}.sb-chat{width:100%;text-align:left;display:flex;gap:10px;margin:4px 0;background:transparent!important}.sb-chat.active{background:#e7eafa!important}.sb-chat-copy{min-width:0;display:flex;flex-direction:column;gap:4px}.sb-preview{font-size:12px;color:#758095;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.sb-sidebar footer{margin-top:auto;color:#758095;font-size:12px}.sb-content{display:flex;flex-direction:column;min-width:0;min-height:0}.sb-header{padding:20px 28px;border-bottom:1px solid #eef1f7;display:flex;align-items:center;gap:8px;flex-wrap:wrap}.sb-chip{display:inline-flex;gap:8px;align-items:center;background:#f1f3fa;padding:6px 10px;border-radius:24px}.sb-chip .sb-face{width:28px;height:28px;border-radius:50%}.sb-picker{padding:16px 28px;max-height:45%;overflow:auto}.sb-options{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}.sb-options button{display:flex;align-items:center;gap:10px}.sb-input{width:100%;padding:12px;border:1px solid #e0e5ef;border-radius:14px;background:white;color:#263247}.sb-empty{margin:auto;text-align:center;padding:30px;color:#758095}.sb-empty h2{color:#263247;font-size:28px}.sb-messages{list-style:none;margin:0;padding:24px 28px;overflow:auto;flex:1}.sb-message{display:flex;flex-direction:column;align-items:flex-start;margin:16px 0;gap:5px}.sb-message.user{align-items:flex-end}.sb-author{font-size:12px;color:#758095}.sb-bubble{white-space:pre-wrap;overflow-wrap:anywhere;max-width:min(85%,740px);background:#f1f3f8;padding:14px 18px;border-radius:20px;line-height:1.6}.sb-message.user .sb-bubble{background:#5964d8;color:white}.sb-composer{margin:16px 28px 24px;display:flex;align-items:flex-end;gap:12px;padding:10px;background:#f7f8fc;border:1px solid #e7eaf0;border-radius:24px}.sb-composer textarea{resize:vertical;border:0;background:transparent;flex:1;min-width:0;max-height:180px;padding:10px;color:#263247}.sb-composer button{background:#5964d8!important;color:white!important}.sb-alert{margin:10px 28px;padding:10px 14px;background:#fff3df;border-radius:12px;font-size:14px}.sb-create{display:grid;gap:10px;margin-top:12px}.sb-muted{font-size:12px;color:#758095}@media(max-width:700px){#seed-bots{grid-template-columns:130px minmax(0,1fr);border-radius:0;margin:0;height:100dvh}.sb-sidebar{padding:16px 8px}.sb-main-bot{flex-direction:column}.sb-chat .sb-face{display:none}.sb-header,.sb-picker{padding:14px}.sb-messages{padding:14px}.sb-composer{margin:10px}.sb-bubble{max-width:100%}.sb-toolbar h1{font-size:17px}}
      </style>
      <aside class="sb-sidebar" aria-label="Chats">
        <div class="sb-toolbar">
          <h1>Bots</h1><button id="new-chat" phx-click="new-chat" aria-label="New chat">＋</button>
        </div>
        <form phx-change="search" role="search">
          <input
            class="sb-input"
            type="search"
            name="search"
            value={@search}
            placeholder="Search chats"
            aria-label="Search chats"
          />
        </form>
        <div :if={@bots != []} class="sb-main-bot">
          <.face bot={hd(@bots)} /><strong>{hd(@bots).name}</strong>
        </div>
        <nav aria-label="Conversations">
          <button
            :for={s <- Enum.filter(@sessions, &matches?(&1.title <> " " <> preview(&1), @search))}
            class={["sb-chat", @current && @current.id == s.id && "active"]}
            phx-click="open"
            phx-value-id={s.id}
            aria-current={if @current && @current.id == s.id, do: "true", else: "false"}
          >
            <.face bot={bot(@bots, List.first(s.bot_ids))} /><span class="sb-chat-copy"><strong>{s.title}</strong><span class="sb-preview">{preview(
              s
            )}</span></span>
          </button>
        </nav>
        <footer>
          <span class="sb-chip">You</span><p>Your space to think together.</p><button
            id="notifications"
            phx-click={JS.dispatch("seed-bots:notifications") |> JS.push("notifications")}
            aria-pressed={to_string(@notifications)}
          >{if @notifications, do: "Mute alerts", else: "Enable alerts"}</button><p class="sb-muted">
            Browser alerts require client support and permission.
          </p>
        </footer>
      </aside>
      <main class="sb-content">
        <header class="sb-header">
          <strong>{if @current, do: @current.title, else: "To:"}</strong>
          <span :for={id <- if(@current, do: @current.bot_ids, else: @selected)} class="sb-chip"><.face bot={
            bot(@bots, id)
          } />{bot(@bots, id).name}<button
            :if={!@current}
            phx-click="remove"
            phx-value-id={id}
            aria-label={"Remove #{bot(@bots, id).name}"}
          >×</button></span>
          <button :if={@current} phx-click="stop">Stop bots</button>
        </header>
        <p
          :for={{bid, status} <- @statuses}
          :if={status != :idle}
          role="status"
          class="sb-muted"
          style="margin:10px 28px"
        >
          {bot(@bots, bid).name}: {if status == :thinking,
            do: "Thinking…",
            else: "Unavailable; check operator dashboard"}
        </p>
        <div :if={!@current} class="sb-picker">
          <form phx-change="query">
            <input
              id="bot-query"
              class="sb-input"
              name="query"
              value={@query}
              placeholder="Find a bot or choose several for a group"
              aria-label="Find bots"
            />
          </form>
          <div class="sb-options">
            <button phx-click="show-create">＋ Create {if @query == "", do: "new bot", else: @query}</button><button
              :for={b <- Enum.filter(@bots, &matches?(&1.name, @query))}
              phx-click="select"
              phx-value-id={b.id}
              disabled={b.id in @selected}
            ><.face bot={b} />{b.name}</button>
          </div>
          <p class="sb-muted">
            Choose two or more bots for a shared group chat. Tab to a bot and press Enter to select.
          </p>
          <form :if={@creating} id="create-bot" class="sb-create" phx-submit="create-bot">
            <label>Name<input
              class="sb-input"
              name="bot[name]"
              value={@query}
              required
              maxlength="80"
            /></label>
            <label>About this bot<textarea
              class="sb-input"
              name="bot[description]"
              placeholder="A friendly research partner…"
              maxlength="2000"
            ></textarea></label>
            <label>Face colour<input type="color" name="bot[color]" value="#818cf8" /></label>
            <div>
              <button type="submit">Create bot</button>
              <button type="button" phx-click="cancel-create">Cancel</button>
            </div>
          </form>
        </div>
        <p :if={@error} role="alert" class="sb-alert">{@error}</p>
        <div :if={@notice} role="status" class="sb-alert">
          {@notice} <button phx-click="dismiss" aria-label="Dismiss notification">×</button>
        </div>
        <ol
          :if={@current && @current.messages != []}
          id="bot-messages"
          class="sb-messages"
          aria-label="Messages"
          aria-live="polite"
        >
          <li
            :for={m <- @current.messages}
            id={"message-#{m.id}"}
            class={["sb-message", m.author in [:user, "user"] && "user"]}
          >
            <span class="sb-author">{author_name(m.author, @bots)}</span><div class="sb-bubble">
              {m.text}
            </div>
            <form
              :if={Map.get(m, :request_id) && get_in(@requests, [m.request_id, :status]) == :pending}
              phx-submit="answer"
              class="sb-chip"
            >
              <input type="hidden" name="request" value={Map.get(m, :request_id)} />
              <input name="text" aria-label="Answer request" required class="sb-input" />
              <button type="submit">Answer</button>
            </form>
          </li>
        </ol>
        <div :if={!@current || @current.messages == []} class="sb-empty">
          <h2>A little company.<br />A lot of possibility.</h2><p>
            Ask a question, share an idea, or make a plan.
          </p>
        </div>
        <form id="bot-composer" class="sb-composer" phx-change="draft" phx-submit="send">
          <textarea
            id="message-text"
            name="text"
            rows="2"
            placeholder={
              if @current, do: "Message #{@current.title}", else: "Write your first message…"
            }
            aria-label="Message"
            maxlength="20000"
          >{@draft}</textarea>
          <button type="submit" aria-label="Send message">Send ↑</button>
        </form>
        <p class="sb-muted" style="margin:0 28px 12px">
          Replies appear here when ready. Attachments and voice are not available yet.
        </p>
      </main>
    </div>
    """
  end
end

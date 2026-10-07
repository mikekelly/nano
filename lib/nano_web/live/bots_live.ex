defmodule NanoWeb.BotsLive do
  @moduledoc "Consumer-only chat; all model text is HTML escaped. No harness log rendering."
  use Phoenix.LiveView
  import NanoWeb.BotsMarkdown

  def mount(_, _, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Nano.PubSub, "nano:bots")

    {:ok,
     assign(socket,
       page_title: "Bots",
       data: Nano.Bots.snapshot(),
       selected: nil,
       chips: [],
       query: "",
       model: Application.get_env(:nano, :bots_agent_options, [])[:model] || "",
       notice: nil
     )
     |> allow_upload(:files, accept: :any, max_entries: 1, max_file_size: 5_000_000)}
  end

  def handle_info({:bots_changed, event}, socket) do
    socket = assign(socket, data: Nano.Bots.snapshot())

    socket =
      if event[:notify],
        do:
          push_event(socket, "bot-notification", %{
            text: "A bot has a new message",
            session: event[:session]
          }),
        else: socket

    {:noreply, socket}
  end

  def handle_event("new", _, socket),
    do: {:noreply, assign(socket, selected: nil, chips: [], notice: nil)}

  def handle_event("filter", %{"query" => q} = params, socket),
    do: {:noreply, assign(socket, query: q, model: params["model"] || socket.assigns.model)}

  def handle_event("chip", %{"id" => id}, socket),
    do: {:noreply, assign(socket, chips: Enum.uniq(socket.assigns.chips ++ [id]), query: "")}

  def handle_event("remove", %{"id" => id}, socket),
    do: {:noreply, assign(socket, chips: socket.assigns.chips -- [id])}

  def handle_event("create", _, socket) do
    opts = Application.get_env(:nano, :bots_agent_options, [])

    opts =
      if socket.assigns.model != "",
        do: Keyword.put(opts, :model, socket.assigns.model),
        else: opts

    case Nano.Bots.create_bot(socket.assigns.query, agent_options: opts) do
      {:ok, bot} ->
        {:noreply,
         assign(socket,
           data: Nano.Bots.snapshot(),
           chips: socket.assigns.chips ++ [bot.id],
           query: ""
         )}

      e ->
        {:noreply, assign(socket, notice: inspect(e))}
    end
  end

  def handle_event("start", _, socket) do
    case Nano.Bots.create_session(socket.assigns.chips) do
      {:ok, chat} -> {:noreply, assign(socket, data: Nano.Bots.snapshot(), selected: chat.id)}
      e -> {:noreply, assign(socket, notice: inspect(e))}
    end
  end

  def handle_event("open", %{"id" => id}, socket), do: {:noreply, assign(socket, selected: id)}

  def handle_event("upload_validate", _, socket), do: {:noreply, socket}

  def handle_event("send", %{"text" => text}, socket) do
    attachments =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        {:ok,
         Nano.Bots.attach(socket.assigns.selected, :human, path, filename: entry.client_name)}
      end)

    error = Enum.find(attachments, &match?({:error, _}, &1))

    result =
      cond do
        error ->
          error

        String.trim(text) != "" ->
          Nano.Bots.say(socket.assigns.selected, text)

        attachments != [] ->
          Nano.Bots.say(
            socket.assigns.selected,
            "Please review the attached file."
          )

        true ->
          {:error, :empty_message}
      end

    {:noreply,
     assign(socket,
       data: Nano.Bots.snapshot(),
       notice: if(result == :ok, do: nil, else: inspect(result))
     )}
  end

  def handle_event("answer", %{"text" => text, "request" => rid}, socket) do
    result = Nano.Bots.answer(rid, text)

    {:noreply,
     assign(socket,
       data: Nano.Bots.snapshot(),
       notice: if(result == :ok, do: nil, else: inspect(result))
     )}
  end

  def handle_event("notifications", _, socket) do
    Nano.Bots.set_notifications(not socket.assigns.data.notifications)
    {:noreply, assign(socket, data: Nano.Bots.snapshot()) |> push_event("bot-permission", %{})}
  end

  defp chats(data), do: data.sessions |> Map.values() |> Enum.sort_by(& &1.updated_at, :desc)

  defp bots(data, query),
    do:
      data.bots
      |> Map.values()
      |> Enum.sort_by(& &1.created_at)
      |> Enum.filter(&String.contains?(String.downcase(&1.name), String.downcase(query)))

  def status_label(:thinking), do: "is thinking…"
  def status_label(:no_reply), do: "finished without a reply. Try asking again."

  def status_label(:paused),
    do: "is paused at its budget limit. Start a new conversation to continue."

  def status_label(_), do: "is unavailable — ask the operator to configure the bot model."

  defp label(:human, _), do: "You"
  defp label(id, data), do: data.bots[id].name

  def render(assigns) do
    ~H"""
    <div class="bot-app" id="bot-app">
      <aside>
        <header><strong>Bots</strong><button phx-click="new" aria-label="New chat">＋</button></header>
        <div :for={bot <- Enum.take(bots(@data, ""), 1)} class="main-bot">
          <span class="face" style={"background:#{bot.color}"}>◕‿◕</span><h2>{bot.name}</h2><p>
            {bot.description}
          </p>
        </div>
        <nav aria-label="Chats">
          <button
            :for={chat <- chats(@data)}
            phx-click="open"
            phx-value-id={chat.id}
            class={if @selected == chat.id, do: "selected", else: ""}
          >
            <span
              :for={id <- chat.bots}
              class="mini-face"
              style={"background:#{@data.bots[id].color}"}
            >◕‿◕</span>
            <strong>{chat.title}</strong><small>{if List.last(chat.messages),
              do: String.slice(List.last(chat.messages).text, 0, 65),
              else: "New conversation"}</small>
          </button>
        </nav>
        <footer>
          <span class="mini-face">You</span><button phx-click="notifications">{if @data.notifications,
            do: "Mute notifications",
            else: "Enable notifications"}</button><small>At most one notification per minute</small>
        </footer>
      </aside>
      <main>
        <p :if={@notice} role="alert">{@notice}</p>
        <%= if @selected && @data.sessions[@selected] do %>
          <% chat = @data.sessions[@selected] %>
          <header class="participants">{chat.title}</header>
          <section class="messages" aria-live="polite">
            <article :for={m <- chat.messages} class={if m.who == :human, do: "human", else: "bot"}>
              <strong>{label(m.who, @data)}</strong> <.message text={m.text} />
              <a
                :for={file <- Map.get(m, :files, [])}
                href={"/bots/files/#{file.service}/#{file.id}"}
                download={file.filename}
                class="file"
              >📎 {file.filename} ({file.size} bytes)</a>

              <form
                :if={m.request && @data.requests[m.request].status == :pending}
                id={"answer-#{m.id}"}
                phx-submit="answer"
              >
                <input type="hidden" name="request" value={m.request} /><input
                  name="text"
                  required
                  aria-label="Answer request"
                  autocomplete="off"
                /><button>Answer</button>
              </form>
            </article>
            <p :for={{bid, status} <- chat.status} :if={status != :idle} class="status">
              {label(bid, @data)} {status_label(status)}
            </p>
          </section>
          <form
            phx-submit="send"
            phx-change="upload_validate"
            class="composer"
            id={"composer-#{chat.id}"}
          >
            <label aria-label="Attach file">＋<.live_file_input upload={@uploads.files} /></label>
            <input
              name="text"
              placeholder={"Message #{chat.title}"}
              aria-label="Message"
              autocomplete="off"
            /><button>Send ↑</button>
          </form>
        <% else %>
          <header>New conversation</header>
          <div class="to-line">
            <strong>To:</strong><button :for={id <- @chips} phx-click="remove" phx-value-id={id}>{@data.bots[
              id
            ].name} ×</button>
          </div>
          <form id="bot-search" phx-change="filter" phx-submit="create">
            <input
              name="model"
              value={@model}
              placeholder="Explicit model slug (e.g. google/gemini-2.5-flash-lite)"
              aria-label="Bot model"
            />
            <input
              name="query"
              value={@query}
              placeholder="Search or create a bot"
              aria-label="Search or create a bot"
              autocomplete="off"
            />
          </form>
          <div class="choices" role="list">
            <button :if={String.trim(@query) != ""} phx-click="create">Create new Bot “{@query}”</button>
            <button :for={bot <- bots(@data, @query)} phx-click="chip" phx-value-id={bot.id}><span
              class="mini-face"
              style={"background:#{bot.color}"}
            >◕‿◕</span>{bot.name}</button>
          </div>
          <button phx-click="start" disabled={@chips == []}>{if length(@chips) > 1,
            do: "Create group chat",
            else: "Start chat"}</button>
        <% end %>
      </main>
    </div>
    """
  end
end

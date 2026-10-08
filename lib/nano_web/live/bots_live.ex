defmodule NanoWeb.BotsLive do
  @moduledoc "Consumer chat; model content is escaped text, never raw HTML."
  use Phoenix.LiveView
  alias Seedling.Bots

  def mount(_, _, socket) do
    if connected?(socket) do
      Bots.subscribe()
      :timer.send_interval(1500, :status)
    end

    {:ok,
     socket
     |> assign(page_title: "Bots", selected: nil, chips: [], query: "", error: nil, thinking: [])
     |> refresh()}
  end

  def handle_info(:status, s) do
    chat = s.assigns.data.sessions[s.assigns.selected]

    thinking =
      if chat,
        do:
          Enum.filter(chat.bots, fn id ->
            case Nano.Ops.agent("bot-" <> id <> "-" <> chat.id) do
              %{status: status} when status in [:thinking, :running_tool, :waiting_retry] -> true
              _ -> false
            end
          end),
        else: []

    {:noreply, assign(s, thinking: thinking)}
  end

  def handle_info(:bots_updated, s) do
    old = s.assigns.data
    s = refresh(s)

    changed =
      Enum.any?(s.assigns.data.sessions, fn {id, chat} ->
        previous = old.sessions[id]
        last = List.last(chat.messages)

        last && last.author != "human" &&
          (!previous || length(chat.messages) > length(previous.messages))
      end)

    {:noreply, if(changed, do: push_event(s, "bot-notify", %{title: "Your bots"}), else: s)}
  end

  defp refresh(s), do: assign(s, data: Bots.snapshot())
  def handle_event("query", %{"q" => q}, s), do: {:noreply, assign(s, query: q)}
  def handle_event("new", _, s), do: {:noreply, assign(s, selected: nil, chips: [])}
  def handle_event("open", %{"id" => id}, s), do: {:noreply, assign(s, selected: id)}

  def handle_event("chip", %{"id" => id}, s) do
    chips =
      if id in s.assigns.chips,
        do: List.delete(s.assigns.chips, id),
        else: s.assigns.chips ++ [id]

    {:noreply, assign(s, chips: chips)}
  end

  def handle_event("create", %{"name" => name}, s) do
    case Bots.create_bot(name) do
      {:ok, bot} ->
        {:noreply, s |> assign(chips: s.assigns.chips ++ [bot.id], query: "") |> refresh()}

      e ->
        {:noreply, assign(s, error: inspect(e))}
    end
  end

  def handle_event("start", _, s) do
    case Bots.create_session(s.assigns.chips) do
      {:ok, chat} -> {:noreply, s |> assign(selected: chat.id) |> refresh()}
      e -> {:noreply, assign(s, error: inspect(e))}
    end
  end

  def handle_event("send", %{"text" => text}, s) do
    result = Bots.say(s.assigns.selected, text)

    {:noreply,
     s |> assign(error: error(result)) |> refresh() |> push_event("clear-composer", %{})}
  end

  def handle_event("answer", %{"request" => id, "text" => text}, s) do
    {:noreply, s |> assign(error: error(Bots.answer(id, text))) |> refresh()}
  end

  defp error(:ok), do: nil
  defp error({:ok, _}), do: nil
  defp error(e), do: inspect(e)
  defp author(_data, "human"), do: "You"
  defp author(data, id), do: data.bots[id].name

  def render(assigns) do
    assigns =
      assign(assigns,
        chat: assigns.data.sessions[assigns.selected],
        bots: assigns.data.bots |> Map.values() |> Enum.sort_by(& &1.created),
        chats: assigns.data.sessions |> Map.values() |> Enum.sort_by(& &1.updated, :desc)
      )

    ~H"""
    <style>
      .bots-app{position:fixed;inset:0;background:#fff;color:#252733;display:grid;grid-template-columns:290px 1fr;font-family:system-ui;z-index:5}.bots-app aside{background:#f8f8fa;padding:22px;border-right:1px solid #eee;overflow:auto}.bots-app button{border:0;border-radius:16px;background:#eeeef3;color:#333;padding:10px 16px;cursor:pointer}.bots-app input,.bots-app textarea{background:white;color:#333;border:1px solid #e6e6ec;border-radius:18px;padding:14px;font:inherit}.bots-app .face{border-radius:50%;width:44px;height:44px;display:inline-grid;place-items:center;margin-right:10px;color:white}.bots-app .chatrow{display:block;width:100%;text-align:left;margin-top:8px;background:transparent}.bots-app .chatrow.active{background:#e9e5f4}.bots-app .preview{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#8a8892;font-size:13px}.bots-app main{display:flex;flex-direction:column;max-width:100%;overflow:hidden;padding:30px}.bots-app .conversation{flex:1;overflow:auto;padding:20px 0}.bots-app .bubble{background:#f4f3f7;border-radius:20px;padding:14px 20px;margin:12px 0;max-width:75%;white-space:pre-wrap;overflow-wrap:anywhere}.bots-app .bubble.human{margin-left:auto;background:#ebe4f8}.bots-app .composer{display:flex;gap:10px;padding-top:16px}.bots-app .composer textarea{flex:1;resize:vertical}.bots-app .to{display:flex;flex-wrap:wrap;gap:10px;align-items:center}.bots-app .options{margin-top:25px;display:flex;flex-direction:column;gap:10px;max-width:420px}.bots-app .main-bot{margin:28px 0}.bots-app .main-bot strong{font-size:24px}.bots-app small{color:#777}.bots-app .error{color:#a32d41}@media(max-width:700px){.bots-app{grid-template-columns:110px 1fr}.bots-app aside{padding:10px}.bots-app main{padding:14px}.bots-app .face{width:28px;height:28px}.bots-app .main-bot strong{font-size:16px}.bots-app .bubble{max-width:95%}}
    </style>
    <div class="bots-app" id="bots-chat" phx-hook="Chat">
      <aside>
        <button phx-click="new" aria-label="New chat">＋ New chat</button>
        <div :if={List.first(@bots)} class="main-bot">
          <span class="face" style={"background:"<>hd(@bots).color}>{hd(@bots).face}</span><strong>{hd(
            @bots
          ).name}</strong>
        </div>
        <button
          :for={chat <- @chats}
          class={["chatrow", chat.id == @selected && "active"]}
          phx-click="open"
          phx-value-id={chat.id}
        >
          <span :for={id <- chat.bots} class="face" style={"background:"<>@data.bots[id].color}>{@data.bots[
            id
          ].face}</span>
          {chat.title}<span class="preview">{if List.last(chat.messages),
            do: List.last(chat.messages).text,
            else: "Start a conversation"}</span>
        </button>
        <p><small>YO · Your space</small></p><button id="bot-notifications" type="button">Enable / mute notifications</button><label><small>At most one notification every</small><select id="notification-rate"><option value="300000">
          5 minutes
        </option><option value="1800000">30 minutes</option><option value="3600000">Hour</option></select></label><.link navigate="/">Operator dashboard</.link>
      </aside>
      <main>
        <p :if={@error} class="error" role="alert">{@error}</p>
        <section :if={!@chat}>
          <h1>Who would you like to talk to?</h1>
          <div class="to">
            <strong>To:</strong><button :for={id <- @chips} phx-click="chip" phx-value-id={id}>{@data.bots[
              id
            ].name} ×</button>
          </div>
          <form id="bot-search" phx-change="query">
            <input
              name="q"
              value={@query}
              placeholder="Search bots or type a new name"
              aria-label="Search bots"
              autofocus
            />
          </form>
          <div class="options">
            <button
              :for={bot <- @bots}
              :if={String.contains?(String.downcase(bot.name), String.downcase(@query))}
              phx-click="chip"
              phx-value-id={bot.id}
              data-bot-choice
            ><span class="face" style={"background:"<>bot.color}>{bot.face}</span>{bot.name}<small>{bot.description}</small></button>
            <form phx-submit="create">
              <input type="hidden" name="name" value={if @query == "", do: "New Bot", else: @query} /><button>Create new Bot {if @query !=
                                                                                                                                   "",
                                                                                                                                 do:
                                                                                                                                   "“" <>
                                                                                                                                     @query <>
                                                                                                                                     "”"}</button>
            </form>
            <button :if={@chips != []} phx-click="start">{if length(@chips) > 1,
              do: "Create group chat",
              else: "Start chat"} →</button>
          </div>
        </section>
        <header :if={@chat}>
          <strong>{@chat.title}</strong><small> · Shared conversation</small>
        </header>
        <div :if={@chat} class="conversation" aria-live="polite">
          <article
            :for={m <- @chat.messages}
            class={["bubble", m.author == "human" && "human"]}
            id={"msg-"<>m.id}
          >
            <small>{author(@data, m.author)}</small><div :for={
              block <- Seedling.Bots.Text.blocks(m.text)
            }>
              <pre :if={block.type == :code}><small>{block.language}</small><code>{block.text}</code></pre><p :if={
                block.type == :paragraph
              }>
                {block.text}
              </p>
            </div>
            <form
              :if={Map.get(m, :request) && @data.requests[m.request].status == "pending"}
              phx-submit="answer"
            >
              <input type="hidden" name="request" value={m.request} /><input
                name="text"
                placeholder="Your answer"
                required
              /><button>Answer request</button>
            </form>
            <small :if={Map.get(m, :request) && @data.requests[m.request].status == "answered"}>Answered: {@data.requests[
              m.request
            ].answer}</small>
          </article>
        </div>
        <small :if={@thinking != []} role="status">{Enum.map_join(
          @thinking,
          ", ",
          &@data.bots[&1].name
        )} thinking…</small>
        <form :if={@chat} class="composer" phx-submit="send">
          <textarea
            name="text"
            aria-label="Message"
            placeholder={"Message "<>@chat.title}
            required
            rows="2"
            maxlength="32000"
          ></textarea><button>Send ↑</button>
        </form>
      </main>
    </div>
    """
  end
end

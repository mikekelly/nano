defmodule NanoWeb.BotsLive do
  @moduledoc "Consumer chat at /bots: named persistent bots and groups, never eval/tool/harness traffic."
  use Phoenix.LiveView
  alias Seedling.{Bots, BotFiles, ChatMarkup}
  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Nano.PubSub, "bots")

    {:ok,
     socket
     |> assign(
       page_title: "Bots",
       selected: nil,
       recipients: [],
       query: "",
       creating: false,
       draft: "",
       error: nil,
       doc: Bots.snapshot()
     )
     |> allow_upload(:files, accept: :any, max_entries: 4, max_file_size: 5_000_000)}
  end

  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, selected: params["session"], doc: Bots.snapshot())}

  def handle_info({:bots, event}, socket) do
    socket = assign(socket, doc: Bots.snapshot())

    socket =
      if event[:notify] && event[:message] do
        msg = event.message
        bot = socket.assigns.doc["bots"][msg["speaker"]]

        push_event(socket, "bot-notification", %{
          title: if(bot, do: bot["name"], else: "Your bot"),
          body: String.slice(msg["text"], 0, 160),
          session: event.session
        })
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("new", _, socket),
    do:
      {:noreply,
       socket
       |> assign(selected: nil, recipients: [], query: "", creating: false, error: nil)
       |> push_patch(to: "/bots")}

  def handle_event("query", %{"query" => query}, socket),
    do: {:noreply, assign(socket, query: String.slice(query, 0, 100))}

  def handle_event("choose", %{"bot" => id}, socket) do
    ids = Enum.uniq(socket.assigns.recipients ++ [id]) |> Enum.take(8)
    {:noreply, assign(socket, recipients: ids, query: "", creating: false)}
  end

  def handle_event("remove", %{"bot" => id}, socket),
    do: {:noreply, assign(socket, recipients: List.delete(socket.assigns.recipients, id))}

  def handle_event("create-form", _, socket), do: {:noreply, assign(socket, creating: true)}

  def handle_event("create", p, socket) do
    opts = [
      model: p["model"],
      reasoning: p["reasoning"],
      max_context: integer(p["context"], 64000),
      description: p["description"]
    ]

    case safe(fn -> Bots.create(p["name"], opts) end) do
      {:ok, bot} ->
        {:noreply,
         assign(socket,
           doc: Bots.snapshot(),
           recipients: Enum.uniq(socket.assigns.recipients ++ [bot["id"]]),
           creating: false,
           query: "",
           error: nil
         )}

      {:error, error} ->
        {:noreply, assign(socket, error: friendly(error))}
    end
  end

  def handle_event("start", _, socket) do
    case safe(fn -> Bots.session(socket.assigns.recipients) end) do
      {:ok, chat} ->
        {:noreply,
         socket
         |> assign(selected: chat["id"], error: nil, doc: Bots.snapshot())
         |> push_patch(to: "/bots?" <> URI.encode_query(session: chat["id"]))}

      {:error, error} ->
        {:noreply, assign(socket, error: friendly(error))}
    end
  end

  def handle_event("draft", %{"text" => text}, socket),
    do: {:noreply, assign(socket, draft: text)}

  def handle_event("send", %{"text" => text}, socket) do
    files =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        case BotFiles.add(path, entry.client_name) do
          {:ok, file} -> {:ok, file}
          {:error, error} -> {:ok, %{error: error}}
        end
      end)

    result =
      if Enum.any?(files, &Map.has_key?(&1, :error)),
        do: {:error, :invalid_attachment},
        else: safe(fn -> Bots.say(socket.assigns.selected, text, files: files) end)

    case result do
      {:ok, _} -> {:noreply, assign(socket, draft: "", error: nil, doc: Bots.snapshot())}
      {:error, error} -> {:noreply, assign(socket, error: friendly(error))}
    end
  end

  def handle_event("answer", %{"request" => id, "answer" => text}, socket) do
    case safe(fn -> Bots.answer(id, text, session: socket.assigns.selected) end) do
      {:ok, _} -> {:noreply, assign(socket, error: nil, doc: Bots.snapshot())}
      {:error, error} -> {:noreply, assign(socket, error: friendly(error))}
    end
  end

  def handle_event("notify", _, socket) do
    enabled = not socket.assigns.doc["notifications"]["enabled"]
    safe(fn -> Bots.notifications(enabled: enabled) end)
    {:noreply, assign(socket, doc: Bots.snapshot())}
  end

  def handle_event("limits", p, socket) do
    settings = [
      per_hour: integer(p["per_hour"], 3),
      cooldown_seconds: integer(p["cooldown"], 60),
      quiet_start: integer(p["quiet_start"], nil),
      quiet_end: integer(p["quiet_end"], nil)
    ]

    case safe(fn -> Bots.notifications(settings) end) do
      {:ok, _} -> {:noreply, assign(socket, error: nil, doc: Bots.snapshot())}
      {:error, error} -> {:noreply, assign(socket, error: friendly(error))}
    end
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :service_unavailable}
  end

  defp friendly(:service_unavailable), do: "Chat is temporarily unavailable. Please try again."

  defp friendly(error),
    do:
      "Could not complete that action: " <>
        String.replace(if(is_atom(error), do: to_string(error), else: inspect(error)), "_", " ")

  defp integer(s, fallback) do
    case Integer.parse(s || "") do
      {n, ""} -> n
      _ -> fallback
    end
  end

  defp chats(doc), do: doc["sessions"] |> Map.values() |> Enum.sort_by(& &1["updated_at"], :desc)
  defp bots(doc), do: doc["bots"] |> Map.values() |> Enum.sort_by(& &1["created_at"])

  defp filtered(doc, query, recipients),
    do:
      Enum.filter(
        bots(doc),
        &(&1["id"] not in recipients and
            String.contains?(String.downcase(&1["name"]), String.downcase(query)))
      )

  defp main_bot(doc), do: List.first(bots(doc))

  defp title(doc, speaker),
    do: if(speaker == "human", do: "You", else: get_in(doc, ["bots", speaker, "name"]) || "Bot")

  defp preview(chat) do
    case List.last(chat["messages"]) do
      nil -> "Say hello"
      m -> String.slice(m["text"], 0, 70)
    end
  end

  attr :bot, :map, required: true
  attr :large, :boolean, default: false

  def face(assigns) do
    ~H"""
    <span
      class={["bot-face", @bot["shape"], @large && "large"]}
      style={"background:" <> @bot["color"]}
      aria-label={@bot["name"]}
    >◕‿◕</span>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        chat: assigns.doc["sessions"][assigns.selected],
        main: main_bot(assigns.doc)
      )

    ~H"""
    <link rel="stylesheet" href="/bots.css" />
    <div id="bots-product">
      <aside class="bots-sidebar">
        <div class="bots-tools">
          <button
            type="button"
            phx-click={JS.focus(to: "#bot-to")}
            aria-label="Search bots (Control K)"
          >⌕ Search</button>
          <button type="button" phx-click="new" aria-label="New chat">＋</button>
        </div>
        <div :if={@main} class="bot-main-card">
          <.face bot={@main} large={true} /><span>{@main["name"]}</span>
        </div>
        <nav class="bots-chat-list" aria-label="Chats">
          <.link
            :for={c <- chats(@doc)}
            patch={"/bots?" <> URI.encode_query(session: c["id"])}
            class={["bots-chat-row", @selected == c["id"] && "current"]}
          >
            <span class="bots-faces"><.face :for={id <- c["bots"]} bot={@doc["bots"][id]} /><span
              :if={length(c["bots"]) > 1}
              class="bot-face"
            >YO</span></span>
            <strong>{c["title"]}</strong><span class="preview">{preview(c)}</span>
          </.link>
        </nav>
        <div class="bot-person">
          <span class="bot-face" style="background:#e2e8f0">YO</span><span>You · local chat</span>
        </div>
        <div class="bot-notifications">
          <button type="button" id="bot-permission" phx-click="notify">{if @doc["notifications"][
                                                                             "enabled"
                                                                           ],
                                                                           do: "Mute notifications",
                                                                           else:
                                                                             "Enable notifications"}</button>
          <details>
            <summary>Interruption limits</summary>
            <form id="bot-limits" phx-submit="limits" class="bot-settings">
              <label>Per hour
              <input
                type="number"
                name="per_hour"
                min="0"
                max="30"
                value={@doc["notifications"]["per_hour"]}
              /></label>
              <label>Cooldown seconds
              <input
                type="number"
                name="cooldown"
                min="0"
                value={@doc["notifications"]["cooldown_seconds"]}
              /></label>
              <label>Quiet UTC from
              <input
                type="number"
                name="quiet_start"
                min="0"
                max="23"
                value={@doc["notifications"]["quiet_start"]}
              /></label>
              <label>to
              <input
                type="number"
                name="quiet_end"
                min="0"
                max="23"
                value={@doc["notifications"]["quiet_end"]}
              /></label>
              <button>Save</button>
            </form>
          </details>
        </div>
      </aside>
      <main class="bots-main">
        <p :if={@error} class="bot-alert" role="alert">{@error}</p>
        <section :if={!@chat}>
          <form id="bot-recipients" phx-change="query" phx-submit="start" class="bot-to-line">
            <label for="bot-to">To:</label>
            <span :for={id <- @recipients} class="bot-chip"><.face bot={@doc["bots"][id]} />{@doc[
              "bots"
            ][id]["name"]}<button
              type="button"
              phx-click="remove"
              phx-value-bot={id}
              aria-label={"Remove " <> @doc["bots"][id]["name"]}
            >×</button></span>
            <input
              id="bot-to"
              name="query"
              value={@query}
              placeholder="Name a bot, or create one"
              autocomplete="off"
            />
            <button :if={@recipients != []}>Start chat</button>
          </form>
          <div id="bot-choices" class="bot-choices">
            <button type="button" phx-click="create-form">＋ Create new Bot{if @query != "",
              do: " named “#{@query}”"}</button>
            <button type="button" phx-click={JS.focus(to: "#bot-to")}>Create group chat · choose several bots</button>
            <button
              :for={{bot, index} <- Enum.with_index(filtered(@doc, @query, @recipients), 1)}
              type="button"
              data-recipient={bot["id"]}
              phx-click="choose"
              phx-value-bot={bot["id"]}
            ><.face bot={bot} />{bot["name"]}<kbd>⌘{index}</kbd></button>
          </div>
          <form :if={@creating} id="create-bot" phx-submit="create" class="bot-create">
            <h2>Meet your new bot</h2>
            <label>Name<input name="name" value={@query} maxlength="80" required /></label>
            <label>Personality<textarea
              name="description"
              maxlength="500"
              placeholder="A calm travel companion"
            /></label>
            <details>
              <summary>Model configuration</summary>
              <label>Model<input
                name="model"
                value={Application.get_env(:nano, :bot_model, "openai-codex/gpt-6.1-sol")}
              /></label>
              <label>Reasoning<input name="reasoning" value="low" /></label>
              <label>Context limit<input name="context" type="number" value="64000" min="8192" /></label>
            </details>
            <button>Create bot</button>
          </form>
          <p class="bot-empty">A familiar face. A fresh conversation. Choose a bot to begin.</p>
        </section>
        <div :if={@chat} class="bots-pill">
          <.face :for={id <- @chat["bots"]} bot={@doc["bots"][id]} />{@chat["title"]}
        </div>
        <ol :if={@chat} class="bot-messages" id="bot-thread">
          <li
            :for={m <- @chat["messages"]}
            id={"message-" <> m["id"]}
            class={["bot-message", m["speaker"] == "human" && "human"]}
          >
            <span class="bot-speaker">{title(@doc, m["speaker"])}</span>
            <div class="bot-bubble">
              {ChatMarkup.render(m["text"])}
              <img
                :for={f <- m["files"]}
                :if={f["image"]}
                src={"/api/images/" <> f["image"]["id"]}
                alt={f["name"]}
                style="max-width:300px;max-height:240px"
              />
              <div :if={m["files"] != []} class="bot-files">
                <a :for={f <- m["files"]} href={"/bots/files/" <> f["id"]} download={f["name"]}>↓ {f[
                  "name"
                ]}</a>
              </div>
              <form
                :if={m["request_id"] && @doc["requests"][m["request_id"]]["state"] == "open"}
                phx-submit="answer"
                class="bot-request"
              >
                <input type="hidden" name="request" value={m["request_id"]} /><input
                  name="answer"
                  placeholder="Your answer"
                  required
                  maxlength="4000"
                /><button>Answer request</button>
              </form>
              <small :if={m["request_id"]}>Requested by {@doc["requests"][m["request_id"]][
                "requester"
              ]} · Request {@doc["requests"][m["request_id"]]["state"]}</small>
            </div>
            <time>{String.slice(m["at"], 11, 5)}</time>
          </li>
        </ol>
        <div :if={@chat} class="bot-typing" aria-live="polite">
          <span :for={{id, status} <- @chat["status"]} :if={status != "idle"}>{title(@doc, id)} · {status}</span>
        </div>
        <form :if={@chat} id="bot-compose" class="bot-composer" phx-change="draft" phx-submit="send">
          <label aria-label="Add attachments">＋<.live_file_input upload={@uploads.files} /></label>
          <textarea name="text" maxlength="12000" required placeholder={"Message " <> @chat["title"]}>{@draft}</textarea>
          <button
            type="button"
            disabled
            title="Voice input is coming later"
            aria-label="Voice input coming later"
          >♩</button><button>Send ↑</button>
        </form>
        <div :if={@chat} class="bot-files">
          <span :for={entry <- @uploads.files.entries}>{entry.client_name} · {entry.progress}%</span>
        </div>
      </main>
    </div>
    """
  end
end

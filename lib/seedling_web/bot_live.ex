defmodule SeedlingWeb.BotLive do
  @moduledoc """
  Consumer messaging surface at /bots: bot identities, recipient chips, group sessions,
  safe chat, progress, attachments, human requests and bounded browser interruptions.
  Shares endpoint/PubSub with the operator surface, not its harness traffic. Voice
  input is explicitly a future feature. This remains a local single-person product;
  like the node's operator API it is not authenticated for public Internet exposure.
  """
  use Phoenix.LiveView
  import SeedlingWeb.BotComponents
  alias Seedling.Bots

  def mount(_, _, socket) do
    if connected?(socket), do: Bots.subscribe()

    socket =
      socket
      |> assign(
        page_title: "Bots",
        sid: nil,
        selected: [],
        query: "",
        search: "",
        create: false,
        settings: false,
        group: false,
        draft: "",
        earlier: nil,
        files: %{},
        error: nil
      )
      |> allow_upload(:files, accept: :any, max_entries: 5, max_file_size: 10_000_000)
      |> load()

    {:ok, socket}
  end

  def handle_params(params, _, socket) do
    {:noreply, socket |> assign(sid: params["session"], earlier: nil) |> load()}
  end

  def handle_info({:bots, event}, socket) do
    socket = load(socket)
    result = event[:result]

    socket =
      if is_map(result) and result["notify"] do
        push_event(socket, "bot-notify", %{
          id: result["id"],
          title: result["name"] || "A bot needs you",
          body: String.slice(result["text"] || result["question"] || "New message", 0, 180),
          session: result["session"] || socket.assigns.sid
        })
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("new", _, socket),
    do:
      {:noreply,
       socket
       |> assign(selected: [], query: "", create: false, group: false)
       |> push_patch(to: "/bots?new=1")}

  def handle_event("search", %{"value" => value}, socket),
    do: {:noreply, assign(socket, search: value)}

  def handle_event("query", %{"query" => q}, socket), do: {:noreply, assign(socket, query: q)}

  def handle_event("draft", %{"text" => text}, socket),
    do: {:noreply, assign(socket, draft: text)}

  def handle_event("select", %{"bot" => id}, socket) do
    ids = socket.assigns.selected

    if Enum.any?(socket.assigns.bots, &(&1["id"] == id)) and length(ids) < 8,
      do: {:noreply, assign(socket, selected: Enum.uniq(ids ++ [id]), query: "", create: false)},
      else: {:noreply, assign(socket, error: "Choose at most eight bots.")}
  end

  def handle_event("remove", %{"bot" => id}, socket),
    do: {:noreply, assign(socket, selected: List.delete(socket.assigns.selected, id))}

  def handle_event("create", _, socket), do: {:noreply, assign(socket, create: true)}
  def handle_event("group", _, socket), do: {:noreply, assign(socket, group: true)}

  def handle_event("create-bot", params, socket) do
    case Bots.create_bot(params["name"],
           description: params["description"],
           voice: params["voice"]
         ) do
      {:ok, bot} ->
        {:noreply,
         socket
         |> assign(
           selected: Enum.take(socket.assigns.selected ++ [bot["id"]], 8),
           create: false,
           query: "",
           error: nil
         )
         |> load()}

      {:error, e} ->
        {:noreply, assign(socket, error: e)}
    end
  end

  def handle_event("main-chat", %{"bot" => id}, socket), do: begin_chat(socket, [id])
  def handle_event("begin", _, socket), do: begin_chat(socket, socket.assigns.selected)

  def handle_event("send", %{"text" => text}, socket) do
    if String.trim(text) == "" do
      {:noreply, assign(socket, error: "Write a message to send with your attachments.")}
    else
      with {:ok, sid} <- ensure_session(socket),
           {:ok, attachments} <- uploaded(socket),
           {:ok, _} <- Bots.say(sid, text, attachments: attachments) do
        {:noreply, socket |> assign(draft: "", error: nil) |> push_patch(to: href(sid)) |> load()}
      else
        {:error, e} -> {:noreply, assign(socket, error: e)}
      end
    end
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :files, ref)}

  def handle_event("stop", _, socket), do: result(socket, Bots.stop(socket.assigns.sid))

  def handle_event("answer", %{"request" => id, "answer" => answer}, socket),
    do: result(socket, Bots.answer(id, answer))

  def handle_event("cancel-request", %{"request" => id}, socket),
    do: result(socket, Bots.cancel_request(id))

  def handle_event("settings", _, socket),
    do: {:noreply, assign(socket, settings: not socket.assigns.settings)}

  def handle_event("configure", params, socket) do
    with {:ok, values} <- numbers(params, ~w(max_context max_turns max_tokens exchange_ceiling)) do
      config = Map.merge(values, Map.take(params, ~w(model reasoning)))
      result(socket, Bots.configure(config))
    else
      {:error, e} -> {:noreply, assign(socket, error: e)}
    end
  end

  def handle_event("notifications", params, socket) do
    with {:ok, values} <- numbers(params, ~w(per_hour cooldown_seconds)) do
      result(
        socket,
        Bots.notification_limits(
          socket.assigns.sid,
          Map.put(values, "enabled", params["enabled"] == "true")
        )
      )
    else
      {:error, e} -> {:noreply, assign(socket, error: e)}
    end
  end

  def handle_event("earlier", _, socket) do
    before = (List.first(socket.assigns.messages) || %{})["id"]

    case Bots.history(socket.assigns.sid, before: before) do
      {:ok, page} ->
        {:noreply,
         assign(socket,
           messages: page.messages,
           earlier: page.before,
           has_earlier: page.truncated
         )}

      {:error, e} ->
        {:noreply, assign(socket, error: e)}
    end
  end

  def handle_event("latest", _, socket), do: {:noreply, socket |> assign(earlier: nil) |> load()}

  defp begin_chat(socket, ids) do
    case Bots.create_session(ids) do
      {:ok, s} -> {:noreply, socket |> assign(error: nil) |> push_patch(to: href(s["id"]))}
      {:error, e} -> {:noreply, assign(socket, error: e)}
    end
  end

  defp ensure_session(%{assigns: %{sid: sid}}) when is_binary(sid), do: {:ok, sid}

  defp ensure_session(socket) do
    case Bots.create_session(socket.assigns.selected) do
      {:ok, s} -> {:ok, s["id"]}
      error -> error
    end
  end

  defp uploaded(socket) do
    if Enum.any?(socket.assigns.uploads.files.entries, &(not &1.done?)) do
      {:error, "Wait for files to finish uploading."}
    else
      results =
        consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
          {:ok, Bots.attach(path, entry.client_name)}
        end)

      case Enum.find(results, &match?({:error, _}, &1)) do
        {:error, e} -> {:error, e}
        nil -> {:ok, Enum.map(results, fn {:ok, item} -> item["id"] end)}
      end
    end
  end

  defp numbers(params, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn k, {:ok, acc} ->
      case Integer.parse(params[k] || "") do
        {n, ""} -> {:cont, {:ok, Map.put(acc, k, n)}}
        _ -> {:halt, {:error, "#{k} must be a whole number."}}
      end
    end)
  end

  defp result(socket, {:ok, _}), do: {:noreply, socket |> assign(error: nil) |> load()}
  defp result(socket, {:error, e}), do: {:noreply, assign(socket, error: e)}

  defp load(socket) do
    {:ok, snapshot} = Bots.snapshot()
    session = Enum.find(snapshot.sessions, &(&1["id"] == socket.assigns.sid))

    page =
      if session,
        do: elem(Bots.history(session["id"]), 1),
        else: %{messages: [], truncated: false}

    messages = if socket.assigns.earlier, do: socket.assigns.messages, else: page.messages

    files =
      messages
      |> Enum.flat_map(& &1["attachments"])
      |> Enum.uniq()
      |> Map.new(fn id ->
        case Bots.attachment(id) do
          {:ok, file} -> {id, Map.drop(file, ["path"])}
          _ -> {id, %{"name" => "Unavailable file"}}
        end
      end)

    assign(socket,
      bots: Enum.sort_by(snapshot.bots, & &1["created_at"]),
      sessions: snapshot.sessions,
      requests: snapshot.requests,
      statuses: snapshot.statuses,
      config: snapshot.config,
      session: session,
      messages: messages,
      has_earlier: page.truncated,
      files: files
    )
  end

  defp bot(bots, id), do: Enum.find(bots, &(&1["id"] == id))
  defp href(id), do: "/bots?" <> URI.encode_query(session: id)

  defp filtered(bots, query),
    do: Enum.filter(bots, &String.contains?(String.downcase(&1["name"]), String.downcase(query)))

  defp request(requests, id), do: Enum.find(requests, &(&1["id"] == id))
  defp stamp(at), do: at |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M")
  defp placeholder(bots, ids), do: "Message " <> Enum.map_join(ids, ", ", &bot(bots, &1)["name"])

  def render(assigns) do
    ~H"""
    <main
      class={["bots-app", (@sid || @selected != [] || @create || @query != "") && "open"]}
      id="bots-app"
    >
      <aside class="bot-sidebar">
        <div class="sidebar-actions">
          <h1>Bots</h1><button
            aria-label="Search chats"
            phx-click={Phoenix.LiveView.JS.focus(to: "#chat-search")}
          >⌕</button><button id="new-chat" aria-label="New chat" phx-click="new">＋</button>
        </div>
        <input
          id="chat-search"
          type="search"
          placeholder="Search chats"
          value={@search}
          phx-keyup="search"
          phx-debounce="120"
          aria-label="Search chats"
        />
        <button
          :if={@bots != []}
          class="main-bot"
          phx-click="main-chat"
          phx-value-bot={hd(@bots)["id"]}
        ><.face bot={hd(@bots)} /><span>{hd(@bots)["name"]}<small class="muted" style="display:block">Your main bot</small></span></button>
        <p :if={@bots == []} class="muted">Create your first bot to get started.</p>
        <nav aria-label="Chats">
          <.link
            :for={
              s <-
                Enum.filter(
                  @sessions,
                  &String.contains?(
                    String.downcase(&1["title"] <> " " <> &1["preview"]),
                    String.downcase(@search)
                  )
                )
            }
            patch={href(s["id"])}
            class={["thread-row", @sid == s["id"] && "current"]}
            aria-current={if(@sid == s["id"], do: "page", else: nil)}
          >
            <div class="faces">
              <.face
                :for={id <- Enum.take(s["bots"], 3)}
                bot={bot(@bots, id)}
                small={length(s["bots"]) > 1}
              /><span :if={length(s["bots"]) > 1} class="human-face">You</span>
            </div><div class="thread-copy">
              <strong>{s["title"]}</strong><small>{String.slice(s["preview"], 0, 70)}</small>
            </div>
          </.link>
        </nav>
        <div class="sidebar-bottom">
          <span class="human-face">You</span><span>You</span><button
            id="bot-settings"
            phx-click="settings"
            aria-label="Bot settings"
          >⚙</button><.link navigate="/" title="Operator dashboard">Operator</.link>
        </div>
      </aside>
      <section class="bot-pane">
        <div :if={@error} class="alert" role="alert">{@error}</div>
        <div :if={@settings} class="panel" id="settings-panel">
          <h2>Bot model settings</h2><p class="muted">
            Choose a connected model and set spending limits. Provider credentials stay in operator settings, never in chat.
          </p>
          <form id="configure-bots" phx-submit="configure">
            <label>Model slug<input
              name="model"
              value={@config["model"]}
              placeholder="Provider/model"
              required
            /></label>
            <label>Reasoning<input
              name="reasoning"
              value={@config["reasoning"]}
              placeholder="Supported level"
              required
            /></label>
            <label>Context tokens<input
              name="max_context"
              type="number"
              min="8192"
              value={@config["max_context"] || 64000}
              required
            /></label>
            <label>Turn ceiling<input
              name="max_turns"
              type="number"
              min="1"
              value={@config["max_turns"] || 1000}
              required
            /></label>
            <label>Token ceiling<input
              name="max_tokens"
              type="number"
              min="1"
              value={@config["max_tokens"] || 1_000_000}
              required
            /></label>
            <label>Bot exchange ceiling<input
              name="exchange_ceiling"
              type="number"
              min="1"
              max="50"
              value={@config["exchange_ceiling"] || 8}
              required
            /></label>
            <button type="submit">Save settings</button>
          </form>
        </div>
        <div :if={!@session} class="compose-to" id="recipients" phx-hook="BotRecipients">
          <div class="to-line">
            <.link class="mobile-back" patch="/bots">← Chats</.link><strong>To:</strong>
            <span :for={id <- @selected} class="chip"><.face bot={bot(@bots, id)} small />{bot(
              @bots,
              id
            )["name"]}<button
              phx-click="remove"
              phx-value-bot={id}
              aria-label={"Remove #{bot(@bots,id)["name"]}"}
            >×</button></span>
            <form id="recipient-form" phx-change="query" phx-submit="create">
              <input
                id="recipient-query"
                name="query"
                value={@query}
                placeholder="Bot name"
                autocomplete="off"
                aria-label="Choose recipients"
              />
            </form>
          </div>
          <div id="recipient-menu" class="recipient-menu" role="listbox" aria-label="Choose a bot">
            <button phx-click="create">＋ Create new Bot {if(@query != "", do: "“#{@query}”", else: "")}</button><button phx-click="group">Create group chat</button>
            <button
              :for={{b, index} <- Enum.with_index(filtered(@bots, @query))}
              :if={b["id"] not in @selected}
              phx-click="select"
              phx-value-bot={b["id"]}
              data-recipient={b["id"]}
              role="option"
              aria-selected="false"
            ><.face bot={b} />{b["name"]}<kbd>⌘{index + 1}</kbd></button>
          </div>
          <p :if={@group} class="muted">
            Choose two or more bots. Everyone shares this conversation and speaks as themselves.
          </p>
          <div :if={@create} class="panel">
            <h2>Create a bot</h2><form id="create-bot" phx-submit="create-bot">
              <label>Name<input name="name" value={@query} maxlength="80" required autofocus /></label><label>Self-description<input
                name="description"
                placeholder="A thoughtful helper"
                maxlength="500"
              /></label><label>Voice<input name="voice" placeholder="Warm and clear" maxlength="500" /></label><button type="submit">Create Bot</button>
            </form>
          </div>
          <button :if={@selected != []} id="start-chat" phx-click="begin">Start {if(
            length(@selected) > 1,
            do: "group ",
            else: ""
          )}chat</button>
          <div :if={@selected == [] && !@create} class="empty-chat">
            <h2>Who shall we talk to?</h2><p>Choose a bot, or create someone new.</p>
          </div>
        </div>
        <header :if={@session} class="chat-header">
          <.link class="mobile-back" patch="/bots">← Chats</.link><div class="participant-pill">
            <.face :for={id <- @session["bots"]} bot={bot(@bots, id)} small /><span>{@session["title"]}</span>
          </div><button id="stop-chat" phx-click="stop" title="Stop bot exchanges">Stop</button>
        </header>
        <div
          class="messages"
          id="chat-messages"
          phx-hook="BotChat"
          role="log"
          aria-label="Conversation"
          aria-live="polite"
        >
          <button :if={@has_earlier} phx-click="earlier">Earlier messages</button><button
            :if={@earlier}
            phx-click="latest"
          >Back to latest</button>
          <article
            :for={m <- @messages}
            id={"message-#{m["id"]}"}
            class={["chat-message", m["from"] in ["human", "system"] && m["from"]]}
          >
            <.face :if={m["from"] not in ["human", "system"]} bot={bot(@bots, m["from"])} />
            <div class="message-body">
              <small>{m["name"]} · {stamp(m["at"])}</small><div class="bubble">
                <div :if={m["request"]} class="request-label">A human answer is needed</div>
                {markdown(m["text"])}
                <a
                  :for={id <- m["attachments"]}
                  class="attachment"
                  href={"/bots/files/#{id}"}
                  download
                >↓ {@files[id]["name"]}</a>
                <%= if r=request(@requests,m["request"]) do %>
                  <form
                    :if={r["state"] == "pending"}
                    id={"answer-#{r["id"]}"}
                    class="reply-form"
                    phx-submit="answer"
                  >
                    <input type="hidden" name="request" value={r["id"]} /><input
                      name="answer"
                      placeholder="Your answer"
                      maxlength="4000"
                      required
                      aria-label="Answer request"
                    /><button type="submit">Answer</button><button
                      type="button"
                      phx-click="cancel-request"
                      phx-value-request={r["id"]}
                    >Dismiss</button>
                  </form>
                  <p :if={r["state"] != "pending"} class="muted">Request {r["state"]}</p>
                <% end %>
              </div>
            </div>
          </article>
        </div>
        <div :if={@session || @selected != []} class="composer-area">
          <div class="thinking" role="status">
            <span
              :for={id <- if @session, do: @session["bots"], else: []}
              :if={@statuses[{@sid, id}] not in [nil, "quiet"]}
            >{bot(@bots, id)["name"]}: {@statuses[{@sid, id}]} · </span>
          </div>
          <form id="chat-composer" phx-submit="send" phx-change="draft">
            <div class="composer">
              <label
                title="Attach files"
                aria-label="Attach files"
                for={@uploads.files.ref}
                style="padding:10px;cursor:pointer"
              >＋</label><.live_file_input
                upload={@uploads.files}
                style="position:absolute;width:1px;height:1px;opacity:0"
              /><textarea
                name="text"
                placeholder={placeholder(@bots, if(@session, do: @session["bots"], else: @selected))}
                maxlength="8000"
                aria-label="Message"
              >{@draft}</textarea><button
                type="button"
                disabled
                title="Voice input is coming later"
                aria-label="Voice input coming later"
              >♩</button><button id="send-message" type="submit" aria-label="Send message">↑</button>
            </div>
            <div :for={entry <- @uploads.files.entries} class="muted">
              {entry.client_name} · {entry.progress}%<button
                type="button"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                aria-label="Remove attachment"
              >×</button><span :for={e <- upload_errors(@uploads.files, entry)}>{upload_error(e)}</span>
            </div>
            <p :for={e <- upload_errors(@uploads.files)} class="alert">{upload_error(e)}</p>
          </form>
          <div :if={@session} class="notification-controls">
            <button id="allow-notifications" type="button">Allow browser notifications</button><span id="notification-permission">Permission is your choice</span>
            <form id="notification-limits" phx-submit="notifications">
              <label><input
                name="enabled"
                type="checkbox"
                value="true"
                checked={@session["notifications"]["enabled"]}
              /> Interruptions</label><label>Max/hour
              <input
                type="number"
                name="per_hour"
                min="0"
                max="30"
                value={@session["notifications"]["per_hour"]}
              /></label><label>Quiet seconds
              <input
                type="number"
                name="cooldown_seconds"
                min="0"
                max="86400"
                value={@session["notifications"]["cooldown_seconds"]}
              /></label><button>Save limits</button>
            </form>
          </div>
        </div>
      </section>
    </main>
    """
  end

  defp upload_error(:too_large), do: "File exceeds 10 MB."
  defp upload_error(:too_many_files), do: "Choose at most five attachments."
  defp upload_error(_), do: "Upload could not be accepted."
end

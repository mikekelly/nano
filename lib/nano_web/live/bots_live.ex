defmodule NanoWeb.BotsLive do
  @moduledoc "Consumer messaging surface. All mutations go through the durable Bots service."
  use Phoenix.LiveView
  import NanoWeb.BotsComponents

  def mount(_params, _session, socket) do
    opts =
      case Application.get_env(:nano, :bots_server) do
        nil -> []
        server -> [server: server]
      end

    if connected?(socket), do: Vega.Bots.subscribe(opts)

    socket =
      socket
      |> assign(
        page_title: "Bots",
        opts: opts,
        bots: [],
        sessions: [],
        requests: [],
        requests_truncated: false,
        request_count: 0,
        settings: %{},
        selected: nil,
        current_chat: nil,
        history_loaded: false,
        history_new: false,
        pane: "list",
        creating: false,
        bot_form: false,
        recipients: [],
        query: "",
        search: "",
        draft: "",
        drafts: %{},
        pending_images: [],
        image_drafts: %{},
        upload_notice: nil,
        error: nil,
        recipient_open: true,
        settings_open: false,
        bot_name: ""
      )
      |> allow_upload(:images,
        accept: ~w(.png .jpg .jpeg .webp .gif),
        max_entries: 4,
        max_file_size: 3_750_000
      )

    socket = refresh(socket)
    {:ok, if(socket.assigns.bots == [], do: assign(socket, pane: "chat"), else: socket)}
  end

  defp refresh(socket) do
    case Vega.Bots.snapshot(socket.assigns.opts) do
      {:ok, data} ->
        socket =
          assign(socket,
            bots: data["bots"] || [],
            sessions: Enum.sort_by(data["sessions"] || [], & &1["updated_at"], :desc),
            requests: data["requests"] || [],
            requests_truncated: data["requests_truncated"] == true,
            request_count: data["request_count"] || length(data["requests"] || []),
            settings: data["settings"] || %{}
          )

        load_chat(socket)

      {:error, _} ->
        assign(socket, error: "Could not load your chats. Please retry.")
    end
  end

  defp load_chat(socket, reset \\ false) do
    id = socket.assigns.selected

    if is_nil(id) do
      assign(socket, current_chat: nil, history_loaded: false)
    else
      case Vega.Bots.get_session(id, socket.assigns.opts) do
        {:ok, chat} ->
          old = socket.assigns.current_chat

          if not reset and socket.assigns.history_loaded and not is_nil(old) and old["id"] == id do
            # Readers own the loaded window: background updates must not replace or evict it.
            history = old["history"] || %{}

            new_activity =
              socket.assigns.history_new or
                (chat["history"] || %{})["total"] > (history["total"] || 0)

            assign(socket,
              current_chat:
                Map.merge(chat, %{"messages" => old["messages"] || [], "history" => history}),
              history_new: new_activity
            )
          else
            assign(socket, current_chat: chat, history_loaded: false, history_new: false)
          end

        {:error, _} ->
          assign(socket, error: "Could not load this conversation. Please retry.")
      end
    end
  end

  def handle_info({:vega_bots, event}, socket) do
    socket = refresh(socket)
    session = Enum.find(socket.assigns.sessions, &(&1["id"] == event["session_id"]))

    message =
      if session,
        do: Enum.find(session["messages"] || [], &(&1["id"] == event["message_id"])),
        else: nil

    request = Enum.find(socket.assigns.requests, &(&1["id"] == event["request_id"]))

    text =
      cond do
        request -> request["question"]
        message -> message["text"]
        true -> "A bot has an update for you."
      end

    {:noreply,
     push_event(socket, "bots-notification", %{
       event: event,
       settings: socket.assigns.settings,
       session_title: (session && session["title"]) || "Bots",
       text: text
     })}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("reading-history", %{"reading" => true}, socket),
    do: {:noreply, assign(socket, history_loaded: true)}

  def handle_event("reading-history", %{"reading" => false}, socket) do
    if socket.assigns.history_loaded do
      {:noreply, socket |> load_chat(true) |> push_event("bots-show-latest", %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reading-history", _, socket), do: {:noreply, socket}

  def handle_event("load-earlier", _, socket) do
    chat = socket.assigns.current_chat

    if chat && (chat["history"] || %{})["has_more"] == true do
      cursor = (chat["history"] || %{})["next_before"]

      case Vega.Bots.get_session(
             socket.assigns.selected,
             socket.assigns.opts ++ [before: cursor, limit: 80]
           ) do
        {:ok, page} ->
          messages =
            Enum.uniq_by((page["messages"] || []) ++ (chat["messages"] || []), & &1["id"])

          {:noreply,
           socket
           |> assign(
             current_chat:
               Map.merge(chat, %{
                 "messages" => Enum.take(messages, 400),
                 "history" => page["history"] || %{}
               }),
             history_loaded: true
           )
           |> push_event("bots-history-prepended", %{})}

        {:error, _} ->
          {:noreply, assign(socket, error: "Could not load earlier messages. Please retry.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("latest-messages", _, socket),
    do: {:noreply, socket |> load_chat(true) |> push_event("bots-show-latest", %{})}

  def handle_event("retry", _, socket), do: {:noreply, refresh(assign(socket, error: nil))}

  def handle_event("search", %{"search" => value}, socket),
    do: {:noreply, assign(socket, search: value)}

  def handle_event("new-chat", _, socket),
    do:
      {:noreply,
       socket
       |> save_draft()
       |> assign(
         creating: true,
         pane: "chat",
         recipients: [],
         query: "",
         bot_form: false,
         error: nil
       )}

  def handle_event("back", _, socket),
    do: {:noreply, socket |> save_draft() |> assign(pane: "list")}

  def handle_event("open-session", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.sessions, &(&1["id"] == id)) do
      socket = save_draft(socket)

      {:noreply,
       socket
       |> assign(
         selected: id,
         creating: false,
         pane: "chat",
         draft: Map.get(socket.assigns.drafts, id, ""),
         pending_images: Map.get(socket.assigns.image_drafts, id, []),
         error: nil
       )
       |> load_chat(true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("recipient-query", %{"query" => value}, socket),
    do: {:noreply, assign(socket, query: value, recipient_open: true)}

  def handle_event("close-recipients", _, socket),
    do: {:noreply, assign(socket, recipient_open: false)}

  def handle_event("add-recipient", %{"id" => id}, socket) do
    ids = socket.assigns.recipients

    ids =
      if Enum.any?(socket.assigns.bots, &(&1["id"] == id)), do: Enum.uniq(ids ++ [id]), else: ids

    {:noreply, assign(socket, recipients: ids, query: "", recipient_open: true)}
  end

  def handle_event("remove-recipient", %{"id" => id}, socket),
    do: {:noreply, assign(socket, recipients: List.delete(socket.assigns.recipients, id))}

  def handle_event("main-bot", _, socket) do
    case List.first(socket.assigns.bots) do
      nil ->
        {:noreply, socket}

      bot ->
        case Enum.find(socket.assigns.sessions, &(&1["bot_ids"] == [bot["id"]])) do
          nil ->
            case Vega.Bots.create_session([bot["id"]], socket.assigns.opts) do
              {:ok, chat} ->
                {:noreply,
                 socket
                 |> save_draft()
                 |> refresh()
                 |> assign(
                   selected: chat["id"],
                   creating: false,
                   pane: "chat",
                   draft: "",
                   pending_images: [],
                   error: nil
                 )
                 |> load_chat(true)}

              {:error, _} ->
                {:noreply, assign(socket, error: "Could not start chat. Please retry.")}
            end

          chat ->
            handle_event("open-session", %{"id" => chat["id"]}, socket)
        end
    end
  end

  def handle_event("group", _, socket), do: {:noreply, assign(socket, recipient_open: true)}

  def handle_event("show-bot-form", _, socket),
    do:
      {:noreply,
       socket
       |> save_draft()
       |> assign(
         bot_form: true,
         bot_name: socket.assigns.query,
         creating: true,
         pane: "chat"
       )}

  def handle_event("cancel-bot", _, socket), do: {:noreply, assign(socket, bot_form: false)}

  def handle_event("create-bot", params, socket) do
    opts =
      socket.assigns.opts ++
        [
          description: params["description"] || "",
          voice: params["voice"] || "",
          model: params["model"] || "openai-codex/gpt-6.1-sol",
          reasoning: params["reasoning"] || "low",
          max_context: integer(params["max_context"], 272_000),
          max_turns: integer(params["max_turns"], 0),
          max_tokens: integer(params["max_tokens"], 0)
        ]

    case Vega.Bots.create_bot(params["name"] || "", opts) do
      {:ok, bot} ->
        {:noreply,
         socket
         |> refresh()
         |> assign(
           bot_form: false,
           recipients: Enum.uniq(socket.assigns.recipients ++ [bot["id"]]),
           query: "",
           error: nil
         )}

      {:error, _} ->
        {:noreply,
         assign(socket,
           error: "Could not create this bot. Check the name and settings, then try again.",
           bot_name: params["name"] || ""
         )}
    end
  end

  def handle_event("start-chat", _, socket) do
    case Vega.Bots.create_session(socket.assigns.recipients, socket.assigns.opts) do
      {:ok, session} ->
        {:noreply,
         socket
         |> save_draft()
         |> refresh()
         |> assign(
           selected: session["id"],
           creating: false,
           pane: "chat",
           draft: "",
           pending_images: [],
           error: nil
         )
         |> load_chat(true)}

      {:error, _} ->
        {:noreply,
         assign(socket, error: "Could not start this chat. Choose recipients and try again.")}
    end
  end

  def handle_event("draft", %{"text" => text}, socket),
    do: {:noreply, assign(socket, draft: text)}

  def handle_event("remove-stored-image", %{"id" => id}, socket),
    do:
      {:noreply,
       assign(socket,
         pending_images: Enum.reject(socket.assigns.pending_images, &(&1["id"] == id))
       )}

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :images, ref)}

  def handle_event("send", %{"text" => text}, socket) do
    socket = assign(socket, draft: text)

    if socket.assigns.selected && Enum.all?(socket.assigns.uploads.images.entries, & &1.done?) do
      refs =
        consume_uploaded_entries(socket, :images, fn %{path: path}, _entry ->
          case Vega.Images.import_file(path) do
            {:ok, ref} -> {:ok, {:ok, ref}}
            {:error, reason} -> {:ok, {:error, reason}}
          end
        end)

      if Enum.any?(refs, &match?({:error, _}, &1)) do
        socket =
          assign(socket,
            pending_images: socket.assigns.pending_images ++ for({:ok, ref} <- refs, do: ref)
          )

        {:noreply,
         assign(socket,
           error:
             "An image could not be stored. Your text is saved; reattach the image and retry."
         )}
      else
        images = socket.assigns.pending_images ++ Enum.map(refs, fn {:ok, ref} -> ref end)
        socket = assign(socket, pending_images: images)

        case Vega.Bots.send_message(
               socket.assigns.selected,
               text,
               socket.assigns.opts ++ [images: images]
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(
               draft: "",
               pending_images: [],
               drafts: Map.delete(socket.assigns.drafts, socket.assigns.selected),
               error: nil
             )
             |> refresh()}

          {:error, _} ->
            {:noreply,
             assign(socket, error: "Message was not sent. Your draft is saved. Please try again.")}
        end
      end
    else
      {:noreply, assign(socket, error: "Wait for images to finish uploading, then send again.")}
    end
  end

  def handle_event("retry-bots", _, socket) do
    case Vega.Bots.retry(socket.assigns.selected, socket.assigns.opts) do
      {:ok, _} ->
        {:noreply, refresh(assign(socket, error: nil))}

      {:error, _} ->
        {:noreply, assign(socket, error: "Could not restart the reply. Please retry.")}
    end
  end

  def handle_event("rename", %{"title" => title}, socket) do
    case Vega.Bots.update_session(
           socket.assigns.selected,
           %{"title" => title},
           socket.assigns.opts
         ) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      {:error, _} ->
        {:noreply, assign(socket, error: "Could not rename this chat. Please try again.")}
    end
  end

  def handle_event("answer", %{"request_id" => id, "answer" => answer}, socket) do
    case Vega.Bots.answer_request(id, answer, socket.assigns.opts) do
      {:ok, _} -> {:noreply, refresh(assign(socket, error: nil))}
      {:error, _} -> {:noreply, assign(socket, error: "Answer was not saved. Please retry.")}
    end
  end

  def handle_event("toggle-settings", _, socket),
    do: {:noreply, assign(socket, settings_open: !socket.assigns.settings_open)}

  def handle_event("settings", p, socket) do
    attrs = %{
      "notifications_enabled" => p["notifications_enabled"] == "true",
      "notification_requests_only" => p["notification_requests_only"] == "true",
      "notification_preview" => p["notification_preview"] == "true",
      "notification_interval_seconds" => integer(p["notification_interval_seconds"], 60),
      "notification_max_per_hour" => integer(p["notification_max_per_hour"], 6)
    }

    case Vega.Bots.update_settings(attrs, socket.assigns.opts) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      {:error, _} ->
        {:noreply,
         assign(socket, error: "Could not save notification preferences. Please try again.")}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp save_draft(socket) do
    socket =
      assign(socket,
        drafts: Map.put(socket.assigns.drafts, socket.assigns.selected, socket.assigns.draft),
        image_drafts:
          Map.put(
            socket.assigns.image_drafts,
            socket.assigns.selected,
            socket.assigns.pending_images
          )
      )

    entries = socket.assigns.uploads.images.entries

    socket =
      Enum.reduce(entries, socket, fn entry, acc -> cancel_upload(acc, :images, entry.ref) end)

    if entries == [],
      do: socket,
      else:
        assign(socket,
          upload_notice:
            "Unsent image uploads were removed when you changed chats. Reattach them in the intended conversation."
        )
  end

  defp integer(value, default) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end

  defp bot(bots, id), do: Enum.find(bots, &(&1["id"] == id)) || %{"id" => id, "name" => "Bot"}

  defp matching(bots, query, ids),
    do: Enum.filter(bots, &(&1["id"] not in ids and contains?(&1["name"], query)))

  defp contains?(text, q),
    do: String.contains?(String.downcase(text || ""), String.downcase(q || ""))

  defp preview(s) do
    case List.last(s["messages"] || []) do
      nil -> "Start the conversation"
      m -> String.slice(m["text"] || "Image", 0, 100)
    end
  end

  defp names(bots, ids), do: Enum.map_join(ids || [], ", ", &bot(bots, &1)["name"])

  defp chats(sessions, bots, search),
    do:
      Enum.filter(
        sessions,
        &(contains?(&1["title"], search) or contains?(preview(&1), search) or
            contains?(names(bots, &1["bot_ids"]), search))
      )

  def render(assigns) do
    assigns =
      assign(assigns,
        chat: assigns.current_chat,
        available: matching(assigns.bots, assigns.query, assigns.recipients)
      )

    ~H"""
    <div class="bots-app" data-pane={@pane}>
      <aside class="sidebar" aria-label="Chats">
        <header>
          <h1>Bots</h1><button phx-click="new-chat" aria-label="New chat"><.icon kind="plus" /></button>
        </header>
        <form id="chat-search-form" phx-change="search" role="search">
          <label for="chat-search">Search chats and bots</label><input
            id="chat-search"
            name="search"
            type="search"
            value={@search}
            placeholder="Search"
          />
        </form>
        <button :if={List.first(@bots)} class="main-bot" phx-click="main-bot"><.face bot={hd(@bots)} />{hd(
          @bots
        )["name"]}</button>
        <nav class="chat-list" aria-label="Conversations">
          <button
            :for={s <- chats(@sessions, @bots, @search)}
            class={["chat-row", s["id"] == @selected && "selected"]}
            phx-click="open-session"
            phx-value-id={s["id"]}
            aria-current={s["id"] == @selected && "true"}
            aria-selected={to_string(s["id"] == @selected)}
          >
            <span class="faces"><.face :for={id <- s["bot_ids"] || []} bot={bot(@bots, id)} small /><span
              class="person-face"
              aria-label="You"
            >YO</span></span>
            <span><strong>{s["title"] || names(@bots, s["bot_ids"])}</strong><span class="preview">{preview(
              s
            )}</span></span>
            <span
              :if={Enum.any?(@requests, &(&1["session_id"] == s["id"] and &1["status"] == "pending"))}
              class="badge"
              aria-label="Needs your answer"
            >●</span>
          </button>
          <p :if={@sessions == []}>Your conversations will appear here.</p>
          <p :if={@sessions != [] and chats(@sessions, @bots, @search) == []}>No matching chats.</p>
        </nav>
        <footer>
          <span class="person-face">YO</span><span>You</span><button
            phx-click="toggle-settings"
            aria-expanded={to_string(@settings_open)}
          >Notifications</button>
        </footer>
        <section id="notification-controls" class="settings" phx-hook="BotsNotifications">
          <div :if={@settings_open}>
            <h2>Notifications</h2><p>
              Only while this tab is open in the background. Not closed-tab push.
            </p>
            <button id="enable-notifications" type="button">Enable browser notifications</button><p
              id="notification-permission"
              role="status"
            >
            </p>
            <form id="notification-settings-form" phx-change="settings">
              <label><input
                type="checkbox"
                name="notifications_enabled"
                value="true"
                checked={@settings["notifications_enabled"] == true}
              /> Allow notifications</label>
              <label><input
                type="checkbox"
                name="notification_requests_only"
                value="true"
                checked={@settings["notification_requests_only"] != false}
              /> Human requests only</label>
              <label><input
                type="checkbox"
                name="notification_preview"
                value="true"
                checked={@settings["notification_preview"] == true}
              /> Include message previews</label>
              <label>Minimum seconds apart<input
                name="notification_interval_seconds"
                type="number"
                min="10"
                max="86400"
                value={@settings["notification_interval_seconds"] || 60}
              /></label>
              <label>Maximum per hour<input
                name="notification_max_per_hour"
                type="number"
                min="0"
                max="60"
                value={@settings["notification_max_per_hour"] || 6}
              /></label>
            </form>
          </div>
        </section>
      </aside>
      <main class="main-pane" aria-label="Conversation">
        <button class="mobile-back" phx-click="back">← Back to chats</button>
        <div :if={@error} class="error" role="alert">
          {@error}<button phx-click="retry">Retry loading</button>
        </div>
        <p :if={@requests_truncated} class="notice" role="status">
          Showing the most recent 200 of {@request_count} human requests, with unanswered requests first. Older request cards are not shown.
        </p>
        <p :if={@upload_notice} class="notice" role="status">{@upload_notice}</p>
        <section :if={@creating or @bots == []} class="new-chat">
          <h2>{if @bots == [], do: "Create your first bot", else: "New conversation"}</h2>
          <p>A familiar face to think things through with. Choose one bot or bring a few together.</p>
          <div class="recipient-chips">
            <span>To:</span><span :for={id <- @recipients} class="chip"><.face
              bot={bot(@bots, id)}
              small
            />{bot(@bots, id)["name"]}<button
              phx-click="remove-recipient"
              phx-value-id={id}
              aria-label={"Remove #{bot(@bots,id)["name"]}"}
            >×</button></span>
          </div>
          <form id="recipient-form" phx-change="recipient-query">
            <label for="recipient-query">Choose recipients</label><input
              id="recipient-query"
              phx-hook="BotsRecipients"
              name="query"
              value={@query}
              role="combobox"
              aria-autocomplete="list"
              aria-controls="recipient-options"
              aria-expanded={to_string(@recipient_open)}
              autocomplete="off"
            />
          </form>
          <div
            :if={@recipient_open}
            id="recipient-options"
            class="popover"
            role="listbox"
            aria-label="Bots"
          >
            <button role="option" aria-selected="false" phx-click="show-bot-form">{if @query == "",
              do: "Create new Bot",
              else: "Create #{@query}"}</button>
            <button role="option" aria-selected="false" phx-click="group">Create group chat — choose two or more</button>
            <button
              :for={{b, i} <- Enum.with_index(@available, 1)}
              id={"recipient-option-#{b["id"]}"}
              role="option"
              aria-selected="false"
              phx-click="add-recipient"
              phx-value-id={b["id"]}
              data-shortcut={i}
            ><.face bot={b} small />{b["name"]}<kbd :if={i <= 9}>⌘{i}</kbd></button>
          </div>
          <p :if={length(@recipients) > 1}>Group chat · {length(@recipients)} bots</p>
          <button phx-click="start-chat" disabled={@recipients == []}>Start chat</button>
          <button :if={@bots == [] and not @bot_form} phx-click="show-bot-form">Create your first bot</button>
          <form :if={@bot_form} id="create-bot" class="bot-form" phx-submit="create-bot">
            <h3>Create a bot</h3><label>Name<input
              name="name"
              value={@bot_name}
              required
              maxlength="80"
            /></label>
            <label>Short description<textarea
              name="description"
              placeholder="What would you like this bot to help with?"
            ></textarea></label>
            <label>Voice and personality<textarea
              name="voice"
              placeholder="Warm, curious, straightforward…"
            ></textarea></label>
            <details>
              <summary>Advanced model settings</summary>
              <label>Model<input name="model" value="openai-codex/gpt-6.1-sol" /></label>
              <label>Reasoning<select name="reasoning"><option value="low">Low</option><option value="medium">
                Medium
              </option><option value="high">High</option></select></label>
              <label>Context tokens<input name="max_context" type="number" min="1" value="272000" /></label>
              <label>Turn limit (0 = unlimited)<input
                name="max_turns"
                type="number"
                min="0"
                value="0"
              /></label>
              <label>Token budget (0 = unlimited)<input
                name="max_tokens"
                type="number"
                min="0"
                value="0"
              /></label>
            </details><button type="submit">Create bot</button><button
              type="button"
              phx-click="cancel-bot"
            >Cancel</button>
          </form>
        </section>
        <section :if={not @creating and @chat} class="conversation">
          <header class="chat-header">
            <div class="participant-pill">
              <.face :for={id <- @chat["bot_ids"] || []} bot={bot(@bots, id)} small /><h2>
                {@chat["title"] || names(@bots, @chat["bot_ids"])}
              </h2>
            </div>
            <details>
              <summary>Rename topic</summary><form phx-submit="rename">
                <label>Topic<input name="title" value={@chat["title"]} required /></label><button>Save topic</button>
              </form>
            </details>
          </header>
          <div
            id="messages"
            class="messages"
            phx-hook="BotsFollow"
            data-session={@selected}
            role="log"
            aria-label="Messages"
          >
            <div class="history-controls">
              <p :if={@history_new} role="status">
                New messages have arrived. Show latest messages to read them.
              </p>
              <button
                :if={(@chat["history"] || %{})["has_more"] == true}
                type="button"
                phx-click="load-earlier"
              >Load earlier messages</button>
              <button :if={@history_loaded} type="button" phx-click="latest-messages">Show latest messages</button>
              <p :if={length(@chat["messages"] || []) >= 400} role="status">
                Showing a window of 400 messages. Load earlier to keep reading, or show latest.
              </p>
            </div>
            <p :if={(@chat["messages"] || []) == []} class="empty-state">
              Say hello to {names(@bots, @chat["bot_ids"])}.
            </p>
            <article
              :for={m <- @chat["messages"] || []}
              id={"message-#{m["id"]}"}
              class={[
                "message",
                if(m["author_id"] == "person", do: "person-message", else: "bot-message")
              ]}
            >
              <div class="message-author">
                <span :if={m["author_id"] == "person"} class="person-face">YO</span><.face
                  :if={m["author_id"] != "person"}
                  bot={bot(@bots, m["author_id"])}
                  small
                /><strong>{if m["author_id"] == "person",
                  do: "You",
                  else: bot(@bots, m["author_id"])["name"]}</strong>
              </div>
              <div class="bubble">
                <.markdown text={m["text"] || ""} /><a
                  :for={file <- m["files"] || []}
                  :if={file_url(file)}
                  href={file_url(file)}
                  class="attachment"
                  download
                >{file["filename"] || "Download file"}</a><a
                  :for={image <- m["images"] || []}
                  :if={image_url(image)}
                  href={image_url(image)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="attachment"
                ><img src={image_url(image)} alt="Attached image" loading="lazy" /></a>
              </div>
            </article>
            <section
              :for={r <- Enum.filter(@requests, &(&1["session_id"] == @selected))}
              id={"request-#{r["id"]}"}
              class="request-card"
            >
              <h3>{bot(@bots, r["bot_id"])["name"]} needs your answer</h3><.markdown text={
                r["question"] || ""
              } />
              <form :if={r["status"] == "pending" and r["kind"] != "setting"} phx-submit="answer">
                <input type="hidden" name="request_id" value={r["id"]} /><label for={"answer-#{r["id"]}"}>Your answer</label><textarea
                  id={"answer-#{r["id"]}"}
                  name="answer"
                  required
                ></textarea><button>Send answer</button>
              </form>
              <div
                :if={r["status"] == "pending" and r["kind"] == "setting"}
                id={"setting-request-#{r["id"]}"}
                phx-hook="BotsSetting"
                phx-update="ignore"
                data-endpoint={"/bots/requests/#{r["id"]}/setting"}
                class="setting-request"
              >
                <p>
                  Save {r["setting_key"]} securely. Don’t paste credentials into the general chat.
                </p>
                <label for={"credential-#{r["id"]}"}>Credential {r["setting_key"]}</label>
                <input
                  id={"credential-#{r["id"]}"}
                  type="password"
                  name="password"
                  autocomplete="new-password"
                  spellcheck="false"
                  autocapitalize="none"
                />
                <button type="button" data-save-setting>Save credential</button>
                <p data-setting-status role="status" aria-live="polite"></p>
              </div>
              <p :if={r["status"] != "pending" and r["kind"] == "setting"}>
                Credential {r["setting_key"]} saved.
              </p>
              <p :if={r["status"] != "pending" and r["kind"] != "setting"}>
                Answered: {if is_binary(r["answer"]), do: r["answer"], else: "Answer saved."}
              </p>
            </section>
            <div class="statuses" role="status" aria-live="polite">
              <p :for={{id, status} <- @chat["statuses"] || %{}} :if={status["state"] != "idle"}>
                {bot(@bots, id)["name"]}: {if status["state"] == "thinking",
                  do: "Thinking…",
                  else: "Unable to continue. Check your provider settings and send again."}
              </p><button
                :if={Enum.any?(@chat["statuses"] || %{}, fn {_, s} -> s["state"] == "error" end)}
                phx-click="retry-bots"
              >Retry reply</button>
            </div>
          </div>
          <button id="jump-latest" type="button" hidden>Jump to latest ↓</button>
          <form id="composer" class="composer" phx-change="draft" phx-submit="send">
            <label for="message-text" class="sr-only">Message {names(@bots, @chat["bot_ids"])}</label><textarea
              id="message-text"
              phx-hook="BotsComposer"
              name="text"
              value={@draft}
              placeholder={"Message #{names(@bots,@chat["bot_ids"])}"}
            >{@draft}</textarea>
            <label class="attach-button"><.icon kind="plus" /><span class="sr-only">Attach images</span><.live_file_input upload={
              @uploads.images
            } /></label>
            <button
              type="button"
              disabled
              aria-label="Voice input coming later"
              title="Voice input coming later"
            ><.icon kind="microphone" /><span class="sr-only">Voice input coming later</span></button><button
              type="submit"
              phx-disable-with="Sending…"
            >Send</button>
            <div :for={entry <- @uploads.images.entries} class="attachment">
              <.live_img_preview entry={entry} /><span>{entry.client_name} · {entry.progress}%</span><button
                type="button"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                aria-label={"Remove #{entry.client_name}"}
              >×</button><p :for={err <- upload_errors(@uploads.images, entry)} role="alert">
                {upload_error(err)}
              </p>
            </div>
            <div :for={image <- @pending_images} class="attachment">
              <img :if={image_url(image)} src={image_url(image)} alt="Image ready to resend" />
              <span>Image ready to resend</span><button
                type="button"
                phx-click="remove-stored-image"
                phx-value-id={image["id"]}
                aria-label="Remove stored image"
              >×</button>
            </div>
            <p :for={err <- upload_errors(@uploads.images)} role="alert">{upload_error(err)}</p>
          </form>
        </section>
        <section :if={not @creating and is_nil(@chat) and @bots != []} class="empty-state">
          <h2>A little space to think</h2><p>Choose a conversation or start a new one.</p><button phx-click="new-chat">New chat</button>
        </section>
      </main>
    </div>
    """
  end

  defp file_url(%{"type" => "file_ref", "id" => id}) when is_binary(id) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, id), do: "/bots/files/" <> id, else: nil
  end

  defp file_url(_), do: nil

  defp image_url(%{"type" => "image_ref", "id" => id}) when is_binary(id) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, id), do: "/api/images/" <> id, else: nil
  end

  defp image_url(_), do: nil
  defp upload_error(:too_large), do: "This image is too large (maximum 3.75 MB)."
  defp upload_error(:too_many_files), do: "Attach up to four images at a time."
  defp upload_error(:not_accepted), do: "Choose a PNG, JPEG, WebP or GIF image."
  defp upload_error(_), do: "Upload failed. Remove the image and try again."
end

defmodule NanoWeb.BotsLive do
  @moduledoc """
  Consumer chat at `/bots` and `/bots/:id`, using only the `Bots` facade's product
  events, never logs. Assets: bots.css and bots.js (window.BotsHooks.BotsShell).
  Tests can set a PID string in the trusted signed session's bots_server key;
  request parameters never choose a backend. BotsMarkdown escapes raw HTML.

  Image attachments use Images.ingest/1 (four files per batch, 3.75 MB each),
  with canonical references sent to Bots.say/3 and fixed /api/images/:id links.
  Replies to human requests are text-only. Failed sends retain drafts and images.
  Initially renders the latest 100 messages; earlier history loads on demand.
  Browser notifications require explicit permission, saved opt-in preferences,
  a background tab and backend plus client limits. They require an open page;
  no service worker or push service is registered. Voice input is unavailable.
  """
  use Phoenix.LiveView
  import Phoenix.Component
  alias NanoWeb.BotsMarkdown
  alias NanoWeb.BotsBackend, as: Bots

  @impl true
  def mount(_params, session, socket) do
    opts =
      case session["bots_server"] do
        pid when is_binary(pid) -> trusted_server(pid)
        _ -> []
      end

    {:ok,
     socket
     |> assign(
       page_title: "Bots",
       opts: opts,
       available: false,
       subscribed: false,
       bots: [],
       sessions: [],
       preferences: %{"notifications" => false, "cooldown_seconds" => 300, "max_per_hour" => 6},
       active: nil,
       active_id: nil,
       selected: [],
       query: "",
       search: "",
       draft: "",
       error: nil,
       create_open: false,
       new_name: "",
       preferences_open: false,
       reply_to: nil,
       mobile_list: false,
       permission: "unknown",
       attachments: [],
       message_limit: 100
     )
     |> refresh()
     |> allow_upload(:pictures,
       accept: ~w(.png .jpg .jpeg .gif .webp),
       max_entries: 4,
       max_file_size: 3_750_000
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns.available do
      change_chat(params, socket)
    else
      {:noreply, assign(socket, active_id: params["id"])}
    end
  catch
    :throw, :bots_service_unavailable -> {:noreply, unavailable_socket(socket)}
  end

  defp change_chat(params, socket) do
    id = params["id"]
    active = if id, do: Bots.session(id, socket.assigns.opts)

    socket =
      Enum.reduce(
        socket.assigns.uploads.pictures.entries,
        socket,
        &cancel_upload(&2, :pictures, &1.ref)
      )

    {:noreply,
     assign(socket,
       active_id: id,
       active: active,
       message_limit: 100,
       attachments: [],
       draft: "",
       reply_to: nil,
       selected: [],
       query: "",
       mobile_list: false,
       error: if(id && is_nil(active), do: "This chat is no longer available.", else: nil)
     )}
  end

  @impl true
  def handle_info({:bots_changed, _id}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:bots_notification, event}, socket) do
    if socket.assigns.preferences["notifications"] do
      {:noreply, push_event(socket, "bots:notification", event)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry-service", _, socket), do: {:noreply, refresh(socket)}
  def handle_event(_, _, %{assigns: %{available: false}} = socket), do: {:noreply, socket}

  def handle_event(name, params, socket) do
    socket =
      if name in ["send", "draft"] and is_binary(params["text"]),
        do: assign(socket, draft: String.slice(params["text"], 0, 32_000)),
        else: socket

    event(name, params, socket)
  catch
    :throw, :bots_service_unavailable -> {:noreply, unavailable_socket(socket)}
  end

  defp event("search", %{"search" => query}, socket),
    do: {:noreply, assign(socket, search: String.slice(query, 0, 200))}

  defp event("recipient-query", %{"query" => query}, socket),
    do: {:noreply, assign(socket, query: String.slice(query, 0, 80))}

  defp event("choose-bot", %{"id" => id}, socket) do
    selected =
      if Enum.any?(socket.assigns.bots, &(&1["id"] == id)),
        do: Enum.uniq(socket.assigns.selected ++ [id]),
        else: socket.assigns.selected

    {:noreply, assign(socket, selected: selected, query: "", error: nil)}
  end

  defp event("remove-bot", %{"id" => id}, socket),
    do: {:noreply, assign(socket, selected: List.delete(socket.assigns.selected, id))}

  defp event("group", _, socket),
    do:
      {:noreply,
       socket |> assign(error: nil) |> push_event("bots:focus", %{id: "recipient-input"})}

  defp event("create-open", _, socket),
    do: {:noreply, assign(socket, create_open: true, new_name: socket.assigns.query, error: nil)}

  defp event("create-close", _, socket), do: {:noreply, assign(socket, create_open: false)}

  defp event("create-bot", %{"bot" => attrs}, socket) do
    case Bots.create_bot(Map.take(attrs, ["name", "description"]), socket.assigns.opts) do
      {:ok, bot} ->
        {:noreply,
         socket
         |> refresh()
         |> assign(
           create_open: false,
           query: "",
           error: nil,
           selected: Enum.uniq(socket.assigns.selected ++ [bot["id"]])
         )}

      {:error, _} ->
        {:noreply,
         assign(socket, error: "We couldn’t create that bot. Use a short name and try again.")}
    end
  end

  defp event("start-chat", _, socket) do
    case open_session(socket) do
      {:ok, chat} -> {:noreply, push_patch(socket, to: chat_path(chat["id"]))}
      {:error, _} -> {:noreply, assign(socket, error: "Choose at least one bot to start a chat.")}
    end
  end

  defp event("main-bot", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.bots, &(&1["id"] == id)) do
      existing = Enum.find(socket.assigns.sessions, &(&1["bot_ids"] == [id]))

      result =
        if existing, do: {:ok, existing}, else: Bots.create_session([id], socket.assigns.opts)

      case result do
        {:ok, chat} -> {:noreply, push_patch(socket, to: chat_path(chat["id"]))}
        _ -> {:noreply, assign(socket, error: "We couldn’t open this chat. Please try again.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp event("draft", %{"text" => text}, socket),
    do: {:noreply, assign(socket, draft: String.slice(text, 0, 32_000))}

  defp event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, assign(socket, error: "Write a message first.")}

      String.length(text) > 32_000 or byte_size(text) > 50_000 ->
        {:noreply,
         assign(socket,
           error:
             "That message is too long. Please send it in smaller parts (up to 32,000 characters or 50 KB)."
         )}

      true ->
        prepare_send(socket, text)
    end
  end

  defp event("reply", %{"id" => id}, socket) do
    request =
      Enum.find(
        messages(socket.assigns.active),
        &(&1["kind"] == "request" and &1["request_id"] == id and &1["status"] != "answered")
      )

    if request do
      {:noreply,
       socket
       |> assign(reply_to: id, error: nil)
       |> push_event("bots:focus", %{id: "message-input"})}
    else
      {:noreply, socket}
    end
  end

  defp event("cancel-reply", _, socket), do: {:noreply, assign(socket, reply_to: nil)}

  defp event("stop", _, socket) do
    case Bots.stop(socket.assigns.active_id, socket.assigns.opts) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      _ ->
        {:noreply, assign(socket, error: "We couldn’t stop this conversation. Please try again.")}
    end
  end

  defp event("show-chats", _, socket), do: {:noreply, assign(socket, mobile_list: true)}

  defp event("preferences-open", _, socket),
    do: {:noreply, assign(socket, preferences_open: true, error: nil)}

  defp event("preferences-close", _, socket),
    do: {:noreply, assign(socket, preferences_open: false)}

  defp event("permission", %{"permission" => value}, socket)
       when value in ["granted", "denied", "default", "unsupported"],
       do: {:noreply, assign(socket, permission: value)}

  defp event("save-preferences", %{"preferences" => prefs}, socket) do
    attrs = %{
      "notifications" => prefs["notifications"] == "true",
      "cooldown_seconds" => integer(prefs["cooldown_seconds"], 300),
      "max_per_hour" => integer(prefs["max_per_hour"], 6)
    }

    case Bots.preferences(attrs, socket.assigns.opts) do
      {:ok, _} ->
        {:noreply, socket |> refresh() |> assign(preferences_open: false, error: nil)}

      _ ->
        {:noreply,
         assign(socket,
           error: "Use at least 60 seconds between alerts, and 0–60 alerts per hour."
         )}
    end
  end

  defp event("review-request", %{"id" => id}, socket) do
    entries = messages(socket.assigns.active)

    index =
      Enum.find_index(
        entries,
        &(&1["id"] == id and &1["kind"] == "request" and &1["status"] != "answered")
      )

    if index do
      {:noreply,
       socket
       |> assign(message_limit: max(socket.assigns.message_limit, length(entries) - index))
       |> push_event("bots:reveal-message", %{id: "bot-message-" <> id})}
    else
      {:noreply, socket}
    end
  end

  defp event("older-messages", _, socket),
    do: {:noreply, update(socket, :message_limit, &(&1 + 100))}

  defp event("dismiss-error", _, socket), do: {:noreply, assign(socket, error: nil)}

  defp event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :pictures, ref)}

  defp event("remove-attachment", %{"id" => id}, socket),
    do:
      {:noreply,
       assign(socket, attachments: Enum.reject(socket.assigns.attachments, &(&1["id"] == id)))}

  defp trusted_server(value) do
    [
      server:
        :erlang.list_to_pid(value |> String.replace_prefix("#PID", "") |> String.to_charlist())
    ]
  rescue
    ArgumentError -> []
  end

  defp prepare_send(socket, text) do
    {complete, pending} = uploaded_entries(socket, :pictures)

    cond do
      length(complete) + length(socket.assigns.attachments) > 10 ->
        {:noreply,
         assign(socket,
           error: "Keep at most ten images in one message. Remove an attachment and try again."
         )}

      pending != [] or upload_errors(socket.assigns.uploads.pictures) != [] or
          Enum.any?(complete, &(upload_errors(socket.assigns.uploads.pictures, &1) != [])) ->
        {:noreply,
         assign(socket,
           error: "Wait for images to finish uploading, or remove any invalid files."
         )}

      socket.assigns.reply_to && (complete != [] or socket.assigns.attachments != []) ->
        {:noreply,
         assign(socket,
           error:
             "Requests accept text replies. Remove the images, or cancel replying to send them to the chat."
         )}

      true ->
        results =
          consume_uploaded_entries(socket, :pictures, fn %{path: path}, _entry ->
            {:ok, Images.ingest(path)}
          end)

        refs = socket.assigns.attachments ++ for {:ok, ref} <- results, do: ref
        socket = assign(socket, attachments: refs, draft: text)

        if Enum.any?(results, &match?({:error, _}, &1)) do
          {:noreply,
           assign(socket,
             error:
               "An image couldn’t be read. Use a valid PNG, JPEG, GIF or WebP under 3.75 MB. Other attachments are still here."
           )}
        else
          send_message(socket, text)
        end
    end
  end

  defp image_refs(attachments) when is_list(attachments) do
    Enum.filter(attachments, fn
      %{"type" => "image_ref", "id" => id, "mime" => mime} when is_binary(id) ->
        Regex.match?(~r/\A[0-9a-f]{64}\z/, id) and
          mime in ~w(image/png image/jpeg image/gif image/webp)

      _ ->
        false
    end)
  end

  defp image_refs(_), do: []
  defp upload_error(:too_large), do: "Image is too large (maximum 3.75 MB)."
  defp upload_error(:too_many_files), do: "Choose up to four images at a time."
  defp upload_error(:not_accepted), do: "Choose PNG, JPEG, GIF or WebP images."
  defp upload_error(_), do: "Upload failed. Remove the image and try again."

  defp send_message(socket, text) do
    result =
      if socket.assigns.reply_to do
        case Bots.reply(socket.assigns.reply_to, text, socket.assigns.opts) do
          {:ok, _} -> {:ok, socket.assigns.active}
          error -> error
        end
      else
        with {:ok, chat} <- open_session(socket),
             {:ok, _} <-
               Bots.say(
                 chat["id"],
                 text,
                 Keyword.put(socket.assigns.opts, :attachments, socket.assigns.attachments)
               ),
             do: {:ok, chat}
      end

    case result do
      {:ok, chat} ->
        socket =
          socket
          |> assign(draft: "", reply_to: nil, error: nil, attachments: [])
          |> refresh()
          |> push_event("bots:sent", %{})

        {:noreply,
         if(socket.assigns.active_id == chat["id"],
           do: socket,
           else: push_patch(socket, to: chat_path(chat["id"]))
         )}

      {:error, _} ->
        {:noreply,
         assign(socket,
           draft: text,
           error: "Your message wasn’t sent. It’s still here — please try again."
         )}
    end
  catch
    :throw, :bots_service_unavailable -> {:noreply, unavailable_socket(socket)}
  end

  defp open_session(%{assigns: %{active: chat}}) when is_map(chat), do: {:ok, chat}
  defp open_session(%{assigns: %{selected: []}}), do: {:error, :no_bots}
  defp open_session(socket), do: Bots.create_session(socket.assigns.selected, socket.assigns.opts)

  defp refresh(socket) do
    do_refresh(socket)
  catch
    :throw, :bots_service_unavailable -> unavailable_socket(socket)
  end

  defp unavailable_socket(socket), do: assign(socket, available: false, subscribed: false)

  defp do_refresh(socket) do
    if connected?(socket) and not socket.assigns.subscribed,
      do: Bots.subscribe(socket.assigns.opts)

    snapshot = Bots.snapshot(socket.assigns.opts)

    assign(socket,
      available: true,
      subscribed: connected?(socket),
      bots: snapshot["bots"],
      sessions: snapshot["sessions"],
      preferences: snapshot["preferences"],
      active:
        if(socket.assigns.active_id,
          do: Bots.session(socket.assigns.active_id, socket.assigns.opts)
        )
    )
  end

  defp integer(value, fallback) do
    case Integer.parse(value || "") do
      {n, ""} -> n
      _ -> fallback
    end
  end

  defp chat_path(id), do: "/bots/" <> URI.encode(id, &URI.char_unreserved?/1)
  defp bot(bots, id), do: Enum.find(bots, &(&1["id"] == id)) || %{"name" => "Bot", "id" => id}
  defp participants(bots, ids), do: Enum.map(ids || [], &bot(bots, &1))
  defp names(bots), do: Enum.map_join(bots, ", ", & &1["name"])

  defp title(chat, bots),
    do:
      if(chat["title"] not in [nil, ""],
        do: chat["title"],
        else: names(participants(bots, chat["bot_ids"]))
      )

  defp messages(nil), do: []

  defp messages(chat) do
    entries =
      Enum.filter(chat["messages"] || [], &(&1["kind"] in ["human", "bot", "system", "request"]))

    answered =
      entries
      |> Enum.filter(&(&1["kind"] == "human" and is_binary(&1["request_id"])))
      |> MapSet.new(& &1["request_id"])

    Enum.map(entries, fn entry ->
      if entry["kind"] == "request" and MapSet.member?(answered, entry["request_id"]),
        do: Map.put(entry, "status", "answered"),
        else: entry
    end)
  end

  defp pending_count(chat),
    do: Enum.count(messages(chat), &(&1["kind"] == "request" and &1["status"] != "answered"))

  defp preview(chat) do
    case List.last(messages(chat)) do
      nil -> "Start a conversation"
      message -> String.slice(message["text"] || "", 0, 120)
    end
  end

  defp time(nil), do: ""
  defp time(value) when is_binary(value), do: String.slice(value, 11, 5)
  defp time(_), do: ""

  defp matches?(value, query),
    do: String.contains?(String.downcase(value || ""), String.downcase(query))

  defp speaker(message, bots) do
    case message["kind"] do
      "human" -> "You"
      "system" -> "Conversation"
      _ -> bot(bots, message["bot_id"])["name"]
    end
  end

  attr :bot, :map, required: true
  attr :small, :boolean, default: false

  defp face(assigns) do
    # Fixed class names, never interpolated CSS supplied by a bot. Preserve the
    # backend's distinct default colors, with deterministic fallback for custom ones.
    palette = %{
      "#7C83FD" => "sky",
      "#EF8354" => "peach",
      "#62B6A8" => "sage",
      "#C284D9" => "lilac",
      "#E4B85B" => "gold"
    }

    color =
      Map.get(palette, String.upcase(assigns.bot["color"] || "")) ||
        Enum.at(
          ~w(lilac sage peach sky rose gold),
          :erlang.phash2(assigns.bot["id"] || assigns.bot["name"], 6)
        )

    shape =
      if assigns.bot["shape"] in ~w(circle square squircle triangle),
        do: assigns.bot["shape"],
        else: "circle"

    assigns = assign(assigns, color: color, shape: shape)

    ~H"""
    <span
      class={["bots-face", "face-" <> @color, "shape-" <> @shape, @small && "face-small"]}
      aria-hidden="true"
    ><span class="face-eyes">••</span><span class="face-smile">⌣</span></span>
    """
  end

  @impl true
  def render(assigns) do
    if assigns.available, do: render_chat(assigns), else: render_unavailable(assigns)
  end

  defp render_unavailable(assigns) do
    ~H"""
    <main id="bots-shell" class="bots-app bots-unavailable">
      <section role="status" aria-labelledby="bots-unavailable-title">
        <span class="bots-dot" aria-hidden="true">✦</span>
        <h1 id="bots-unavailable-title">Your chats are temporarily unavailable</h1>
        <p>We couldn’t connect to your bots. Your saved conversations have not been changed.</p>
        <button
          id="bots-retry"
          type="button"
          class="bots-primary"
          phx-click="retry-service"
          phx-disable-with="Reconnecting…"
        >Try reconnecting</button>
        <p class="bots-unavailable-note">
          If this continues, the person looking after this computer may need to check the service.
        </p>
      </section>
    </main>
    """
  end

  defp render_chat(assigns) do
    entries = messages(assigns.active)

    pending_requests =
      Enum.filter(entries, &(&1["kind"] == "request" and &1["status"] != "answered"))

    recipients =
      participants(
        assigns.bots,
        if(assigns.active, do: assigns.active["bot_ids"], else: assigns.selected)
      )

    assigns =
      assign(assigns,
        recipients: recipients,
        filtered_bots:
          Enum.filter(
            assigns.bots,
            &(&1["id"] not in assigns.selected and matches?(&1["name"], assigns.query))
          ),
        filtered_chats:
          Enum.filter(
            assigns.sessions,
            &(matches?(title(&1, assigns.bots), assigns.search) or
                matches?(preview(&1), assigns.search))
          ),
        messages: Enum.take(entries, -assigns.message_limit),
        has_older: length(entries) > assigns.message_limit,
        pending_requests: pending_requests
      )

    ~H"""
    <main
      id="bots-shell"
      phx-hook="BotsShell"
      class={["bots-app", @mobile_list && "bots-show-list"]}
      data-session={@active_id || ""}
      data-notifications={to_string(@preferences["notifications"] == true)}
      data-cooldown={@preferences["cooldown_seconds"]}
      data-max-hour={@preferences["max_per_hour"]}
    >
      <aside class="bots-sidebar" aria-label="Chats">
        <header class="bots-sidebar-header">
          <h1>Bots<span class="bots-dot">✦</span></h1><div class="bots-actions">
            <button
              type="button"
              class="bots-icon"
              data-bots-focus="chat-search"
              aria-label="Search chats"
            >⌕</button><.link patch="/bots" class="bots-icon" aria-label="New chat">＋</.link>
          </div>
        </header>
        <form id="bots-search-form" phx-change="search" role="search" class="bots-search">
          <label class="bots-sr-only" for="chat-search">Search chats</label><input
            id="chat-search"
            name="search"
            value={@search}
            placeholder="Search chats"
            phx-debounce="150"
            type="search"
          />
        </form>
        <button
          :if={List.first(@bots)}
          type="button"
          class="bots-main-bot"
          phx-click="main-bot"
          phx-value-id={hd(@bots)["id"]}
        ><.face bot={hd(@bots)} /><span><strong>{hd(@bots)["name"]}</strong><small>Your everyday companion</small></span><span aria-hidden="true">↗</span></button>
        <div class="bots-section-label">Your chats <span>{length(@sessions)}</span></div>
        <nav class="bots-chat-list" aria-label="Conversations">
          <.link
            :for={chat <- @filtered_chats}
            patch={chat_path(chat["id"])}
            class={["bots-chat-row", @active_id == chat["id"] && "is-active"]}
            aria-current={if @active_id == chat["id"], do: "page"}
          >
            <span class="bots-face-stack"><.face
              :for={member <- Enum.take(participants(@bots, chat["bot_ids"]), 2)}
              bot={member}
              small={true}
            /><span :if={length(chat["bot_ids"] || []) > 1} class="bots-you-small">Y</span></span>
            <span class="bots-chat-copy"><strong>{title(chat, @bots)}</strong><small>{preview(chat)}</small></span>
            <span
              :if={pending_count(chat) > 0}
              class="bots-request-badge"
              aria-label={"#{pending_count(chat)} requests waiting"}
            >{pending_count(chat)}</span>
            <span :if={chat["status"] == "thinking"} class="bots-thinking-dot" aria-label="Thinking"></span>
          </.link>
          <p :if={@filtered_chats == []} class="bots-empty-list">
            {if @search == "",
              do: "Your conversations will feel at home here.",
              else: "No chats found. Try another name or phrase."}
          </p>
        </nav>
        <footer class="bots-sidebar-footer">
          <span class="bots-you">Y</span><div>
            <strong>You</strong><small>Your space, your pace</small>
          </div><button
            type="button"
            id="preferences-open"
            class="bots-icon"
            phx-click="preferences-open"
            aria-label="Notification settings"
          >⚙</button>
        </footer>
      </aside>
      <section class="bots-conversation" aria-label="Conversation">
        <header class="bots-conversation-header">
          <button class="bots-icon bots-mobile-back" phx-click="show-chats" aria-label="Back to chats">‹</button><div class="bots-participant-pill">
            <.face :for={member <- @recipients} bot={member} small={true} /><span>{if @active,
              do: title(@active, @bots),
              else: "New conversation"}</span>
          </div><.link patch="/bots" class="bots-icon" aria-label="New conversation">＋</.link>
        </header>
        <div :if={@error} class="bots-error" role="alert">
          <span>{@error}</span><button
            type="button"
            phx-click="dismiss-error"
            aria-label="Dismiss error"
          >×</button>
        </div>
        <section :if={!@active} class="bots-recipient-panel" aria-label="Choose recipients">
          <div class="bots-to-line">
            <span class="bots-to-label">To:</span><span :for={member <- @recipients} class="bots-chip"><.face
              bot={member}
              small={true}
            />{member["name"]}<button
              type="button"
              phx-click="remove-bot"
              phx-value-id={member["id"]}
              aria-label={"Remove " <> member["name"]}
            >×</button></span>
            <form
              id="bots-recipient-form"
              phx-change="recipient-query"
              phx-submit="group"
              class="bots-recipient-form"
            >
              <label for="recipient-input" class="bots-sr-only">Find or create a bot</label><input
                id="recipient-input"
                name="query"
                value={@query}
                placeholder={if @selected == [], do: "Find or create a bot…", else: "Add someone…"}
                autocomplete="off"
                role="combobox"
                aria-autocomplete="list"
                aria-expanded="true"
                aria-controls="bots-recipient-options"
              />
            </form>
          </div>
          <div
            class="bots-recipient-options"
            id="bots-recipient-options"
            role="listbox"
            aria-label="Bots"
          >
            <button
              type="button"
              id="recipient-create"
              class="bots-recipient-option"
              data-recipient-option
              role="option"
              tabindex="-1"
              aria-selected="false"
              phx-click="create-open"
            ><span class="bots-option-icon">＋</span><span>{if @query != "" and @filtered_bots == [],
              do: "Create “#{@query}”",
              else: "Create new Bot"}<small>A familiar face, with a personality of their own</small></span></button>
            <button
              type="button"
              id="recipient-group"
              class="bots-recipient-option"
              data-recipient-option
              role="option"
              tabindex="-1"
              aria-selected="false"
              phx-click="group"
            ><span class="bots-option-icon">♧</span><span>Create group chat<small>Choose two or more bots below</small></span></button>
            <button
              :for={{member, index} <- Enum.with_index(@filtered_bots)}
              id={"recipient-" <> member["id"]}
              type="button"
              class="bots-recipient-option"
              data-recipient-option
              data-bot-shortcut={if index < 9, do: index + 1}
              role="option"
              tabindex="-1"
              aria-selected="false"
              phx-click="choose-bot"
              phx-value-id={member["id"]}
            ><.face bot={member} small={true} /><span>{member["name"]}<small>{member["description"]}</small></span><kbd :if={
              index < 9
            }>⌘{index + 1}</kbd></button>
          </div>
          <p :if={length(@selected) > 1} class="bots-recipient-hint">
            Everyone will share this conversation, speaking as themselves.
          </p>
          <button
            :if={@selected != []}
            id="start-chat"
            type="button"
            class="bots-primary bots-start-chat"
            phx-click="start-chat"
          >Start {if length(@selected) > 1, do: "group chat", else: "chat"} →</button>
        </section>
        <div :if={@active && @pending_requests != []} class="bots-pending-request" role="status">
          <span>✦ {length(@pending_requests)} {if length(@pending_requests) == 1,
            do: "request is",
            else: "requests are"} waiting for you</span>
          <button type="button" phx-click="review-request" phx-value-id={hd(@pending_requests)["id"]}>Review request →</button>
        </div>
        <div
          :if={@active}
          id="bots-messages"
          tabindex="0"
          class="bots-messages"
          role="log"
          aria-label="Messages"
          aria-live="polite"
          aria-relevant="additions text"
        >
          <button :if={@has_older} type="button" class="bots-older" phx-click="older-messages">Load earlier messages</button>
          <div :if={@messages == []} class="bots-welcome">
            <div class="bots-welcome-faces"><.face :for={member <- @recipients} bot={member} /></div><h2>
              A little hello goes a long way.
            </h2><p>Ask a question, make a plan, or think out loud with {names(@recipients)}.</p>
          </div>
          <article
            :for={message <- @messages}
            id={"bot-message-" <> message["id"]}
            class={["bots-message", "message-" <> message["kind"]]}
          >
            <.face
              :if={message["kind"] in ["bot", "request"]}
              bot={bot(@bots, message["bot_id"])}
              small={true}
            />
            <div class="bots-message-content">
              <div class="bots-message-meta">
                <strong>{speaker(message, @bots)}</strong><time datetime={message["created_at"]}>{time(
                  message["created_at"]
                )}</time>
              </div><div class="bots-bubble bots-markdown">
                {BotsMarkdown.render(message["text"] || "")}
              </div>
              <div :if={image_refs(message["attachments"]) != []} class="bots-image-gallery">
                <a
                  :for={image <- image_refs(message["attachments"])}
                  href={"/api/images/" <> image["id"]}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  <img
                    src={"/api/images/" <> image["id"]}
                    alt={"Image shared by " <> speaker(message, @bots)}
                    loading="lazy"
                  />
                </a>
              </div>

              <div :if={message["kind"] == "request"} class="bots-request">
                <span>✦ {if message["status"] == "answered",
                  do: "Answered",
                  else: "Your input is needed"}</span><button
                  :if={message["status"] != "answered"}
                  type="button"
                  class="bots-secondary"
                  phx-click="reply"
                  phx-value-id={message["request_id"]}
                >Reply to request</button>
              </div>
            </div>
          </article>
        </div>
        <div :if={!@active and @selected == []} class="bots-new-welcome">
          <span>✦</span><h2>Good company for your ideas.</h2><p>
            Choose a bot above, or create someone new.
          </p>
        </div>
        <div :if={@active && @active["status"] == "thinking"} class="bots-status" role="status">
          <span class="bots-thinking-dot"></span>{names(@recipients)} {if length(@recipients) > 1,
            do: "are",
            else: "is"} thinking<button id="stop-thinking" type="button" phx-click="stop">■ Stop</button>
        </div>
        <div :if={@active && @active["status"] == "stopped"} class="bots-status" role="status">
          Conversation paused. Send a message when you’re ready to continue.
        </div>
        <div :if={@active && @active["status"] == "error"} class="bots-status" role="status">
          A bot couldn’t finish. Your messages are safe; try sending again.
        </div>
        <div class="bots-compose-area">
          <button id="bots-jump" type="button" class="bots-jump" hidden>New messages ↓</button>
          <div :if={@reply_to} class="bots-reply-banner">
            Replying to a request<button
              type="button"
              phx-click="cancel-reply"
              aria-label="Cancel reply"
            >×</button>
          </div>
          <form id="bots-composer" phx-submit="send" phx-change="draft" class="bots-composer">
            <div
              :if={@uploads.pictures.entries != [] or @attachments != []}
              class="bots-pending-images"
              aria-label="Attachments"
            >
              <div :for={entry <- @uploads.pictures.entries} class="bots-upload-entry">
                <span>{entry.client_name} · {entry.progress}%</span><button
                  type="button"
                  phx-click="cancel-upload"
                  phx-value-ref={entry.ref}
                  aria-label={"Remove " <> entry.client_name}
                >×</button>
                <p :for={error <- upload_errors(@uploads.pictures, entry)} role="alert">
                  {upload_error(error)}
                </p>
              </div>
              <div :for={image <- @attachments} class="bots-upload-entry">
                <span>Image ready</span><button
                  type="button"
                  phx-click="remove-attachment"
                  phx-value-id={image["id"]}
                  aria-label="Remove attached image"
                >×</button>
              </div>
            </div>
            <p :for={error <- upload_errors(@uploads.pictures)} class="bots-upload-error" role="alert">
              {upload_error(error)}
            </p>
            <.live_file_input
              upload={@uploads.pictures}
              tabindex="-1"
              class="bots-sr-only"
              disabled={@recipients == [] or @reply_to != nil}
              aria-label="Attach images"
            />
            <label class="bots-sr-only" for="message-input">Message</label>
            <textarea
              id="message-input"
              name="text"
              rows="2"
              maxlength="32000"
              placeholder={
                if @recipients == [],
                  do: "Choose a bot to begin",
                  else: "Message " <> names(@recipients)
              }
              disabled={@recipients == []}
              phx-debounce="200"
            >{@draft}</textarea><div class="bots-composer-tools">
              <button
                type="button"
                class="bots-icon"
                data-bots-attach={@uploads.pictures.ref}
                disabled={@recipients == [] or @reply_to != nil}
                aria-label="Attach images"
                title="Attach up to four PNG, JPEG, GIF or WebP images, each under 3.75 MB"
              >＋</button>
              <span class="bots-composer-hint">Shift + Enter for a new line</span>
              <button
                type="button"
                class="bots-icon"
                disabled
                title="Voice input is coming later"
                aria-label="Voice input unavailable"
              >♩</button><button
                type="submit"
                id="bots-send"
                class="bots-send"
                disabled={@recipients == []}
                aria-label="Send message"
                phx-disable-with="…"
              >↑</button>
            </div>
          </form>
          <p class="bots-footnote">A space to think together. Bots can make mistakes.</p>
        </div>
      </section>
      <div :if={@create_open} class="bots-modal-backdrop">
        <section
          id="create-bot-dialog"
          class="bots-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="create-bot-title"
          phx-window-keydown="create-close"
          phx-key="Escape"
        >
          <header>
            <h2 id="create-bot-title">Meet your new bot</h2><button
              type="button"
              class="bots-icon"
              phx-click="create-close"
              aria-label="Close"
            >×</button>
          </header><p>A name and a little personality. You can start talking right away.</p><p
            :if={@error}
            class="bots-modal-error"
            role="alert"
          >
            {@error}
          </p><form
            id="create-bot-form"
            phx-submit="create-bot"
          >
            <label for="bot-name">Name</label><input
              id="bot-name"
              name="bot[name]"
              value={@new_name}
              required
              maxlength="60"
              placeholder="e.g. Luna"
              autofocus
            /><label for="bot-description">What are they like?</label><textarea
              id="bot-description"
              name="bot[description]"
              maxlength="1000"
              rows="3"
              placeholder="A thoughtful creative partner, a patient guide…"
            ></textarea><button type="submit" class="bots-primary" phx-disable-with="Creating…">Create bot</button>
          </form>
        </section>
      </div>
      <div :if={@preferences_open} class="bots-modal-backdrop">
        <section
          id="bots-preferences"
          class="bots-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="preferences-title"
          phx-window-keydown="preferences-close"
          phx-key="Escape"
        >
          <header>
            <h2 id="preferences-title">Your attention, respected</h2><button
              type="button"
              class="bots-icon"
              phx-click="preferences-close"
              aria-label="Close"
            >×</button>
          </header><p>
            Notifications are off unless you choose them. Only important updates and requests, while this page is in the background. Keep the page open to receive them.
          </p><button id="bots-enable-browser" type="button" class="bots-secondary">Allow this browser to notify me</button><p
            id="bots-permission"
            role="status"
          >
            {permission_text(@permission)}
          </p><p :if={@error} class="bots-modal-error" role="alert">{@error}</p>
          <form id="bots-preferences-form" phx-submit="save-preferences">
            <label class="bots-checkbox"><input
              type="checkbox"
              name="preferences[notifications]"
              value="true"
              checked={@preferences["notifications"]}
            />Enable notifications</label><label for="notification-cooldown">Minimum seconds between alerts</label><input
              id="notification-cooldown"
              type="number"
              min="60"
              max="86400"
              name="preferences[cooldown_seconds]"
              value={@preferences["cooldown_seconds"]}
              required
            /><label for="notification-limit">Maximum alerts per hour (0 to mute)</label><input
              id="notification-limit"
              type="number"
              min="0"
              max="60"
              name="preferences[max_per_hour]"
              value={@preferences["max_per_hour"]}
              required
            /><button type="submit" class="bots-primary" phx-disable-with="Saving…">Save preferences</button>
          </form>
        </section>
      </div>
    </main>
    """
  end

  defp permission_text("granted"),
    do: "This browser allows notifications. Choose your limits below."

  defp permission_text("denied"),
    do: "Notifications are blocked. You can change this in your browser’s site settings."

  defp permission_text("unsupported"),
    do: "This browser doesn’t support notifications. Your requests still appear in chat."

  defp permission_text(_), do: "Browser permission and your preferences are both needed."
end

defmodule NanoWeb.BotsLive do
  @moduledoc "Consumer chat only; session bots_server selects an isolated facade server. Reconnect reloads durable state."
  use Phoenix.LiveView
  alias Nano.Bots

  def mount(_, session, s) do
    if connected?(s), do: Phoenix.PubSub.subscribe(Nano.PubSub, "bots")

    {:ok,
     assign(s,
       runtime_server: session["bots_runtime_server"] || Nano.Bots.Runtime,
       notices: [],
       composer_key: new_key(),
       server: session["bots_server"] || Nano.Bots.Store,
       bots: [],
       sessions: [],
       previews: %{},
       requests: [],
       current: nil,
       messages: [],
       selected: [],
       query: "",
       choice: 0,
       search: "",
       error: nil,
       answer_id: nil,
       memory_bot: nil,
       memories: [],
       cursor: 0,
       has_more: false,
       status: %{}
     )
     |> reload()
     |> allow_upload(:files, accept: :any, max_entries: 4, max_file_size: 10_485_760)}
  end

  defp new_key, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  defp opts(s), do: [server: s.assigns.server]
  defp rows({:ok, xs}), do: xs
  defp rows(_), do: []

  defp reload(s) do
    s =
      assign(s,
        bots: rows(Bots.list_bots(opts(s))),
        sessions: rows(Bots.list_sessions(opts(s))),
        requests: rows(Bots.list_requests(opts(s)))
      )

    previews =
      Map.new(s.assigns.sessions, fn c ->
        preview =
          case Bots.list_messages(c.id, opts(s) ++ [tail: true, limit: 1]) do
            {:ok, %{messages: messages}} ->
              case List.last(messages) do
                nil -> "No messages yet"
                m -> String.slice(m.text, 0, 90)
              end

            _ ->
              ""
          end

        {c.id, preview}
      end)

    s = assign(s, previews: previews, notices: runtime_notices(s))
    s = if s.assigns.current, do: select(s, s.assigns.current.id), else: s

    if s.assigns.memory_bot,
      do: assign(s, memories: rows(Bots.list_memories(s.assigns.memory_bot, opts(s)))),
      else: s
  end

  def handle_params(p, _, s), do: {:noreply, select(s, p["id"])}
  defp select(s, nil), do: assign(s, current: nil, messages: [])

  defp select(s, id) do
    with {:ok, chat} <- Bots.get_session(id, opts(s)),
         {:ok, page} <-
           Bots.list_messages(
             id,
             opts(s) ++ [tail: true, limit: 50]
           ) do
      assign(s,
        current: chat,
        messages: page.messages,
        cursor: page.next_cursor,
        has_more: page.has_more
      )
    else
      _ -> assign(s, current: nil, messages: [], error: "Chat not found")
    end
  end

  def handle_event("new", _, s),
    do: {:noreply, push_patch(assign(s, selected: [], query: "", answer_id: nil), to: "/bots")}

  def handle_event("query", %{"query" => q}, s), do: {:noreply, assign(s, query: q, choice: 0)}
  def handle_event("search", %{"search" => q}, s), do: {:noreply, assign(s, search: q)}

  def handle_event("pick", %{"id" => id}, s) do
    {:noreply,
     if(Enum.any?(s.assigns.bots, &(&1.id == id)),
       do: assign(s, selected: Enum.uniq(s.assigns.selected ++ [id]), query: "", choice: 0),
       else: s
     )}
  end

  def handle_event("remove", %{"id" => id}, s),
    do: {:noreply, assign(s, selected: List.delete(s.assigns.selected, id))}

  def handle_event("recipient_key", %{"key" => key} = p, s) do
    choices = candidates(s.assigns)

    cond do
      key == "ArrowDown" ->
        {:noreply, assign(s, choice: min(s.assigns.choice + 1, length(choices)))}

      key == "ArrowUp" ->
        {:noreply, assign(s, choice: max(s.assigns.choice - 1, 0))}

      key == "Enter" and s.assigns.choice < length(choices) ->
        handle_event("pick", %{"id" => Enum.at(choices, s.assigns.choice).id}, s)

      key == "Enter" ->
        handle_event("create_bot", %{}, s)

      p["metaKey"] == true and key in ~w(1 2 3 4 5 6 7 8 9) ->
        case Enum.at(s.assigns.bots, String.to_integer(key) - 1) do
          nil -> {:noreply, s}
          b -> handle_event("pick", %{"id" => b.id}, s)
        end

      true ->
        {:noreply, s}
    end
  end

  def handle_event("create_bot", _, s) do
    name = String.trim(s.assigns.query)

    case Bots.create_bot(%{name: if(name == "", do: "New Bot", else: name)}, opts(s)) do
      {:ok, b} ->
        {:noreply,
         reload(assign(s, selected: Enum.uniq(s.assigns.selected ++ [b.id]), query: ""))}

      _ ->
        {:noreply, assign(s, error: "Could not create bot")}
    end
  end

  def handle_event("start_chat", _, s) do
    case Bots.create_session(%{participant_ids: s.assigns.selected}, opts(s)) do
      {:ok, c} -> {:noreply, push_patch(reload(s), to: "/bots/" <> c.id)}
      _ -> {:noreply, assign(s, error: "Choose at least one bot")}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, s),
    do: {:noreply, cancel_upload(s, :files, ref)}

  def handle_event("validate", _, s), do: {:noreply, s}

  def handle_event("send", %{"text" => text} = p, s) do
    refs =
      consume_uploaded_entries(s, :files, fn %{path: path}, entry ->
        result =
          if entry.client_type in ~w(image/png image/jpeg image/gif image/webp) do
            with {:ok, image} <- Nano.Images.import_file(path),
                 do: Nano.Bots.Attachments.image_ref(image)
          else
            with {:ok, meta} <-
                   Nano.Bots.Attachments.import_file(path, filename: entry.client_name),
                 do: {:ok, meta.ref}
          end

        case result do
          {:ok, ref} -> {:ok, ref}
          _ -> {:ok, nil}
        end
      end)

    result =
      if Enum.any?(refs, &is_nil/1) or (s.assigns.answer_id && refs != []),
        do: {:error, :attachment_failed},
        else:
          if(s.assigns.answer_id,
            do: Bots.answer_request(s.assigns.answer_id, text, opts(s)),
            else:
              Bots.post_human(
                s.assigns.current.id,
                %{
                  text: text,
                  idempotency_key: p["message_key"] || s.assigns.composer_key,
                  attachments: Enum.reject(refs, &is_nil/1)
                },
                opts(s)
              )
          )

    if Enum.any?(refs, &is_nil/1) or (s.assigns.answer_id && refs != []),
      do:
        {:noreply,
         assign(s,
           error:
             "Attachment could not be sent. Request answers accept text only; please try again"
         )},
      else: mutate(s, result, true)
  end

  def handle_event("answer", %{"id" => id}, s) do
    valid =
      s.assigns.current &&
        Enum.any?(
          s.assigns.requests,
          &(&1.id == id and &1.session_id == s.assigns.current.id and &1.status == :pending)
        )

    {:noreply, if(valid, do: assign(s, answer_id: id), else: s)}
  end

  def handle_event("stop", _, s), do: mutate(s, Bots.stop_session(s.assigns.current.id, opts(s)))

  def handle_event("more", _, s) do
    case Bots.list_messages(
           s.assigns.current.id,
           opts(s) ++ [tail: true, before: hd(s.assigns.messages).sequence, limit: 50]
         ) do
      {:ok, p} ->
        {:noreply,
         assign(s,
           messages: Enum.take(p.messages ++ s.assigns.messages, 200),
           has_more: p.has_more
         )}

      _ ->
        {:noreply, s}
    end
  end

  def handle_event("notifications", %{"enabled" => enabled}, s) do
    prefs =
      Map.merge(s.assigns.current.notification_prefs, %{
        enabled: enabled == "true",
        muted: enabled != "true",
        min_interval_ms: s.assigns.current.notification_prefs[:min_interval_ms] || 60_000,
        max_per_hour: s.assigns.current.notification_prefs[:max_per_hour] || 5
      })

    mutate(s, Bots.update_session(s.assigns.current.id, %{notification_prefs: prefs}, opts(s)))
  end

  def handle_event("notification_limits", p, s) do
    interval = parse_limit(p["minutes"], 1, 1440) * 60_000
    hourly = parse_limit(p["hourly"], 1, 20)

    prefs =
      Map.merge(s.assigns.current.notification_prefs, %{
        min_interval_ms: interval,
        max_per_hour: hourly
      })

    mutate(s, Bots.update_session(s.assigns.current.id, %{notification_prefs: prefs}, opts(s)))
  end

  def handle_event("memory", %{"id" => id}, s),
    do: {:noreply, reload(assign(s, memory_bot: id))}

  def handle_event("memory_save", %{"record_id" => id, "text" => text}, s),
    do: mutate(s, Bots.update_memory(id, %{text: text}, opts(s)))

  def handle_event("memory_delete", %{"id" => id}, s),
    do: mutate(s, Bots.delete_memory(id, opts(s)))

  def handle_event("identity", %{"record_id" => id} = p, s) do
    attrs =
      Map.new([:name, :description, :voice, :face, :color], &{&1, p[Atom.to_string(&1)] || ""})

    mutate(s, Bots.update_bot(id, attrs, opts(s)))
  end

  defp mutate(s, result, sent \\ false) do
    case result do
      {:ok, _} ->
        s = reload(assign(s, error: nil, answer_id: nil, composer_key: new_key()))
        {:noreply, if(sent, do: push_event(s, "bots:sent", %{}), else: s)}

      _ ->
        {:noreply, assign(s, error: "Change could not be saved")}
    end
  end

  def handle_info({:bots, :runtime_notice, _}, s),
    do: {:noreply, assign(s, notices: runtime_notices(s))}

  def handle_info({:bots, :runtime_status, %{session_id: sid, bot_id: bid, status: status}}, s) do
    if status in [:thinking, :idle, :error, :stopped] do
      {:noreply, assign(s, status: Map.put(s.assigns.status, {sid, bid}, status))}
    else
      {:noreply, s}
    end
  end

  def handle_info({:bots, event, record}, s) do
    s = reload(s)

    c =
      if event == :request_created or (event == :message_created and record.actor != :human),
        do: Enum.find(s.assigns.sessions, &(&1.id == record.session_id)),
        else: nil

    s =
      if c && c.notification_prefs[:enabled] && !c.notification_prefs[:muted],
        do:
          push_event(s, "bots:notify", %{
            id: record.id,
            title:
              if(event == :request_created,
                do: "A bot needs your answer",
                else: "New bot message"
              ),
            min_interval_ms: c.notification_prefs[:min_interval_ms] || 60_000,
            max_per_hour: c.notification_prefs[:max_per_hour] || 5,
            session_id: c.id
          }),
        else: s

    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp parse_limit(value, low, high) do
    case Integer.parse(value || "") do
      {n, ""} -> max(low, min(n, high))
      _ -> low
    end
  end

  defp runtime_notices(s) do
    if Code.ensure_loaded?(Nano.Bots.Runtime) &&
         function_exported?(Nano.Bots.Runtime, :notices, 1) do
      try do
        case apply(Nano.Bots.Runtime, :notices, [[server: s.assigns.runtime_server]]) do
          {:ok, records} when is_list(records) -> Enum.take(records, -200)
          _ -> []
        end
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp candidates(a),
    do:
      Enum.filter(
        a.bots,
        &(&1.id not in a.selected and
            String.contains?(String.downcase(&1.name), String.downcase(a.query)))
      )

  defp bot(a, id), do: Enum.find(a.bots, &(&1.id == id))

  defp title(a, c),
    do:
      if(c.title == "",
        do: Enum.map_join(c.participant_ids, ", ", &bot(a, &1).name),
        else: c.title
      )

  defp actor(_, :human), do: "You"
  defp actor(a, {:bot, id}), do: bot(a, id).name
  defp color(b), do: if(b.color =~ ~r/^#[0-9a-fA-F]{6}$/, do: b.color, else: "#7c83fd")

  defp face(assigns) do
    ~H"""
    <span
      class={"bot-face face-" <> (if @bot.face in ~w(circle square diamond), do: @bot.face, else: "circle")}
      style={"background-color:" <> color(@bot)}
      aria-hidden="true"
    >•ᴗ•</span>
    """
  end

  defp attachment(assigns) do
    meta =
      case Nano.Bots.Attachments.metadata(assigns.ref) do
        {:ok, m} -> m
        _ -> nil
      end

    assigns = assign(assigns, :meta, meta)

    ~H"""
    <span :if={!@meta}>Attachment unavailable</span>
    <img :if={@meta && @meta.kind == :image} src={@meta.url} alt="Attached image" loading="lazy" />
    <a :if={@meta && @meta.kind == :file} href={@meta.url} download>{@meta.filename}</a>
    """
  end

  def render(assigns) do
    ~H"""
    <div id="bots-ui" class="bots-ui" phx-hook="BotsUI">
      <aside class="bots-sidebar">
        <header>
          <h1>Bots</h1><button phx-click="new" aria-label="New chat">＋</button>
        </header>
        <form id="chat-search" phx-change="search">
          <input name="search" value={@search} placeholder="Search chats" aria-label="Search chats" />
        </form>
        <button :if={List.first(@bots)} class="main-bot" phx-click="pick" phx-value-id={hd(@bots).id}><.face bot={
          hd(@bots)
        } />{hd(@bots).name}</button>
        <nav aria-label="Chats">
          <.link
            :for={c <- @sessions}
            :if={String.contains?(String.downcase(title(assigns, c)), String.downcase(@search))}
            patch={"/bots/" <> c.id}
            class={if @current && @current.id == c.id, do: "chat-row active", else: "chat-row"}
          ><span><.face :for={id <- c.participant_ids} bot={bot(assigns, id)} /><span
            :if={length(c.participant_ids) > 1}
            class="user-initials"
          >YO</span></span><strong>{title(assigns, c)}</strong><small>{@previews[c.id]}</small></.link>
        </nav>
        <footer>
          <span class="user-initials">YO</span> You <small>Connect apps · coming later</small>
        </footer>
      </aside>
      <main class="bots-main">
        <p :if={@error} role="alert">{@error}</p>
        <section :if={!@current} class="recipient-pane">
          <h2>New conversation</h2>
          <div class="recipient-line">
            <label for="to-query">To:</label><span :for={id <- @selected} class="recipient-chip"><.face bot={
              bot(assigns, id)
            } />{bot(assigns, id).name}<button
              phx-click="remove"
              phx-value-id={id}
              aria-label={"Remove " <> bot(assigns, id).name}
            >×</button></span><form id="recipient-search" phx-change="query" phx-submit="create_bot">
              <input
                id="to-query"
                name="query"
                value={@query}
                autocomplete="off"
                role="combobox"
                aria-controls="bot-options"
                aria-expanded="true"
                phx-keydown="recipient_key"
                placeholder="Name a bot"
              />
            </form>
          </div>
          <div id="bot-options" role="listbox" class="recipient-options">
            <button
              :for={{b, i} <- Enum.with_index(candidates(assigns))}
              role="option"
              aria-selected={i == @choice}
              phx-click="pick"
              phx-value-id={b.id}
            ><.face bot={b} />{b.name}<kbd>⌘{i + 1}</kbd></button><button phx-click="create_bot">Create new Bot{if @query !=
                                                                                                                     "",
                                                                                                                   do:
                                                                                                                     " “#{@query}”",
                                                                                                                   else:
                                                                                                                     ""}</button><button phx-click="start_chat">{if length(
                                                                                                                                                                      @selected
                                                                                                                                                                    ) >
                                                                                                                                                                      1,
                                                                                                                                                                    do:
                                                                                                                                                                      "Create group chat",
                                                                                                                                                                    else:
                                                                                                                                                                      "Start chat"}</button>
          </div>
        </section>
        <section :if={@current} class="conversation">
          <header class="conversation-header">
            <span class="participants-pill"><.face
              :for={id <- @current.participant_ids}
              bot={bot(assigns, id)}
            />{title(assigns, @current)}</span><button phx-click="stop">Stop replies</button><button
              phx-click="notifications"
              phx-value-enabled={to_string(!(@current.notification_prefs[:enabled] == true))}
              data-notification-opt-in="true"
            >{if @current.notification_prefs[:enabled],
              do: "Mute notifications",
              else: "Enable notifications"}</button>
          </header>
          <p :if={@current.stopped} role="status">
            Replies stopped. Your next message starts a new turn.
          </p>
          <p
            :for={id <- @current.participant_ids}
            :if={@status[{@current.id, id}] == :thinking}
            role="status"
          >
            {bot(assigns, id).name} is thinking…
          </p>
          <p
            :for={id <- @current.participant_ids}
            :if={@status[{@current.id, id}] == :error}
            role="status"
          >
            {bot(assigns, id).name} could not reply. Try sending again.
          </p>
          <div
            class="messages"
            aria-live="polite"
          >
            <article
              :for={m <- @messages}
              id={"message-" <> m.id}
              class={if m.actor == :human, do: "message human", else: "message bot"}
            >
              <strong>{actor(assigns, m.actor)}</strong><small :if={Map.get(m, :request_id)}>Answer to human request</small><div class="message-text">
                {Nano.Bots.Render.markdown(m.text)}
              </div><.attachment :for={ref <- m.attachments} ref={ref} />
            </article><button :if={@has_more} phx-click="more">Load older messages</button>
          </div>
          <section
            :for={r <- @requests}
            :if={r.session_id == @current.id and r.status == :pending}
            class="human-request"
            id={"request-" <> r.id}
          >
            <strong>Your answer is needed</strong><p>{r.text}</p><button
              phx-click="answer"
              phx-value-id={r.id}
            >Answer this request</button>
          </section>
          <p :if={@answer_id} role="status">Answering the selected request</p>
          <div :for={entry <- @uploads.files.entries} class="upload-preview">
            <span>{entry.client_name}</span><progress value={entry.progress} max="100">{entry.progress}%</progress><button
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              aria-label={"Remove " <> entry.client_name}
            >×</button><span :for={error <- upload_errors(@uploads.files, entry)} role="alert">Upload error: {error}</span>
          </div>
          <form id="bots-composer" phx-submit="send" phx-change="validate" class="bots-composer">
            <input type="hidden" name="message_key" value={@composer_key} /><label
              class="attachment-button"
              aria-label="Attach files"
            >＋<.live_file_input upload={@uploads.files} /></label><textarea
              id="message-input"
              name="text"
              required
              placeholder={"Message " <> title(assigns, @current)}
              aria-label="Message"
            /><button type="button" disabled aria-label="Voice input coming soon">♩</button><button type="submit">Send</button>
          </form>
          <form id="notification-limits" phx-submit="notification_limits">
            <label>Minutes between notifications<input
              type="number"
              name="minutes"
              min="1"
              max="1440"
              value={div(@current.notification_prefs[:min_interval_ms] || 60_000, 60_000)}
            /></label><label>Maximum per hour<input
              type="number"
              name="hourly"
              min="1"
              max="20"
              value={@current.notification_prefs[:max_per_hour] || 5}
            /></label><button>Save notification limits</button>
          </form>
          <details class="bot-settings">
            <summary>Bot identity and memory</summary><section :for={id <- @current.participant_ids}>
              <form phx-submit="identity">
                <input type="hidden" name="record_id" value={id} /><label>Name<input
                  name="name"
                  value={bot(assigns, id).name}
                /></label><label>Description<input
                  name="description"
                  value={bot(assigns, id).description}
                /></label><label>Voice<input name="voice" value={bot(assigns, id).voice} /></label><label>Face<select name="face"><option
                  :for={f <- ~w(circle square diamond)}
                  selected={bot(assigns, id).face == f}
                >
                  {f}
                </option></select></label><label>Color<input
                  type="color"
                  name="color"
                  value={color(bot(assigns, id))}
                /></label><button>Save identity</button>
              </form><button phx-click="memory" phx-value-id={id}>View {bot(assigns, id).name}’s memory</button>
            </section><section :if={@memory_bot}>
              <h3>Memory you can manage</h3><article :for={m <- @memories}>
                <form phx-submit="memory_save">
                  <input type="hidden" name="record_id" value={m.id} /><textarea
                    name="text"
                    aria-label="Memory text"
                  >{m.text}</textarea><small>Provenance: {inspect(m.provenance)}</small><button>Save memory</button>
                </form><button phx-click="memory_delete" phx-value-id={m.id}>Delete memory</button>
              </article><p :if={@memories == []}>No saved memories.</p>
            </section>
          </details>
        </section>
      </main>
    </div>
    """
  end
end

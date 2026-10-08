defmodule NanoWeb.BotsLiveTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NanoWeb.Endpoint

  defmodule QuietRuntime do
    def dispatch(bot, session, context, opts) do
      send(opts[:observer], {:ui_dispatch, bot, session, context})
      :ok
    end

    def stop(_bot, _session, _opts), do: :ok
  end

  defmodule QuietRouter do
    def select(bots, _session, message, _opts),
      do: {:ok, if(message["kind"] == "human", do: [hd(bots)["id"]], else: [])}
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "bots-ui-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    server =
      start_supervised!(
        {Bots,
         root: root, name: nil, runtime: QuietRuntime, router: QuietRouter, observer: self()}
      )

    on_exit(fn -> File.rm_rf!(root) end)
    opts = [server: server]

    {:ok, luna} =
      Bots.create_bot(%{"name" => "Luna", "description" => "A thoughtful creative partner"}, opts)

    {:ok, moss} = Bots.create_bot(%{"name" => "Moss", "description" => "A practical guide"}, opts)
    conn = build_conn() |> Plug.Test.init_test_session(%{"bots_server" => inspect(server)})
    %{conn: conn, opts: opts, server: server, luna: luna, moss: moss}
  end

  test "new conversation has a friendly home, filtered recipients, chips and group creation",
       ctx do
    {:ok, view, html} = live(ctx.conn, "/bots")
    assert html =~ "Your everyday companion"
    assert has_element?(view, "#recipient-input[role=combobox]")
    assert has_element?(view, "#message-input[disabled]")
    refute html =~ "/api/eval"
    refute html =~ "harness"
    view |> form(".bots-recipient-form", %{query: "lun"}) |> render_change()
    assert has_element?(view, "[data-recipient-option]", "Luna")
    refute has_element?(view, "[data-recipient-option]", "Moss")
    view |> element("#recipient-" <> ctx.luna["id"]) |> render_click()
    assert has_element?(view, ".bots-chip", "Luna")
    assert has_element?(view, "#message-input[placeholder='Message Luna']")
    view |> element("#recipient-" <> ctx.moss["id"]) |> render_click()
    assert has_element?(view, "#start-chat", "Start group chat")
    assert has_element?(view, ".bots-chip", "Moss")
    view |> element("button[aria-label='Remove Luna']") |> render_click()
    refute has_element?(view, ".bots-chip", "Luna")
    view |> element("#recipient-" <> ctx.luna["id"]) |> render_click()
    view |> element("#start-chat") |> render_click()
    [chat] = Bots.snapshot(ctx.opts)["sessions"]
    assert_patch(view, "/bots/" <> chat["id"])
    assert Enum.sort(chat["bot_ids"]) == Enum.sort([ctx.luna["id"], ctx.moss["id"]])
    assert has_element?(view, ".bots-participant-pill", "Luna")
    assert has_element?(view, ".bots-participant-pill", "Moss")
    refute has_element?(view, "#recipient-input")
  end

  test "a name with no matches creates a bot on the spot without losing selected chips", ctx do
    {:ok, view, _} = live(ctx.conn, "/bots")
    view |> element("#recipient-" <> ctx.luna["id"]) |> render_click()
    view |> form(".bots-recipient-form", %{query: "Nova"}) |> render_change()
    assert has_element?(view, "#recipient-create", "Create “Nova”")
    view |> element("#recipient-create") |> render_click()
    assert has_element?(view, "#bot-name[value=Nova]")

    view
    |> form("#create-bot-form", %{bot: %{name: "Nova", description: "A patient tutor"}})
    |> render_submit()

    refute has_element?(view, "#create-bot-dialog")
    assert has_element?(view, ".bots-chip", "Nova")
    assert has_element?(view, ".bots-chip", "Luna")
    assert Enum.any?(Bots.snapshot(ctx.opts)["bots"], &(&1["name"] == "Nova"))
  end

  test "send creates a conversation, named messages, live thinking, stop and safe Markdown",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/bots")
    view |> element("#recipient-" <> ctx.luna["id"]) |> render_click()

    text =
      "Hello **Luna**\n\n<script>alert(1)</script>\n\n[bad](javascript:alert)\n\n```html\n</code><img src=x onerror=alert(1)>\n```"

    view |> form("#bots-composer", %{text: text}) |> render_submit()
    [chat] = Bots.snapshot(ctx.opts)["sessions"]
    assert_patch(view, "/bots/" <> chat["id"])
    assert has_element?(view, ".message-human strong", "You")
    assert has_element?(view, ".bots-markdown strong", "Luna")
    assert has_element?(view, ".bots-markdown pre code", "<img")
    refute has_element?(view, ".bots-markdown script")
    refute has_element?(view, ".bots-markdown img")
    refute has_element?(view, ".bots-markdown a")
    assert has_element?(view, "#stop-thinking")
    assert has_element?(view, "[role=status]", "thinking")
    view |> element("#stop-thinking") |> render_click()
    assert has_element?(view, "[role=status]", "paused")
    refute has_element?(view, "#stop-thinking")
    assert Bots.session(chat["id"], ctx.opts)["status"] == "stopped"
  end

  test "search chats, active chat highlighting, mobile back and unknown IDs", ctx do
    {:ok, chat} = Bots.create_session([ctx.luna["id"]], ctx.opts)
    {:ok, _other} = Bots.create_session([ctx.moss["id"]], ctx.opts)
    {:ok, view, _} = live(ctx.conn, "/bots/" <> chat["id"])
    assert has_element?(view, ".bots-chat-row[aria-current=page]", "Luna")
    view |> form(".bots-search", %{search: "moss"}) |> render_change()
    assert has_element?(view, ".bots-chat-row", "Moss")
    refute has_element?(view, ".bots-chat-row", "Luna")
    view |> form(".bots-search", %{search: "not-found"}) |> render_change()
    assert has_element?(view, ".bots-empty-list", "No chats found")
    view |> element("button[aria-label='Back to chats']") |> render_click()
    assert has_element?(view, ".bots-show-list")
    {:ok, unknown, _} = live(ctx.conn, "/bots/missing")
    assert has_element?(unknown, "[role=alert]", "no longer available")
  end

  test "notifications are opt-in, permission is separate and persisted limits drive hook data",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/bots")
    assert has_element?(view, "#bots-shell[data-notifications=false]")
    view |> element("#preferences-open") |> render_click()
    assert has_element?(view, "#bots-preferences[role=dialog]")
    refute has_element?(view, "input[type=checkbox][checked]")
    assert has_element?(view, "#bots-enable-browser")
    render_hook(view, "permission", %{permission: "denied"})
    assert has_element?(view, "#bots-permission", "blocked")

    view
    |> form("#bots-preferences-form", %{
      preferences: %{notifications: "true", cooldown_seconds: "600", max_per_hour: "3"}
    })
    |> render_submit()

    refute has_element?(view, "#bots-preferences")

    assert has_element?(
             view,
             "#bots-shell[data-notifications=true][data-cooldown='600'][data-max-hour='3']"
           )

    assert Bots.snapshot(ctx.opts)["preferences"]["max_per_hour"] == 3

    event = %{
      id: "event-ui-test",
      title: "Luna",
      body: "Your input is needed",
      session_id: "some-chat"
    }

    send(view.pid, {:bots_notification, event})
    assert_push_event(view, "bots:notification", ^event)
  end

  test "invalid notification limits report a calm error and preserve preferences", ctx do
    {:ok, view, _} = live(ctx.conn, "/bots")
    view |> element("#preferences-open") |> render_click()

    view
    |> form("#bots-preferences-form", %{
      preferences: %{cooldown_seconds: "1", max_per_hour: "999"}
    })
    |> render_submit()

    assert has_element?(view, "[role=alert]", "at least 60 seconds")
    assert Bots.snapshot(ctx.opts)["preferences"]["notifications"] == false
  end

  test "untrusted bot identity and unknown operator messages never become executable markup",
       ctx do
    {:ok, odd} = Bots.create_bot(%{"name" => "<img src=x onerror=alert(1)>"}, ctx.opts)
    {:ok, chat} = Bots.create_session([odd["id"]], ctx.opts)
    {:ok, view, html} = live(ctx.conn, "/bots/" <> chat["id"])
    assert html =~ "&lt;img"
    refute has_element?(view, "#bots-shell img")
    send(view.pid, {:nano_log, %{text: "OPERATOR SECRET", kind: "eval"}})
    refute render(view) =~ "OPERATOR SECRET"
  end

  test "human requests arrive live, replies return to the requester and cannot be answered twice",
       ctx do
    {:ok, chat} = Bots.create_session([ctx.luna["id"]], ctx.opts)
    {:ok, view, _} = live(ctx.conn, "/bots/" <> chat["id"])

    {:ok, request} =
      Bots.request(
        ctx.luna["id"],
        "Which hotel should I book?",
        Keyword.merge(ctx.opts, session_id: chat["id"], requester: self())
      )

    assert has_element?(view, ".message-request", "Which hotel should I book?")
    assert has_element?(view, ".bots-pending-request", "1 request is waiting")
    assert has_element?(view, ".bots-request-badge", "1")
    view |> element("button[phx-click=reply]") |> render_click()
    assert has_element?(view, ".bots-reply-banner", "Replying to a request")
    assert has_element?(view, "button[data-bots-attach][disabled]")
    view |> form("#bots-composer", %{text: "The quiet one, please."}) |> render_submit()
    id = request["id"]
    assert_receive {:bots_answer, ^id, "The quiet one, please."}
    assert has_element?(view, ".message-human", "The quiet one, please.")
    assert has_element?(view, ".bots-request", "Answered")
    refute has_element?(view, ".bots-pending-request")
    refute has_element?(view, ".bots-request-badge")
    refute has_element?(view, "button[phx-click=reply]")
    assert Bots.request_status(id, ctx.opts)["status"] == "answered"
    render_click(view, "reply", %{id: id})
    refute has_element?(view, ".bots-reply-banner")
  end

  test "images upload as validated references and render only fixed immutable URLs", ctx do
    {:ok, chat} = Bots.create_session([ctx.luna["id"]], ctx.opts)
    {:ok, view, _} = live(ctx.conn, "/bots/" <> chat["id"])
    bytes = Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")

    upload =
      file_input(view, "#bots-composer", :pictures, [
        %{name: "little.gif", content: bytes, type: "image/gif"}
      ])

    assert render_upload(upload, "little.gif") =~ "little.gif"
    view |> form("#bots-composer", %{text: "What do you see?"}) |> render_submit()

    refute has_element?(view, ".bots-error"),
           render(view)
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".bots-error")
           |> LazyHTML.text()

    [message] = Bots.session(chat["id"], ctx.opts)["messages"]
    [ref] = message["attachments"]
    assert ref["type"] == "image_ref"
    assert ref["mime"] == "image/gif"
    assert {:ok, ^bytes, "image/gif"} = Images.read(ref)
    assert has_element?(view, ".bots-image-gallery img[src='/api/images/#{ref["id"]}']")
    assert has_element?(view, ".bots-image-gallery a[rel='noopener noreferrer']")
    refute has_element?(view, ".bots-pending-images")
  end

  test "corrupt images cannot be sent and drafts survive validation errors", ctx do
    {:ok, chat} = Bots.create_session([ctx.luna["id"]], ctx.opts)
    {:ok, view, _} = live(ctx.conn, "/bots/" <> chat["id"])

    upload =
      file_input(view, "#bots-composer", :pictures, [
        %{name: "pretend.png", content: "<svg onload=alert(1)></svg>", type: "image/png"}
      ])

    render_upload(upload, "pretend.png")
    view |> form("#bots-composer", %{text: "Keep this draft"}) |> render_submit()
    assert has_element?(view, "[role=alert]", "couldn’t be read")
    assert has_element?(view, "#message-input", "Keep this draft")
    refute has_element?(view, ".bots-image-gallery img")
    assert Bots.session(chat["id"], ctx.opts)["messages"] == []
  end

  test "the main companion reopens an existing direct chat instead of creating duplicates", ctx do
    {:ok, chat} = Bots.create_session([ctx.luna["id"]], ctx.opts)
    {:ok, view, _} = live(ctx.conn, "/bots")
    render_click(view, "main-bot", %{id: ctx.luna["id"]})
    assert_patch(view, "/bots/" <> chat["id"])
    assert length(Bots.snapshot(ctx.opts)["sessions"]) == 1
  end

  test "a bot's reply is named, updates live and clears thinking without operator traffic", ctx do
    {:ok, chat} = Bots.create_session([ctx.luna["id"]], ctx.opts)
    {:ok, view, _} = live(ctx.conn, "/bots/" <> chat["id"])
    view |> form("#bots-composer", %{text: "Hello"}) |> render_submit()
    assert_receive {:ui_dispatch, _, _, context}, 1000
    assert {:ok, _} = Bots.post(context.token, "A **lovely** day for ideas.", ctx.opts)
    assert has_element?(view, ".message-bot .bots-message-meta strong", "Luna")
    assert has_element?(view, ".message-bot .bots-markdown strong", "lovely")
    eventually(fn -> not has_element?(view, "#stop-thinking") end)
    refute render(view) =~ "tool_call"
  end

  test "long conversations initially render the latest hundred and let readers load earlier messages",
       ctx do
    {:ok, chat} = Bots.create_session([ctx.luna["id"]], ctx.opts)

    for n <- 1..105 do
      {:ok, _} =
        Bots.request(
          ctx.luna["id"],
          "Question #{n}",
          Keyword.merge(ctx.opts, session_id: chat["id"], requester: self())
        )
    end

    {:ok, view, _} = live(ctx.conn, "/bots/" <> chat["id"])
    assert has_element?(view, ".bots-older", "Load earlier messages")

    assert Enum.count(LazyHTML.query(LazyHTML.from_fragment(render(view)), ".bots-message")) ==
             100

    view |> element(".bots-older") |> render_click()
    refute has_element?(view, ".bots-older")
    render_patch(view, "/bots/" <> chat["id"])
    assert has_element?(view, ".bots-older")
    view |> element("button[phx-click=review-request]") |> render_click()
    assert_push_event(view, "bots:reveal-message", %{id: _message_id})
    refute has_element?(view, ".bots-older")

    assert Enum.count(LazyHTML.query(LazyHTML.from_fragment(render(view)), ".bots-message")) ==
             105
  end

  test "oversized messages are rejected explicitly without silently sending a truncated message",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/bots")
    view |> element("#recipient-" <> ctx.luna["id"]) |> render_click()
    render_submit(view, "send", %{text: String.duplicate("界", 20_000)})
    assert has_element?(view, ".bots-error", "too long")
    assert Bots.snapshot(ctx.opts)["sessions"] == []
  end

  test "invalid bot names show their error inside the open dialog", ctx do
    {:ok, view, _} = live(ctx.conn, "/bots")
    view |> element("#recipient-create") |> render_click()
    view |> form("#create-bot-form", %{bot: %{name: "   "}}) |> render_submit()
    assert has_element?(view, "#create-bot-dialog .bots-modal-error", "couldn’t create")
  end

  test "empty messages do not create chats", ctx do
    {:ok, view, _} = live(ctx.conn, "/bots")
    view |> element("#recipient-" <> ctx.luna["id"]) |> render_click()
    view |> form("#bots-composer", %{text: " \n "}) |> render_submit()
    assert has_element?(view, "[role=alert]", "Write a message first")
    assert Bots.snapshot(ctx.opts)["sessions"] == []
  end
end

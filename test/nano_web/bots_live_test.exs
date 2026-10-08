defmodule NanoWeb.BotsLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NanoWeb.Endpoint

  defmodule Runtime do
    def deliver(_, _, _, _), do: :ok
    def notify(_, _), do: :ok
    def info(_), do: nil
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "bots-ui-#{System.unique_integer([:positive])}-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
      )

    server = start_supervised!({Vega.Bots.Server, root: root, name: nil, runtime: Runtime})
    previous = Application.get_env(:nano, :bots_server)
    Application.put_env(:nano, :bots_server, server)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nano, :bots_server, previous),
        else: Application.delete_env(:nano, :bots_server)

      File.rm_rf!(root)
    end)

    %{
      conn: build_conn(),
      opts: [
        server: server,
        model: "openai-codex/gpt-6.1-sol",
        reasoning: "low",
        max_context: 272_000,
        max_turns: 0,
        max_tokens: 0
      ]
    }
  end

  defp open(conn), do: live_isolated(conn, NanoWeb.BotsLive)

  defp create(view, name) do
    view |> element("button", "Create your first bot") |> render_click()

    view
    |> form("#create-bot", %{name: name, description: "Helpful", voice: "Calm"})
    |> render_submit()
  end

  test "onboarding creates a stable bot, starts a chat and sends authored text", ctx do
    {:ok, view, html} = open(ctx.conn)
    assert html =~ "Create your first bot"
    create(view, "Muse")
    assert has_element?(view, ".chip", "Muse")
    view |> element("button", "Start chat") |> render_click()
    assert has_element?(view, "#message-text[placeholder='Message Muse']")
    view |> form("#composer", %{text: "Hello **friend**"}) |> render_submit()
    assert has_element?(view, ".person-message .bubble strong", "friend")
    {:ok, [chat]} = Vega.Bots.sessions(ctx.opts)
    assert List.last(chat["messages"])["author_id"] == "person"
    assert has_element?(view, "#message-text", "")
  end

  test "recipient filtering, removable chips and a shared group", ctx do
    {:ok, a} = Vega.Bots.create_bot("Muse", ctx.opts)
    {:ok, b} = Vega.Bots.create_bot("Orbit", ctx.opts)
    {:ok, view, _} = open(ctx.conn)
    view |> element("button[aria-label='New chat']") |> render_click()
    view |> form("form[phx-change='recipient-query']", %{query: "Mus"}) |> render_change()
    assert has_element?(view, "#recipient-options button", "Muse")
    refute has_element?(view, "#recipient-options button", "Orbit")

    view
    |> element("button[phx-value-id='#{a["id"]}'][phx-click='add-recipient']")
    |> render_click()

    view
    |> element("button[phx-value-id='#{b["id"]}'][phx-click='add-recipient']")
    |> render_click()

    assert has_element?(view, ".new-chat", "Group chat · 2 bots")
    view |> element("button[aria-label='Remove Muse']") |> render_click()
    refute has_element?(view, ".chip", "Muse")

    view
    |> element("button[phx-value-id='#{a["id"]}'][phx-click='add-recipient']")
    |> render_click()

    view |> element("button", "Start chat") |> render_click()
    {:ok, [chat]} = Vega.Bots.sessions(ctx.opts)
    assert Enum.sort(chat["bot_ids"]) == Enum.sort([a["id"], b["id"]])
  end

  test "PubSub shows safe Markdown and status; human requests have explicit answers", ctx do
    {:ok, bot} = Vega.Bots.create_bot("Muse", ctx.opts)
    {:ok, chat} = Vega.Bots.create_session([bot["id"]], ctx.opts)
    {:ok, view, _} = open(ctx.conn)
    view |> element("button[phx-click='open-session']") |> render_click()

    {:ok, _} =
      Vega.Bots.post(
        chat["id"],
        bot["id"],
        "<script>alert(1)</script> [bad](javascript:alert) **safe**",
        ctx.opts
      )

    html = render(view)
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
    refute html =~ "href=\"javascript:"
    assert has_element?(view, ".bot-message strong", "safe")
    {:ok, _} = Vega.Bots.status(chat["id"], bot["id"], "thinking", ctx.opts)
    assert render(view) =~ "Thinking"

    {:ok, request} =
      Vega.Bots.request_human(
        bot["id"],
        "Which date?",
        ctx.opts ++ [session_id: chat["id"], requester: "ui-test-requester"]
      )

    assert render(view) =~ "Which date?"
    view |> form("#request-#{request["id"]} form", %{answer: "Friday"}) |> render_submit()
    assert render(view) =~ "Answered: Friday"
    {:ok, snapshot} = Vega.Bots.snapshot(ctx.opts)
    assert Enum.find(snapshot["requests"], &(&1["id"] == request["id"]))["answer"] == "Friday"
  end

  test "failed send preserves draft and notification preferences persist", ctx do
    {:ok, bot} = Vega.Bots.create_bot("Muse", ctx.opts)
    {:ok, _} = Vega.Bots.create_session([bot["id"]], ctx.opts)
    {:ok, view, _} = open(ctx.conn)
    view |> element("button[phx-click='open-session']") |> render_click()
    # Empty messages are rejected by the real service, not a UI fake.
    view |> form("#composer", %{text: "  "}) |> render_submit()
    assert render(view) =~ "Message was not sent"
    assert render(view) =~ ~s(value="  ")
    view |> element("button", "Notifications") |> render_click()

    view
    |> form("#notification-controls form", %{
      notifications_enabled: "true",
      notification_requests_only: "true",
      notification_interval_seconds: "120",
      notification_max_per_hour: "2"
    })
    |> render_change()

    {:ok, snapshot} = Vega.Bots.snapshot(ctx.opts)
    assert snapshot["settings"]["notifications_enabled"] == true
    assert snapshot["settings"]["notification_interval_seconds"] == 120
    assert has_element?(view, "button[aria-label='Voice input coming later'][disabled]")
    view |> element("button", "Back to chats") |> render_click()
    assert has_element?(view, ".bots-app[data-pane='list']")
  end

  test "switching chats keeps separate drafts and ignores unknown info", ctx do
    {:ok, bot} = Vega.Bots.create_bot("Muse", ctx.opts)
    {:ok, first} = Vega.Bots.create_session([bot["id"]], ctx.opts ++ [title: "One"])
    {:ok, second} = Vega.Bots.create_session([bot["id"]], ctx.opts ++ [title: "Two"])
    {:ok, view, _} = open(ctx.conn)

    view
    |> element("button[phx-click='open-session'][phx-value-id='#{first["id"]}']")
    |> render_click()

    view |> form("#composer", %{text: "Draft for one"}) |> render_change()

    view
    |> element("button[phx-click='open-session'][phx-value-id='#{second["id"]}']")
    |> render_click()

    refute has_element?(view, "#message-text", "Draft for one")
    view |> form("#composer", %{text: "Draft for two"}) |> render_change()

    view
    |> element("button[phx-click='open-session'][phx-value-id='#{first["id"]}']")
    |> render_click()

    assert has_element?(view, "#message-text", "Draft for one")
    send(view.pid, {:unexpected, :ignore})
    assert render(view) =~ "Draft for one"
    view |> form("#chat-search-form", %{search: "Two"}) |> render_change()
    assert has_element?(view, ".chat-row", "Two")
    refute has_element?(view, ".chat-row", "One")
  end

  test "uploaded images and bot-produced files render only immutable URLs", ctx do
    {:ok, bot} = Vega.Bots.create_bot("Muse", ctx.opts)
    {:ok, chat} = Vega.Bots.create_session([bot["id"]], ctx.opts)
    {:ok, view, _} = open(ctx.conn)
    view |> element("button[phx-click='open-session']") |> render_click()

    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWQAAAABJRU5ErkJggg=="
      )

    upload =
      file_input(view, "#composer", :images, [
        %{name: "photo.png", content: png, type: "image/png"}
      ])

    assert render_upload(upload, "photo.png") =~ "photo.png"
    view |> form("#composer", %{text: "Look at this"}) |> render_submit()
    {:ok, stored} = Vega.Bots.get_session(chat["id"], ctx.opts)
    [image] = List.last(stored["messages"])["images"]
    assert has_element?(view, "img[src='/api/images/#{image["id"]}']")
    path = Path.join(System.tmp_dir!(), "bots-ui-file-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "a safe download")
    on_exit(fn -> File.rm(path) end)
    {:ok, file} = Vega.Bots.attach_file(path, ctx.opts ++ [filename: "<script>.txt"])
    {:ok, _} = Vega.Bots.post(chat["id"], bot["id"], "Your file", ctx.opts ++ [files: [file]])
    assert render(view) =~ "/bots/files/#{file["id"]}"
    assert has_element?(view, "a[download]", file["filename"])
    refute render(view) =~ "<script>"
  end

  test "history is fetched only for selected chat and paged in a bounded window", ctx do
    {:ok, bot} = Vega.Bots.create_bot("Muse", ctx.opts)
    {:ok, chat} = Vega.Bots.create_session([bot["id"]], ctx.opts ++ [title: "Long chat"])
    {:ok, unopened} = Vega.Bots.create_session([bot["id"]], ctx.opts ++ [title: "Other"])

    for i <- 1..410,
        do:
          assert(
            match?({:ok, _}, Vega.Bots.post(chat["id"], bot["id"], "History item #{i}", ctx.opts))
          )

    {:ok, _} = Vega.Bots.post(unopened["id"], bot["id"], "Unopened transcript", ctx.opts)
    {:ok, snapshot} = Vega.Bots.snapshot(ctx.opts)
    assert Enum.all?(snapshot["sessions"], &(length(&1["messages"] || []) <= 1))
    {:ok, view, _} = open(ctx.conn)

    view
    |> element("button[phx-value-id='#{chat["id"]}'][phx-click='open-session']")
    |> render_click()

    assert has_element?(view, "#messages", "History item 410")
    refute has_element?(view, "#messages", "History item 1")
    refute has_element?(view, "#messages", "Unopened transcript")

    assert length(
             LazyHTML.from_document(render(view))
             |> LazyHTML.query("#messages article")
             |> LazyHTML.to_tree()
           ) == 80

    view |> element("button", "Load earlier messages") |> render_click()
    assert has_element?(view, "#messages", "History item 251")
    for _ <- 1..3, do: view |> element("button", "Load earlier messages") |> render_click()
    refute has_element?(view, "button[phx-click='load-earlier'][disabled]")

    assert length(
             LazyHTML.from_document(render(view))
             |> LazyHTML.query("#messages article")
             |> LazyHTML.to_tree()
           ) == 400

    view |> element("button", "Load earlier messages") |> render_click()
    assert has_element?(view, "#messages", "History item 1")
    refute has_element?(view, "#messages", "History item 410")
    {:ok, _} = Vega.Bots.post(chat["id"], bot["id"], "New while reading", ctx.opts)
    assert render(view) =~ "New messages have arrived"
    assert has_element?(view, "#messages", "History item 1")
    refute has_element?(view, "#messages", "New while reading")
    view |> element("button", "Show latest messages") |> render_click()

    assert length(
             LazyHTML.from_document(render(view))
             |> LazyHTML.query("#messages article")
             |> LazyHTML.to_tree()
           ) == 80

    assert has_element?(view, "#messages", "History item 410")
  end

  test "detaching freezes the initial page and reaching the bottom resumes following", ctx do
    {:ok, bot} = Vega.Bots.create_bot("Muse", ctx.opts)
    {:ok, chat} = Vega.Bots.create_session([bot["id"]], ctx.opts)
    for i <- 1..85, do: Vega.Bots.post(chat["id"], bot["id"], "Detached item #{i}", ctx.opts)
    {:ok, view, _} = open(ctx.conn)
    view |> element("button[phx-click='open-session']") |> render_click()
    assert has_element?(view, "#messages .bubble p", ~r/^Detached item 6$/)
    render_hook(view, "reading-history", %{reading: true})
    {:ok, _} = Vega.Bots.post(chat["id"], bot["id"], "Detached new item", ctx.opts)
    assert has_element?(view, "#messages .bubble p", ~r/^Detached item 6$/)
    refute has_element?(view, "#messages", "Detached new item")
    assert render(view) =~ "New messages have arrived"
    render_hook(view, "reading-history", %{reading: false})
    assert has_element?(view, "#messages", "Detached new item")
    refute has_element?(view, "#messages .bubble p", ~r/^Detached item 6$/)
  end

  test "chat changes cancel raw uploads but keep imported refs in their original draft", ctx do
    {:ok, bot} = Vega.Bots.create_bot("Muse", ctx.opts)
    {:ok, a} = Vega.Bots.create_session([bot["id"]], ctx.opts ++ [title: "A"])
    {:ok, b} = Vega.Bots.create_session([bot["id"]], ctx.opts ++ [title: "B"])
    {:ok, view, _} = open(ctx.conn)

    switch = fn id ->
      view |> element("button[phx-click='open-session'][phx-value-id='#{id}']") |> render_click()
    end

    switch.(a["id"])

    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWQAAAABJRU5ErkJggg=="
      )

    upload =
      file_input(view, "#composer", :images, [
        %{name: "private-a.png", content: png, type: "image/png"}
      ])

    render_upload(upload, "private-a.png")
    switch.(b["id"])
    assert render(view) =~ "Unsent image uploads were removed"
    refute render(view) =~ "private-a.png"
    view |> form("#composer", %{text: "Only B"}) |> render_submit()
    {:ok, b_chat} = Vega.Bots.get_session(b["id"], ctx.opts)
    assert List.last(b_chat["messages"])["images"] == []
    switch.(a["id"])

    upload =
      file_input(view, "#composer", :images, [
        %{name: "retry-a.png", content: png, type: "image/png"}
      ])

    render_upload(upload, "retry-a.png")
    view |> form("#composer", %{text: String.duplicate("x", 32_001)}) |> render_submit()
    assert render(view) =~ "Image ready to resend"
    switch.(b["id"])
    refute render(view) =~ "Image ready to resend"
    view |> form("#composer", %{text: "Still only B"}) |> render_submit()
    {:ok, b_chat} = Vega.Bots.get_session(b["id"], ctx.opts)
    assert List.last(b_chat["messages"])["images"] == []
    switch.(a["id"])
    assert render(view) =~ "Image ready to resend"
    view |> form("#composer", %{text: "A with its own image"}) |> render_submit()
    {:ok, a_chat} = Vega.Bots.get_session(a["id"], ctx.opts)
    assert length(List.last(a_chat["messages"])["images"]) == 1
  end

  test "consumer faces and composer controls use font-independent graphics", ctx do
    {:ok, bot} = Vega.Bots.create_bot("Muse", ctx.opts)
    {:ok, _} = Vega.Bots.create_session([bot["id"]], ctx.opts)
    {:ok, view, _} = open(ctx.conn)
    view |> element("button[phx-click='open-session']") |> render_click()
    assert has_element?(view, "button[aria-label='New chat'] svg[aria-hidden='true']")
    assert has_element?(view, ".attach-button svg")
    assert has_element?(view, "button[aria-label='Voice input coming later'] svg")
    refute render(view) =~ "⌣"
    refute render(view) =~ "🎙"
    refute render(view) =~ "＋"
  end

  test "credential cards use only native password hook, never LiveView forms", ctx do
    {:ok, bot} = Vega.Bots.create_bot("Muse", ctx.opts)
    {:ok, chat} = Vega.Bots.create_session([bot["id"]], ctx.opts)

    {:ok, request} =
      Vega.Bots.request_setting(
        bot["id"],
        "OPENROUTER_API_KEY",
        "Connect the provider",
        ctx.opts ++ [session_id: chat["id"], requester: "credential-ui-test"]
      )

    {:ok, view, _} = open(ctx.conn)
    view |> element("button[phx-click='open-session']") |> render_click()
    card = "#request-#{request["id"]}"

    assert has_element?(
             view,
             "#{card} [phx-hook='BotsSetting'][data-endpoint='/bots/requests/#{request["id"]}/setting']"
           )

    assert has_element?(view, "#{card} input[type='password'][name='password']")
    assert has_element?(view, "#{card} button[type='button'][data-save-setting]")
    refute has_element?(view, "#{card} form")
    refute has_element?(view, "#{card} textarea")
    refute has_element?(view, "#{card} [phx-submit]")
    refute has_element?(view, "#{card} [phx-change]")
    refute has_element?(view, "#{card} input[type='password'][value]")
    refute has_element?(view, "form input[type='password']")
    assert has_element?(view, card, "Don’t paste credentials into the general chat")
    # Simulate only durable metadata acceptance, never a password or Settings mutation.
    {:ok, _} =
      GenServer.call(ctx.opts[:server], {:setting_answer, request["id"], "openrouter_api_key"})

    assert render(view) =~ "Credential openrouter_api_key saved."
    refute has_element?(view, "#{card} input[type='password']")
  end
end

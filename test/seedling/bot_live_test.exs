defmodule SeedlingWeb.BotLiveTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Seedling.Bots
  @endpoint NanoWeb.Endpoint
  setup do
    root = Path.join(Application.fetch_env!(:nano, :state_dir), "bots")
    name = {:global, {Bots.Store, root}}
    if old = GenServer.whereis(name), do: GenServer.stop(old)
    File.rm_rf!(root)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "test-owner"), :erlang.term_to_binary(self()))

    {:ok, server} =
      GenServer.start(Bots.Store, [root: root, runtime: Bots.TestRuntime, gate: Bots.TestGate],
        name: name
      )

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
      File.rm_rf!(root)
    end)

    %{conn: build_conn(), root: root}
  end

  test "create two distinct identities, choose chips, chat live as a group, no harness traffic",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/bots")
    assert has_element?(view, "#recipient-query")
    element(view, "button[phx-click=create]") |> render_click()

    form(view, "#create-bot", %{name: "Muse", description: "Travel", voice: "Thoughtful"})
    |> render_submit()

    assert has_element?(view, ".chip", "Muse")
    element(view, "button[phx-click=create]") |> render_click()

    form(view, "#create-bot", %{name: "Dots", description: "Creative", voice: "Playful"})
    |> render_submit()

    assert has_element?(view, ".chip", "Dots")
    element(view, "#start-chat") |> render_click()
    path = assert_patch(view)
    sid = URI.decode_query(URI.parse(path).query)["session"]
    assert has_element?(view, ".participant-pill", "Muse, Dots")
    form(view, "#chat-composer", %{text: "Hello both"}) |> render_submit()
    assert_receive {:delivered, bid, ^sid, _, _, pid}
    assert_receive {:delivered, _, ^sid, _, _, _}
    send(pid, {:post, self(), bid, sid, "**Hello** human. <script>alert(1)</script>", []})
    assert_receive {:posted, {:ok, _}}
    assert has_element?(view, ".bubble strong", "Hello")
    assert render(view) =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute render(view) =~ "<script>alert(1)</script>"
    refute has_element?(view, ".eval")
    assert has_element?(view, "textarea[name=text]", "")
    element(view, "#stop-chat") |> render_click()
    assert has_element?(view, ".system", "Paused")
    assert {:error, _} = Bots.post(bid, sid, "No forgery")
  end

  test "human request is visibly answerable, goes back to asking agent, notifications are bounded",
       ctx do
    {:ok, b} = Bots.create_bot("Helper")
    {:ok, s} = Bots.create_session([b["id"]])
    {:ok, view, _} = live(ctx.conn, "/bots?session=" <> s["id"])

    form(view, "#notification-limits", %{enabled: "true", per_hour: "1", cooldown_seconds: "0"})
    |> render_submit()

    {:ok, r} = Bots.ask_human(b["id"], "Which city?", reply_to: self(), correlation: "city")
    assert has_element?(view, "#answer-#{r["id"]}")

    request_id = r["id"]
    session_id = s["id"]

    assert_push_event(view, "bot-notify", %{
      id: ^request_id,
      title: "A bot needs you",
      body: "Which city?",
      session: ^session_id
    })

    form(view, "#answer-#{r["id"]}", %{answer: "Kyoto"}) |> render_submit()
    rid = r["id"]
    assert_receive {:bots_human_answer, ^rid, "city", "Kyoto"}
    assert has_element?(view, ".bubble", "Request answered")
    assert has_element?(view, ".human", "Kyoto")
    {:ok, _} = Bots.ack(rid)
    {:ok, next} = Bots.ask_human(b["id"], "Second request")
    refute next["notify"]
  end

  test "attachment is download-only with security headers; browser upload lifecycle works", ctx do
    {:ok, b} = Bots.create_bot("Helper")
    {:ok, s} = Bots.create_session([b["id"]])
    {:ok, view, _} = live(ctx.conn, "/bots?session=" <> s["id"])

    upload =
      file_input(view, "#chat-composer", :files, [
        %{name: "evil.html", content: "<script>fetch('/api/eval')</script>", type: "text/html"}
      ])

    assert render_upload(upload, "evil.html") =~ "evil.html"
    form(view, "#chat-composer", %{text: "Read only"}) |> render_submit()
    assert has_element?(view, "a.attachment", "evil.html")
    {:ok, page} = Bots.history(s["id"])
    file = hd(hd(page.messages)["attachments"])
    conn = get(ctx.conn, "/bots/files/" <> file)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/octet-stream"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "attachment"
    assert get_resp_header(conn, "content-security-policy") |> hd() =~ "sandbox"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    conn = get(ctx.conn, "/bots/files/unknown")
    assert conn.status == 404
  end

  test "unconfigured runtime gives a setup explanation rather than silent chat", ctx do
    # The real runtime refuses to choose a model implicitly, without any provider call.
    {:ok, b} = Bots.create_bot("New")
    {:ok, s} = Bots.create_session([b["id"]])

    assert {:error, e} =
             Bots.Runtime.deliver(b, s, %{"text" => "Hi", "attachments" => []}, [], %{}, ctx.root)

    assert e =~ "settings"
    {:ok, view, _} = live(ctx.conn, "/bots")
    element(view, "#bot-settings") |> render_click()
    assert has_element?(view, "#settings-panel", "Provider credentials stay in operator settings")
  end
end

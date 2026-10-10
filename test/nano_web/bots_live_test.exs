defmodule NanoWeb.BotsTestRouter do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
    plug :fetch_live_flash
  end

  scope "/" do
    pipe_through :browser
    live "/bots", NanoWeb.BotsLive
    live "/bots/:id", NanoWeb.BotsLive
  end
end

Application.put_env(:nano, NanoWeb.BotsTestEndpoint,
  debug_errors: true,
  secret_key_base: String.duplicate("b", 64),
  live_view: [signing_salt: "bots-ui-signing-salt"],
  pubsub_server: Nano.PubSub
)

defmodule NanoWeb.BotsTestEndpoint do
  use Phoenix.Endpoint, otp_app: :nano
  plug Plug.Session, store: :cookie, key: "bots-test", signing_salt: "bots-test"
  plug NanoWeb.BotsTestRouter
end

defmodule NanoWeb.BotsLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NanoWeb.BotsTestEndpoint
  setup do
    dir = Path.join(System.tmp_dir!(), "altair-bots-ui-#{System.unique_integer([:positive])}")
    store = start_supervised!({Nano.Bots.Store, name: nil, store_dir: dir, pubsub: Nano.PubSub})

    start_supervised!(
      {NanoWeb.BotsTestEndpoint,
       server: false,
       debug_errors: true,
       secret_key_base: String.duplicate("b", 64),
       live_view: [signing_salt: "bots-ui-signing-salt"],
       pubsub_server: Nano.PubSub}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    conn = build_conn() |> Plug.Test.init_test_session(%{"bots_server" => store})
    %{conn: conn, store: store}
  end

  test "creates a bot on the spot and routes a session, keyboard markup is accessible", %{
    conn: conn,
    store: store
  } do
    {:ok, v, html} = live(conn, "/bots")
    assert html =~ "role=\"combobox\""
    assert html =~ "phx-keydown=\"recipient_key\""
    v |> form("form[phx-change=query]", query: "Lumen") |> render_change()
    v |> element("button[phx-click=create_bot]") |> render_click()
    assert has_element?(v, ".recipient-chip", "Lumen")
    v |> element("button[phx-click=start_chat]") |> render_click()
    {:ok, [chat]} = Nano.Bots.list_sessions(server: store)
    assert_patch(v, "/bots/" <> chat.id)
    assert has_element?(v, ".participants-pill", "Lumen")
    v |> form("#bots-composer", text: "Hello Lumen") |> render_submit()
    assert has_element?(v, ".message.human", "Hello Lumen")
  end

  test "answers requests durably and edits visible memory; no operator traffic", %{
    conn: conn,
    store: store
  } do
    o = [server: store]
    {:ok, b} = Nano.Bots.create_bot(%{name: "Lumen"}, o)
    {:ok, c} = Nano.Bots.create_session(%{participant_ids: [b.id]}, o)

    {:ok, r} =
      Nano.Bots.request_human(
        %{bot_id: b.id, session_id: c.id, requester: "test-requester", text: "Which date?"},
        o
      )

    {:ok, m} =
      Nano.Bots.create_memory(b.id, %{text: "Likes tea", provenance: %{session_id: c.id}}, o)

    {:ok, v, html} = live(conn, "/bots/" <> c.id)
    refute html =~ "/api/eval"
    refute html =~ "tool_call"
    assert has_element?(v, ".human-request", "Which date?")
    v |> element("button[phx-click=answer]") |> render_click()
    v |> form("#bots-composer", text: "Tuesday") |> render_submit()
    assert {:ok, %{answer: "Tuesday", status: :answered}} = Nano.Bots.get_request(r.id, o)
    assert has_element?(v, ".message.human", "Tuesday")
    v |> element("button[phx-click=memory]") |> render_click()
    assert render(v) =~ "Provenance"
    v |> form("form[phx-submit=memory_save]", text: "Likes coffee") |> render_submit()
    assert {:ok, [%{text: "Likes coffee"}]} = Nano.Bots.list_memories(b.id, o)
    v |> element("button[phx-click=memory_delete]") |> render_click()
    assert {:ok, []} = Nano.Bots.list_memories(b.id, o)
    refute render(v) =~ m.id
    v |> element("button[phx-click=stop]") |> render_click()
    assert has_element?(v, "[role=status]", "Replies stopped")
  end

  test "group status and consumer-only pubsub updates survive reconnect", %{
    conn: conn,
    store: store
  } do
    o = [server: store]
    {:ok, a} = Nano.Bots.create_bot(%{name: "Aster"}, o)
    {:ok, b} = Nano.Bots.create_bot(%{name: "Briar"}, o)
    {:ok, c} = Nano.Bots.create_session(%{participant_ids: [a.id, b.id]}, o)
    {:ok, v, html} = live(conn, "/bots/" <> c.id)
    assert html =~ "Aster, Briar"

    {:ok, _} =
      Nano.Bots.post_human(c.id, %{text: "Both of you?", idempotency_key: "group-test"}, o)

    assert has_element?(v, ".message", "Both of you?")
    send(v.pid, {:bots, :runtime_status, %{session_id: c.id, bot_id: a.id, status: :thinking}})
    assert has_element?(v, "[role=status]", "Aster is thinking")
    send(v.pid, {:nano_log, %{type: "tool_call", text: "DO NOT SHOW EVAL"}})
    refute render(v) =~ "DO NOT SHOW EVAL"
    {:ok, reopened, _} = live(conn, "/bots/" <> c.id)
    assert has_element?(reopened, ".message", "Both of you?")
    v |> element("button[phx-click=notifications]") |> render_click()
    v |> form("#notification-limits", minutes: "10", hourly: "2") |> render_submit()

    assert {:ok, %{notification_prefs: %{min_interval_ms: 600_000, max_per_hour: 2}}} =
             Nano.Bots.get_session(c.id, o)
  end
end

defmodule NanoWeb.BotsLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Seedling.Bots
  @endpoint NanoWeb.Endpoint
  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    Supervisor.terminate_child(Nano.Supervisor, Bots)

    if pid = Process.whereis(Bots),
      do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

    old = Application.get_env(:nano, :bots_path)
    dispatch = Application.get_env(:nano, :bots_dispatch)
    path = Path.join(dir, "bots-8163.json")
    Application.put_env(:nano, :bots_path, path)
    Application.put_env(:nano, :bots_dispatch, fn _, _, _ -> :ok end)

    on_exit(fn ->
      if pid = Process.whereis(Bots),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      if old,
        do: Application.put_env(:nano, :bots_path, old),
        else: Application.delete_env(:nano, :bots_path)

      Supervisor.restart_child(Nano.Supervisor, Bots)

      if dispatch,
        do: Application.put_env(:nano, :bots_dispatch, dispatch),
        else: Application.delete_env(:nano, :bots_dispatch)
    end)

    if pid = Process.whereis(Bots),
      do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

    %{conn: build_conn()}
  end

  test "create identities and a shared conversation with safe text", %{conn: conn} do
    {:ok, view, _} = live(conn, "/bots")
    assert has_element?(view, "h2", "Welcome")
    view |> form("#bot-form", %{name: "Muse", description: "Calm <script>"}) |> render_submit()
    view |> form("#bot-form", %{name: "Dots", description: "Curious"}) |> render_submit()
    ids = Enum.map(Bots.bots(), & &1["id"])
    view |> form("#session-form", %{title: "Team", bots: ids}) |> render_submit()
    assert has_element?(view, "#chat-form")
    view |> form("#chat-form", %{text: "hello <img src=x onerror=alert(1)>"}) |> render_submit()
    [s] = Bots.sessions()
    assert length(s["bot_ids"]) == 2
    {:ok, _} = Bots.post(s["id"], hd(ids), "```elixir\n<script>alert(1)</script>\n```")
    html = render(view)
    assert html =~ "&lt;script&gt;"
    refute has_element?(view, "#chat-messages script")
    refute has_element?(view, "#chat-messages img")
    assert has_element?(view, "#chat-messages", "hello")
    GenServer.stop(view.pid)
  end

  test "live requests answer once, settings persist, bad selection stays safe", %{conn: conn} do
    {:ok, bot} = Bots.create_bot(%{name: "Muse"})
    {:ok, s} = Bots.create_session([bot["id"]], %{title: "One"})
    {:ok, view, _} = live(conn, "/bots")
    render_click(view, "select", %{"id" => s["id"]})

    {:ok, req} =
      Bots.request_human(bot["id"], "Which colour?", session_id: s["id"], reply_to: self())

    assert render(view) =~ "Which colour?"
    view |> element("button", "Answer this request") |> render_click()
    view |> form("#chat-form", %{text: "Blue"}) |> render_submit()
    assert_receive {:bot_answer, id, "Blue"}
    assert id == req["id"]
    assert has_element?(view, "small", "Answered")
    render_click(view, "quiet", %{})
    assert Bots.session(s["id"])["settings"]["quiet"]
    render_click(view, "select", %{"id" => "missing"})
    assert has_element?(view, "h2", "Welcome")
    render_submit(view, "create_session", %{"title" => "Bad", "bots" => []})
    assert has_element?(view, "[role=alert]", "invalid_bots")
    GenServer.stop(view.pid)
  end
end

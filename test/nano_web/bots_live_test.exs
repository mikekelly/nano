defmodule NanoWeb.BotsLiveTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Seedling.{Bots, BotFiles, CapabilityStore}
  @endpoint NanoWeb.Endpoint
  defp create(name) do
    {:ok, b} = Bots.create(name, model: "fake/model", reasoning: "off", max_context: 20000)
    b
  end

  test "consumer creation, recipient chips/group chat and human composer without evals" do
    name = "Muse-" <> CapabilityStore.id()
    {:ok, view, _} = live(build_conn(), "/bots")
    assert has_element?(view, "#bots-product")
    view |> element("button[phx-click='create-form']") |> render_click()

    view
    |> form("#create-bot", %{
      name: name,
      description: "Thoughtful friend",
      model: "fake/model",
      reasoning: "off",
      context: "20000"
    })
    |> render_submit()

    assert has_element?(view, ".bot-chip", name)
    second = create("Dots-" <> CapabilityStore.id())
    render(view)

    view
    |> element("button[phx-value-bot='#{second["id"]}'][phx-click='choose']")
    |> render_click()

    assert Enum.count(view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(".bot-chip")) ==
             2

    view |> form("#bot-recipients") |> render_submit()
    assert has_element?(view, ".bots-pill", name)

    view
    |> form("#bot-compose", %{text: "Hello friends <script>evil</script>"})
    |> render_submit()

    assert has_element?(
             view,
             "#bot-thread .bot-message.human",
             "Hello friends <script>evil</script>"
           )

    refute has_element?(view, "#bot-thread script")
    refute render(view) =~ "running_tool"
    refute render(view) =~ "tool_call"
  end

  test "answerable proactive requests show independent requester; safe downloads and clean live updates" do
    bot = create("RequestBot-" <> CapabilityStore.id())
    {:ok, chat} = Bots.session([bot["id"]])
    name = "requester-" <> CapabilityStore.id()
    :yes = Nano.Names.register_name({:agent, name}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, name}) end)
    {:ok, view, _} = live(build_conn(), "/bots?session=" <> chat["id"])

    {:ok, r} =
      Bots.request_human(bot["id"], "Which dates?", reply_to: self(), session: chat["id"])

    assert render(view) =~ "Which dates?"
    assert has_element?(view, "small", "Requested by #{name}")
    view |> form(".bot-request", %{answer: "Tomorrow", request: r["id"]}) |> render_submit()
    assert_receive %{type: :bot_human_answer, answer: "Tomorrow", request_id: id}
    assert id == r["id"]
    assert has_element?(view, "small", "answered")
    path = Path.join(System.tmp_dir!(), "orion-html-" <> CapabilityStore.id())
    File.write!(path, "<script>danger</script>")
    on_exit(fn -> File.rm(path) end)
    {:ok, file} = BotFiles.add(path, "danger.html")
    conn = get(build_conn(), "/bots/files/" <> file["id"])
    assert response(conn, 200) == "<script>danger</script>"
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    assert hd(get_resp_header(conn, "content-disposition")) =~ "attachment"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert response(get(build_conn(), "/bots/files/invalid"), 404) == "File not found"
  end
end

defmodule NanoWeb.BotsLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NanoWeb.Endpoint
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "lyra-bots-ui-" <> Base.url_encode64(:crypto.strong_rand_bytes(10), padding: false)
      )

    {:ok, pid} = Seedling.Bots.start_link(path: Path.join(dir, "bots.json"))

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(dir)
    end)

    :ok
  end

  test "compose group, switch session, escaped model output and human answer" do
    {:ok, b} = Seedling.Bots.create_bot("Muse")
    {:ok, c} = Seedling.Bots.create_bot("Dot")
    {:ok, view, html} = live(build_conn(), "/bots")
    assert html =~ "Who would you like"
    view |> element("button[data-bot-choice][phx-value-id='#{b.id}']") |> render_click()
    view |> element("button[data-bot-choice][phx-value-id='#{c.id}']") |> render_click()
    view |> element("button[phx-click=start]") |> render_click()
    s = Seedling.Bots.snapshot().sessions |> Map.values() |> hd()
    Seedling.Bots.post(s.id, b.id, "<script>evil()</script>")
    html = render(view)
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>evil"
    {:ok, r} = Seedling.Bots.request_human(b.id, "Choose", session: s.id)
    render(view)
    view |> element("form[phx-submit=answer]") |> render_submit(%{"request" => r, "text" => "A"})
    assert_receive {:human_answer, ^r, "A"}
    assert render(view) =~ "Answered: A"
  end
end

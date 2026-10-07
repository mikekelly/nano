defmodule NanoWeb.BotsLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NanoWeb.Endpoint
  test "consumer creates two bots and a group; model HTML cannot execute" do
    {:ok, view, _} = live(build_conn(), "/bots")
    suffix = System.unique_integer([:positive])
    view |> element("form[phx-change=filter]") |> render_change(%{"query" => "Ada#{suffix}"})
    view |> element("button[phx-click=create]") |> render_click()
    view |> element("form[phx-change=filter]") |> render_change(%{"query" => "Bea#{suffix}"})
    view |> element("button[phx-click=create]") |> render_click()
    assert has_element?(view, "button[phx-click=start]", "Create group chat")
    view |> element("button[phx-click=start]") |> render_click()
    data = Nano.Bots.snapshot()
    chat = data.sessions |> Map.values() |> Enum.find(&String.contains?(&1.title, "Ada#{suffix}"))

    assert :ok =
             Nano.Bots.post(
               chat.id,
               hd(chat.bots),
               "<script>alert('x')</script>\n```\nsecret_eval()\n```"
             )

    html = render(view)
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>alert"
    assert has_element?(view, ".code code", "secret_eval()")
    refute has_element?(view, "#timeline")
    source = Path.join(System.tmp_dir!(), "nova-bots-live-file-#{suffix}.txt")
    File.write!(source, "generated output")

    {:ok, file} =
      Nano.Bots.attach(chat.id, hd(chat.bots), source, filename: "<img onerror=alert(1)>.txt")

    File.rm!(source)
    render(view)
    assert has_element?(view, "a.file", file.filename)
    refute has_element?(view, "article img")
    assert render(view) =~ "&lt;img"

    {:ok, request} = Nano.Bots.ask_human(hd(chat.bots), "Which day?", session: chat.id)
    render(view)

    view
    |> element("form[phx-submit=answer]")
    |> render_submit(%{"request" => request, "text" => "Friday"})

    assert_receive {:nano_human_answer, ^request, "Friday"}
  end
end

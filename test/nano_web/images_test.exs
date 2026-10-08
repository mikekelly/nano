defmodule NanoWeb.ImagesTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn
  @endpoint NanoWeb.Endpoint
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURf8AAP///0EdNBEAAAABYktHRAH/Ai3eAAAAB3RJTUUH6goIDC8zUNkCFQAAAApJREFUCNdjYAAAAAIAAeIhvDMAAAAldEVYdGRhdGU6Y3JlYXRlADIwMjYtMTAtMDhUMTI6NDc6NTErMDA6MDAp2KFtAAAAJXRFWHRkYXRlOm1vZGlmeQAyMDI2LTEwLTA4VDEyOjQ3OjUxKzAwOjAwWIUZ0QAAACh0RVh0ZGF0ZTp0aW1lc3RhbXAAMjAyNi0xMC0wOFQxMjo0Nzo1MSswMDowMA+QOA4AAAAASUVORK5CYII="

  setup do
    Nano.FakeOpenRouter.start()

    model =
      Nano.FakeOpenRouter.model(%{"architecture" => %{"input_modalities" => ["text", "image"]}})

    name = "web-image-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Nano.Ops.start_agent(name, Nano.FakeOpenRouter.opts(model))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    %{model: model, name: name}
  end

  defp upload(name, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/agents/#{name}/images", Jason.encode!(body))
  end

  test "API uploads validated immutable images and returns the same bytes", c do
    Nano.FakeOpenRouter.push(c.model, text: "seen")
    conn = upload(c.name, %{base64: @png, text: "Look"})
    assert %{"image" => %{"id" => id, "mime" => "image/png"}} = json_response(conn, 200)
    conn = get(build_conn(), "/api/images/#{id}")
    assert response(conn, 200) == Base.decode64!(@png)
    assert hd(get_resp_header(conn, "content-type")) =~ "image/png"
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert json_response(upload(c.name, %{base64: "not base64"}), 422)["error"]
    assert json_response(upload(c.name, %{base64: @png, text: 1}), 422)["error"]
    assert json_response(get(build_conn(), "/api/images/invalid"), 404)["error"]
    refute inspect(Nano.Ops.log(c.name)) =~ @png
  end

  defp eventually(fun, tries \\ 100) do
    if fun.(),
      do: :ok,
      else:
        (
          assert tries > 0
          Process.sleep(20)
          eventually(fun, tries - 1)
        )
  end

  test "dashboard upload and both timeline views show the same immutable picture", c do
    Nano.FakeOpenRouter.push(c.model, text: "seen")
    {:ok, view, _html} = live(build_conn(), "/agents/#{c.name}")

    image =
      file_input(view, "#image-form", :image, [
        %{name: "red.png", content: Base.decode64!(@png), type: "image/png"}
      ])

    render_upload(image, "red.png")
    view |> form("#image-form", image_text: "Show red") |> render_submit()
    eventually(fn -> has_element?(view, "#timeline li.images img") end)
    assert has_element?(view, "#timeline li.images img[alt='Image attachment 1 × 1']")
    {:ok, debug, _} = live(build_conn(), "/agents/#{c.name}?view=debug")
    assert has_element?(debug, "#timeline li.images img")
    log = Nano.Ops.log(c.name)
    entry = Enum.find(log, &(&1["type"] == "images_received"))
    id = hd(entry["images"])["id"]
    assert has_element?(view, "img[src='/api/images/#{id}']")
    assert has_element?(debug, "img[src='/api/images/#{id}']")
  end
end

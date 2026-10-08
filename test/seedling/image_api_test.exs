defmodule Seedling.ImageApiTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NanoWeb.Endpoint

  test "upload, serve detected bytes safely, and say with references only" do
    bytes = Seedling.ImageFixture.png()

    ref =
      build_conn() |> post("/api/images", %{"data" => Base.encode64(bytes)}) |> json_response(201)

    assert ref["mime_type"] == "image/png"
    conn = build_conn() |> get("/api/images/" <> ref["id"])
    assert response(conn, 200) == bytes
    assert List.first(Plug.Conn.get_resp_header(conn, "content-type")) =~ "image/png"
    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    name = "image-user-#{System.unique_integer([:positive])}"
    Nano.User.start(name)
    body = %{"to" => inspect(self()), "text" => "look", "images" => [ref["id"]]}

    assert %{"ok" => true} =
             build_conn() |> post("/api/users/#{name}/say", body) |> json_response(200)

    assert_receive %{message: "look", images: [^ref]}
    assert [%{messages: [%{term: term}]}] = Nano.User.threads(name)

    assert [%{"images" => [^ref]}] =
             build_conn() |> get("/api/users/#{name}/threads/*") |> json_response(200)

    refute inspect(term) =~ "base64"

    assert %{"ok" => true} =
             build_conn()
             |> post("/api/users/#{name}/say", Map.put(body, "text", ""))
             |> json_response(200)

    assert_receive %{message: "", images: [^ref]}

    assert %{"error" => _} =
             build_conn()
             |> post("/api/users/#{name}/say", Map.put(body, "images", ["bad"]))
             |> json_response(422)
  end

  test "invalid uploads and references are JSON errors; messages render only local image ids" do
    assert %{"error" => _} =
             build_conn() |> post("/api/images", %{"data" => "not base64"}) |> json_response(422)

    assert %{"error" => _} =
             build_conn()
             |> post("/api/images", %{"data" => Base.encode64("<svg />")})
             |> json_response(422)

    assert %{"error" => _} = build_conn() |> get("/api/images/missing") |> json_response(404)
    {:ok, ref} = Seedling.Images.store(Seedling.ImageFixture.png())

    html =
      render_component(&NanoWeb.Components.message/1, term: %{message: "photo", images: [ref]})

    assert html =~ "/api/images/" <> ref["id"]
    refute html =~ "data:image"

    assert render_component(&Seedling.ImageComponents.images/1,
             refs: ["https://example.com/track", %{"id" => "../state"}]
           ) == ""
  end

  test "dashboard upload component sends an immutable reference and renders in message threads" do
    test = self()

    target =
      spawn(fn ->
        receive do
          term ->
            send(test, {:picture, term})
            Process.sleep(:infinity)
        end
      end)

    on_exit(fn -> if Process.alive?(target), do: Process.exit(target, :kill) end)
    {:ok, view, _} = live(build_conn(), "/?view=debug")
    pid_id = String.replace(inspect(target), ~r/\D+/, "-")
    view |> element("#p-#{pid_id} button[phx-click=open_send]") |> render_click()
    id = "#send#{pid_id}-images-form"
    assert has_element?(view, id)

    upload =
      file_input(view, id, :image, [
        %{name: "pixel.png", content: Seedling.ImageFixture.png(), type: "image/png"}
      ])

    assert render_upload(upload, "pixel.png") =~ "100%"
    view |> form(id, %{caption: "a red pixel"}) |> render_submit()
    assert_receive {:picture, %{message: "a red pixel", images: [ref]}}, 2000
    assert ref["mime_type"] == "image/png"
    {:ok, messages, html} = live(build_conn(), "/messages?user=dashboard&agent=*")
    assert html =~ "/api/images/" <> ref["id"]
    assert has_element?(messages, "img[src='/api/images/#{ref["id"]}']")
  end
end

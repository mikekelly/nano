defmodule NanoWeb.ImagesTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  @endpoint NanoWeb.Endpoint
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
       )

  setup do
    previous = Application.get_env(:nano, :images_dir)

    dir =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "web-images-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:nano, :images_dir, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nano, :images_dir, previous),
        else: Application.delete_env(:nano, :images_dir)

      File.rm_rf!(dir)
    end)

    :ok
  end

  defp post_json(path, params) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end

  defp upload(bytes, filename \\ "picture.png") do
    boundary = "nano-image-test-boundary"

    body =
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n" <>
        bytes <> "\r\n--#{boundary}--\r\n"

    build_conn()
    |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
    |> put_req_header("x-nano-upload", "1")
    |> post("/api/images", body)
  end

  test "multipart upload sniffs bytes and returns a reference, GET serves immutable safe bytes" do
    ref = upload(@png, "misleading.jpg") |> json_response(201)
    assert %{"type" => "image_ref", "mime" => "image/png", "width" => 1, "height" => 1} = ref
    assert ref["id"] == Base.encode16(:crypto.hash(:sha256, @png), case: :lower)
    conn = build_conn() |> get("/api/images/" <> ref["id"])
    assert response(conn, 200) == @png
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert upload(@png) |> json_response(201) == ref
  end

  test "upload requires custom header, actual upload, valid bytes and bounded body" do
    assert post_json("/api/images", %{file: "/etc/passwd"}) |> json_response(403)

    assert build_conn()
           |> put_req_header("x-nano-upload", "1")
           |> put_req_header("content-type", "application/json")
           |> post("/api/images", Jason.encode!(%{file: "/etc/passwd"}))
           |> json_response(422)

    assert upload("not an image") |> json_response(422)
    assert_error_sent 413, fn -> upload(:binary.copy("x", 4_000_001)) end
  end

  test "IDs never resolve local paths and missing images return 404" do
    for id <- ["etc-passwd", "..", String.duplicate("a", 64), String.duplicate("A", 64)] do
      assert build_conn() |> get("/api/images/" <> id) |> json_response(404)
    end

    refute NanoWeb.ImageInput.valid_id?("../etc/passwd")
    refute NanoWeb.ImageInput.valid_id?(nil)
  end

  test "input rejects malformed refs and canonicalizes metadata rather than trusting it" do
    {:ok, ref} = Images.ingest_bytes(@png)
    forged = Map.merge(ref, %{"mime" => "text/html", "width" => 999, "path" => "/etc/passwd"})

    assert {:ok, %{text: "look", images: [^ref]}} =
             NanoWeb.ImageInput.message(%{"text" => "look", "images" => [forged]})

    for params <- [
          %{},
          %{"text" => 123},
          %{"images" => "path"},
          %{"images" => ["/etc/passwd"]},
          %{"images" => [%{"type" => "image_ref", "id" => "../x"}]},
          %{"images" => List.duplicate(ref, 21)}
        ] do
      assert {:error, _} = NanoWeb.ImageInput.message(params)
    end

    assert post_json("/api/agents/not-running/message", %{images: [ref]}) |> json_response(404)

    assert post_json("/api/agents/not-running/message", %{images: ["/etc/passwd"]})
           |> json_response(422)
  end

  test "user say accepts image-only structured messages" do
    name = "image-user-#{System.unique_integer([:positive])}"
    pid = Nano.User.start(name)
    on_exit(fn -> DynamicSupervisor.terminate_child(Nano.UserSupervisor, pid) end)
    {:ok, ref} = Images.ingest_bytes(@png)

    assert post_json("/api/users/#{name}/say", %{to: inspect(self()), images: [ref]})
           |> json_response(200) == %{"ok" => true}

    assert_receive %{sender_pid: ^pid, message: %{text: "", images: [^ref]}}
  end

  test "message endpoint delivers canonical refs to a running agent" do
    Nano.FakeOpenRouter.start()
    name = "image-api-agent-#{System.unique_integer([:positive])}"
    {:ok, pid} = Nano.Ops.start_agent(name, Nano.FakeOpenRouter.opts(Nano.FakeOpenRouter.model()))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    :ok = :sys.suspend(pid)
    {:ok, ref} = Images.ingest_bytes(@png)
    forged = Map.put(ref, "mime", "text/html")

    assert post_json("/api/agents/#{name}/message", %{text: "look", images: [forged]})
           |> json_response(200) == %{"ok" => true}

    assert {:messages, messages} = Process.info(pid, :messages)
    assert {:"$gen_cast", {:notify, %{text: "look", images: [ref]}}} in messages
    :ok = :sys.resume(pid)
  end

  test "gallery links safe IDs only without embedding bytes" do
    {:ok, ref} = Images.ingest_bytes(@png)
    html = render_component(&NanoWeb.ImageGallery.images/1, term: %{images: [ref, ref]})
    assert html =~ "/api/images/#{ref["id"]}"
    assert html =~ "loading=\"lazy\""
    refute html =~ "data:image"
    refute html =~ Base.encode64(@png)
    assert length(Regex.scan(~r/<img /, html)) == 1
  end

  test "agent dashboard upload composer and reading/debug timeline display structured images" do
    Nano.FakeOpenRouter.start()
    name = "image-agent-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Nano.Ops.start_agent(name, Nano.FakeOpenRouter.opts(Nano.FakeOpenRouter.model()))

    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    {:ok, ref} = Images.ingest_bytes(@png)
    {:ok, view, html} = live(build_conn(), "/agents/#{name}")
    assert html =~ "Send images"
    assert has_element?(view, "#image-composer input[type=file]")

    input =
      file_input(view, "#image-composer form", :pictures, [
        %{name: "tiny.png", content: @png, type: "image/png"}
      ])

    assert render_upload(input, "tiny.png") =~ "100%"

    assert view |> form("#image-composer form", %{text: "what is this?"}) |> render_submit() =~
             "Message sent"

    id = Nano.Ops.agent(name).id

    event = %{agent_id: id, seq: 999, type: "event_received", message: "look", images: [ref]}
    send(view.pid, {:nano_log, event})
    assert render(view) =~ "/api/images/#{ref["id"]}"
    {:ok, debug, _} = live(build_conn(), "/agents/#{name}?view=debug")
    send(debug.pid, {:nano_log, event})
    assert render(debug) =~ "/api/images/#{ref["id"]}"
  end
end

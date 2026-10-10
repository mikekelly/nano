defmodule NanoWeb.ImagesTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn
  @endpoint NanoWeb.Endpoint
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  setup do
    dir =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "images_ui_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    saved = Application.fetch_env(:nano, :image_dir)
    Application.put_env(:nano, :image_dir, dir)

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:nano, :image_dir, value)
        :error -> Application.delete_env(:nano, :image_dir)
      end

      File.rm_rf(dir)
    end)

    :ok
  end

  defp upload(bytes) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/images", Jason.encode!(%{base64: Base.encode64(bytes)}))
  end

  test "API imports validated bytes and serves an immutable image, rejecting unsafe hashes" do
    ref = upload(@png) |> json_response(201)
    assert ref["mime"] == "image/png"
    assert ref["width"] == 1 and ref["height"] == 1
    assert ref["image_ref"] =~ ~r/^[a-f0-9]{64}$/
    refute Map.has_key?(ref, "base64")
    conn = build_conn() |> get("/api/images/" <> ref["image_ref"])
    assert response(conn, 200) == @png
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    for hash <- ["bad", String.duplicate("0", 64), "%2E%2E%2Fsecret"] do
      assert build_conn() |> get("/api/images/" <> hash) |> json_response(404)
    end

    assert upload("not an image") |> json_response(422)

    for encoded <- ["not-base64!", String.duplicate("A", 5_000_001)] do
      conn = build_conn() |> put_req_header("content-type", "application/json")
      assert conn |> post("/api/images", Jason.encode!(%{base64: encoded})) |> json_response(422)
    end
  end

  test "image say validates and stores only canonical refs" do
    ref = upload(@png) |> json_response(201)
    name = "images_user_#{System.unique_integer([:positive])}"
    user = Nano.User.start(name)
    on_exit(fn -> DynamicSupervisor.terminate_child(Nano.UserSupervisor, user) end)
    conn = build_conn() |> put_req_header("content-type", "application/json")

    conn
    |> post(
      "/api/users/#{name}/say",
      Jason.encode!(%{
        to: inspect(self()),
        text: "look",
        images: [Map.put(ref, "base64", "never store this")]
      })
    )
    |> json_response(200)

    assert_receive %{sender_pid: ^user, message: %{text: "look", images: [canonical]}}
    assert canonical.image_ref == ref["image_ref"]
    refute Map.has_key?(canonical, "base64")
    [thread] = Nano.User.threads(name)
    refute inspect(thread) =~ "never store this"

    assert {:error, :invalid_image} =
             Nano.User.say(name, self(), %{text: "bad", images: [%{image_ref: "../../secret"}]})
  end

  test "dashboard fake upload sends refs and timeline renders event and eval thumbnails" do
    Nano.FakeOpenRouter.start()
    model = Nano.FakeOpenRouter.model()
    name = "images_agent_#{System.unique_integer([:positive])}"
    {:ok, _} = Nano.Ops.start_agent(name, Nano.FakeOpenRouter.opts(model))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    {:ok, view, html} = live(build_conn(), "/agents/#{name}")
    assert html =~ "type=\"file\""

    input =
      file_input(view, "#send-text", :images, [
        %{name: "pixel.png", content: @png, type: "image/png"}
      ])

    assert render_upload(input, "pixel.png") =~ "pixel.png"
    view |> form("#send-text", %{text: "look"}) |> render_submit()
    [thread] = Nano.User.threads("dashboard") |> Enum.filter(&(&1.agent == name))
    [%{term: %{message: %{text: "look", images: [ref]}}}] = thread.messages
    refute inspect(thread) =~ Base.encode64(@png)
    # Inject structured log fixtures, independent of the harness integration.
    id = Nano.Ops.agent(name).id
    now = DateTime.utc_now()

    send(
      view.pid,
      {:nano_log,
       %{
         agent_id: id,
         seq: 100_000,
         type: :event_received,
         at: now,
         message: "look",
         images: [ref]
       }}
    )

    assert render(view) =~ "/api/images/#{ref.image_ref}"

    send(
      view.pid,
      {:nano_log,
       %{
         agent_id: id,
         seq: 100_001,
         type: :tool_result,
         at: now,
         ok: true,
         result: "image",
         images: [ref]
       }}
    )

    assert has_element?(view, "#timeline .result img[src='/api/images/#{ref.image_ref}']")
    assert has_element?(view, "#timeline .event img[src='/api/images/#{ref.image_ref}']")
  end
end

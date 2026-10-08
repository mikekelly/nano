defmodule Nano.ImagesTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NanoWeb.Endpoint
  alias Nano.FakeOpenRouter, as: Fake

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
       )

  setup do
    dir = Path.join(System.tmp_dir!(), "lyra-images-#{System.unique_integer([:positive])}")
    old = Application.get_env(:nano, :image_dir)
    Application.put_env(:nano, :image_dir, dir)

    on_exit(fn ->
      if old,
        do: Application.put_env(:nano, :image_dir, old),
        else: Application.delete_env(:nano, :image_dir)

      File.rm_rf!(dir)
    end)

    Fake.start()
    :ok
  end

  test "immutable refs, type detection, dimensions, size, safe paths and hydration" do
    assert {:ok, ref} = Nano.Images.store(@png)
    assert {:ok, ^ref} = Nano.Images.store(@png)
    assert ref["mime"] == "image/png"
    assert {:ok, @png, "image/png"} = Nano.Images.fetch(ref["id"])
    assert {:error, _} = Nano.Images.fetch("../secret")
    assert {:error, _} = Nano.Images.store("not an image")
    assert {:error, _} = Nano.Images.store(String.duplicate("x", 3_500_001))
    <<prefix::binary-size(16), _w::32, _h::32, tail::binary>> = @png
    assert {:error, _} = Nano.Images.store(<<prefix::binary, 8001::32, 1::32, tail::binary>>)
    [message] = Nano.Images.expand([%{"role" => "user", "content" => [ref]}])

    assert hd(message["content"])["image_url"]["url"] ==
             "data:image/png;base64," <> Base.encode64(@png)

    refute Jason.encode!(ref) =~ "base64"
  end

  test "real agent request sees image parts, logs refs and keeps accounting bounded" do
    model = Fake.model(%{"architecture" => %{"input_modalities" => ["text", "image"]}})
    name = "image-#{System.unique_integer([:positive])}"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model))

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
      Nano.StateStore.delete(name)
    end)

    Fake.push(model, calls: [idle: nil])
    assert {:ok, ref} = Nano.Images.send(pid, "a pixel", @png)
    assert_receive {:openrouter_request, ^model, body}, 2000
    assert Enum.any?(List.last(body["messages"])["content"], &(&1["type"] == "image_url"))
    state = :sys.get_state(pid)
    assert inspect(state.transcript) =~ ref["id"]
    refute inspect(state.transcript) =~ "base64"
    assert state.system_prompt =~ "Your model can see images"
    assert body["max_tokens"] > 900_000
    log = Nano.Log.read(NanoAgent.info(name).id)
    assert Enum.any?(log, &(&1["type"] == "image_received" and &1["visible_to_model"]))
    refute Jason.encode!(log) =~ Base.encode64(@png)
  end

  test "eval viewing local image delivers it after tool result in a user message" do
    model = Fake.model(%{"architecture" => %{"input_modalities" => ["text", "image"]}})
    name = "image-eval-#{System.unique_integer([:positive])}"
    path = Path.join(Application.fetch_env!(:nano, :image_dir), "local.png")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @png)
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model))

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
      Nano.StateStore.delete(name)
    end)

    Fake.push(model, calls: [eval: "Nano.Images.view(#{inspect(path)}, me)"])
    Fake.push(model, calls: [idle: nil])
    send(pid, :look)
    assert_receive {:openrouter_request, ^model, _}, 2000
    assert_receive {:openrouter_request, ^model, body}, 2000
    assert List.last(body["messages"])["role"] == "user"
    assert Enum.any?(List.last(body["messages"])["content"], &(&1["type"] == "image_url"))
    assert Enum.any?(body["messages"], &(&1["role"] == "tool"))

    assert Enum.all?(
             Enum.filter(body["messages"], &(&1["role"] == "tool")),
             &is_binary(&1["content"])
           )
  end

  test "nonvision agent receives explicit warning, never image bytes" do
    model = Fake.model()
    name = "nonvision-#{System.unique_integer([:positive])}"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model))

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
      Nano.StateStore.delete(name)
    end)

    Fake.push(model, calls: [idle: nil])
    assert {:ok, _} = Nano.Images.send(pid, "a pixel", @png)
    assert_receive {:openrouter_request, ^model, body}, 2000
    assert inspect(body["messages"]) =~ "Your model cannot see this image"
    refute inspect(body["messages"]) =~ "image_url"
  end

  test "dashboard upload displays same image in timeline" do
    model = Fake.model()
    name = "image-ui-#{System.unique_integer([:positive])}"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model))

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
      Nano.StateStore.delete(name)
    end)

    Fake.push(model, calls: [idle: nil])
    {:ok, view, _} = live(build_conn(), "/agents/#{name}")

    upload =
      file_input(view, "#image-upload", :image, [
        %{name: "pixel.png", content: @png, type: "image/png"}
      ])

    render_upload(upload, "pixel.png")
    view |> form("#image-upload", %{text: "known pixel"}) |> render_submit()
    assert_receive {:openrouter_request, ^model, _}, 2000
    Process.sleep(20)
    html = render(view)
    assert html =~ "known pixel"
    assert html =~ "/api/images/"
    assert html =~ "This model cannot see images"
  end

  test "API accepts upload, and serves exactly stored bytes" do
    import Phoenix.ConnTest
    model = Fake.model()
    name = "image-api-#{System.unique_integer([:positive])}"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model))

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
      Nano.StateStore.delete(name)
    end)

    conn = build_conn() |> put_req_header("content-type", "application/json")

    conn =
      dispatch(
        conn,
        NanoWeb.Endpoint,
        :post,
        "/api/agents/#{name}/images",
        Jason.encode!(%{base64: Base.encode64(@png)})
      )

    assert %{"image" => ref} = json_response(conn, 201)
    conn = dispatch(build_conn(), NanoWeb.Endpoint, :get, "/api/images/#{ref["id"]}", nil)
    assert response(conn, 200) == @png
    assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
  end
end

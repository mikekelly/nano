defmodule Vega.ImagesIntegrationTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn
  alias Nano.FakeOpenRouter, as: Fake
  @endpoint NanoWeb.Endpoint

  defp png, do: Nano.ImageFixture.png(10, 10)

  defp post_json(path, body),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp wait(fun, n \\ 100)
  defp wait(fun, 0), do: assert(fun.())

  defp wait(fun, n),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(20)
            wait(fun, n - 1)
          )
      )

  defp start_agent(vision?) do
    Fake.start()
    modalities = if vision?, do: ["text", "image"], else: ["text"]
    model = Fake.model(%{"architecture" => %{"input_modalities" => modalities}})
    name = "images-#{System.unique_integer([:positive])}"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    {name, pid, model}
  end

  test "API upload/say hydrates vision user parts, persisted state and logs keep refs" do
    {name, pid, model} = start_agent(true)
    ref = post_json("/api/images", %{data: Base.encode64(png())}) |> json_response(201)
    conn = build_conn() |> get("/api/images/" <> ref["id"])
    assert conn.resp_body == png()
    assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
    user = "image-user-#{System.unique_integer([:positive])}"
    user_pid = Nano.User.start(user)
    on_exit(fn -> DynamicSupervisor.terminate_child(Nano.UserSupervisor, user_pid) end)
    Fake.push(model, text: "saw it")

    assert post_json("/api/users/#{user}/say", %{to: name, text: "what?", images: [ref]})
           |> json_response(200) == %{"ok" => true}

    assert_receive {:openrouter_request, ^model, body}, 2000

    assert [
             %{"role" => "system"},
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "text"},
                 %{"type" => "image_url", "image_url" => %{"url" => url}}
               ]
             }
           ] = body["messages"]

    assert url == "data:image/png;base64," <> Base.encode64(png())
    wait(fn -> NanoAgent.info(name).status == :idle end)
    state = Nano.StateStore.get(name)
    assert state.input_modalities == ["text", "image"]
    assert NanoAgent.info(name).system_prompt =~ "can see image attachments"
    assert [%{"role" => "user", "content" => [_, ^ref]} | _] = state.transcript
    refute inspect(state) =~ Base.encode64(png())
    logs = Nano.Log.read(state.id)
    assert Enum.find(logs, &(&1["type"] == "event_received"))["images"] == [ref]
    refute Jason.encode!(logs) =~ Base.encode64(png())
    Process.exit(pid, :operator_restart)
    wait(fn -> NanoAgent.whereis(name) not in [nil, pid] end)
    assert NanoAgent.info(name).input_modalities == ["text", "image"]
  end

  test "dashboard file upload delivers pixels and renders the same immutable timeline image" do
    {name, _, model} = start_agent(true)
    existing = Nano.User.pid("dashboard")

    on_exit(fn ->
      if is_nil(existing) and not is_nil(Nano.User.pid("dashboard")),
        do: DynamicSupervisor.terminate_child(Nano.UserSupervisor, Nano.User.pid("dashboard"))
    end)

    {:ok, view, _} = live(build_conn(), "/agents/#{name}")

    upload =
      file_input(view, "#image-message", :images, [
        %{name: "attachment.png", content: png(), type: "image/png"}
      ])

    assert render_upload(upload, "attachment.png") =~ "attachment.png"
    Fake.push(model, text: "visible")
    view |> form("#image-message", %{text: "identify it"}) |> render_submit()
    assert_receive {:openrouter_request, ^model, body}, 2000

    assert Enum.any?(body["messages"], fn m ->
             is_list(m["content"]) and Enum.any?(m["content"], &(&1["type"] == "image_url"))
           end)

    wait(fn -> NanoAgent.info(name).status == :idle end)
    html = render(view)
    assert html =~ "alt=\"Image attachment\""
    assert html =~ "/api/images/"
  end

  test "legacy state looks up missing modalities once and persists through restart" do
    {name, pid, _model} = start_agent(true)

    s =
      Nano.StateStore.get(name)
      |> Map.drop([:input_modalities, :input_modalities_version, :pending_images, :tool_images])

    Nano.StateStore.put(name, s)
    Process.exit(pid, :operator_restart)
    wait(fn -> NanoAgent.whereis(name) not in [nil, pid] end)
    assert NanoAgent.info(name).input_modalities == ["text", "image"]
    assert NanoAgent.info(name).system_prompt =~ "can see image attachments"
  end

  test "pre-schema text-only placeholder upgrades once at runtime and survives catalog outage" do
    {name, pid, model} = start_agent(true)

    :sys.replace_state(pid, fn s ->
      s |> Map.put(:input_modalities, ["text"]) |> Map.delete(:input_modalities_version)
    end)

    Fake.push(model, text: "migrated")
    NanoAgent.notify(name, :upgrade)
    assert_receive {:openrouter_request, ^model, _}, 2000
    wait(fn -> NanoAgent.info(name).status == :idle end)
    assert NanoAgent.info(name).input_modalities == ["text", "image"]
    assert NanoAgent.info(name).system_prompt =~ "can see image attachments"
    assert Nano.StateStore.get(name).input_modalities_version == 1
    # A later catalog with the same slug but no vision must not change recorded capability.
    Fake.models([
      %{
        "id" => model,
        "context_length" => 1_000_000,
        "architecture" => %{"input_modalities" => ["text"]},
        "reasoning" => %{"supported_efforts" => []}
      }
    ])

    :persistent_term.erase({Nano.OpenRouter, :models})
    Fake.push(model, text: "stable")
    NanoAgent.notify(name, :next)
    assert_receive {:openrouter_request, ^model, _}, 2000
    wait(fn -> NanoAgent.info(name).status == :idle end)
    assert NanoAgent.info(name).input_modalities == ["text", "image"]
    Fake.models(500)
    :persistent_term.erase({Nano.OpenRouter, :models})
    Process.exit(pid, :operator_restart)
    wait(fn -> NanoAgent.whereis(name) not in [nil, pid] end)
    assert NanoAgent.info(name).input_modalities == ["text", "image"]
    assert Nano.StateStore.get(name).input_modalities_version == 1
  end

  test "eval views follow every tool output, not mixed into tool content" do
    {name, _, model} = start_agent(true)

    path =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "eval-image-#{System.unique_integer([:positive])}.png"
      )

    File.write!(path, png())
    Fake.push(model, calls: [eval: "Vega.Images.view(#{inspect(path)})", eval: "1+1"])
    Fake.push(model, text: "done")
    NanoAgent.notify(name, :look)
    assert_receive {:openrouter_request, ^model, _}, 2000
    assert_receive {:openrouter_request, ^model, body}, 2000

    assert [
             %{"role" => "system"},
             %{"role" => "user"},
             %{"role" => "assistant"},
             %{"role" => "tool", "content" => a},
             %{"role" => "tool", "content" => "2"},
             %{"role" => "user", "content" => [_, %{"type" => "image_url"}]}
           ] = body["messages"]

    assert is_binary(a)
    wait(fn -> NanoAgent.info(name).status == :idle end)
    state = Nano.StateStore.get(name)

    assert [%{"images" => [_]}] =
             Enum.filter(
               Nano.Log.read(state.id),
               &(&1["type"] == "tool_result" and &1["images"] != [])
             )

    refute inspect(state) =~ Base.encode64(png())
  end

  test "nonvision receives explicit notice and no pixels" do
    {name, _, model} = start_agent(false)
    {:ok, ref} = Vega.Images.import_bytes(png())
    Fake.push(model, text: "I cannot see it")
    NanoAgent.notify(name, %{message: "look", images: [ref]})
    assert_receive {:openrouter_request, ^model, body}, 2000

    assert [
             %{"role" => "system"},
             %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
           ] = body["messages"]

    assert text =~ "cannot see"
    refute Jason.encode!(body) =~ "data:image"
  end
end

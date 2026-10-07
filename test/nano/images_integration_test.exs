defmodule Vega.ImagesIntegrationTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  alias Nano.FakeOpenRouter, as: Fake
  @endpoint NanoWeb.Endpoint

  defp png, do: <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", 10::32, 10::32, 8, 2, 0, 0, 0>>

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

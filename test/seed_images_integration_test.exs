defmodule SeedImagesIntegrationTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn
  alias Nano.FakeOpenRouter, as: Fake
  @endpoint NanoWeb.Endpoint

  setup do
    Fake.start()
    name = "images-#{System.unique_integer([:positive])}"
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    %{name: name}
  end

  defp png do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6qS8AAAAASUVORK5CYII="
    )
  end

  defp start!(ctx, modalities \\ ["text", "image"]) do
    model = Fake.model(%{"architecture" => %{"input_modalities" => modalities}})
    Fake.listen(model)
    {:ok, pid} = Nano.Ops.start_agent(ctx.name, Fake.opts(model))
    {model, pid}
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition not met")

      true ->
        Process.sleep(20)
        eventually(fun, tries - 1)
    end
  end

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  test "API uploads reach actual OpenRouter wire; state and all logs have refs, operators see same bytes",
       ctx do
    {model, pid} = start!(ctx)
    assert NanoAgent.info(ctx.name).input_modalities == ["text", "image"]
    assert NanoAgent.info(ctx.name).system_prompt =~ "can see images"
    Fake.push(model, text: "seen")

    response =
      post_json("/api/users/dashboard/say", %{
        to: ctx.name,
        text: "Look",
        images: [%{data: Base.encode64(png())}]
      })

    assert json_response(response, 200)["ok"]
    assert_receive {:openrouter_request, ^model, body}, 2_000
    assert [_, %{"role" => "user", "content" => parts}] = body["messages"]
    assert [%{"image_url" => %{"url" => url}}] = Enum.filter(parts, &(&1["type"] == "image_url"))
    assert url == "data:image/png;base64," <> Base.encode64(png())
    eventually(fn -> NanoAgent.info(ctx.name).status == :idle end)
    s = :sys.get_state(pid)
    refute inspect(s.transcript) =~ "base64"
    refute inspect(s.pending) =~ "base64"
    entries = Nano.Ops.log(ctx.name, 0)
    refute Jason.encode!(entries) =~ Base.encode64(png())
    event = Enum.find(entries, &(&1["type"] == "event_received"))
    [ref] = event["images"]
    request = Enum.find(entries, &(&1["type"] == "model_request"))
    assert request["approx_input_tokens"] > 4800
    assert request["approx_input_tokens"] < 12000
    path = "/api/agents/#{ctx.name}/images/#{ref["sha256"]}"
    conn = build_conn() |> get(path)
    assert response(conn, 200) == png()
    assert get_resp_header(conn, "content-type") == ["image/png"]

    assert build_conn()
           |> get("/api/agents/#{ctx.name}/images/" <> String.duplicate("0", 64))
           |> json_response(404)

    {:ok, view, _} = live(build_conn(), "/agents/#{ctx.name}")
    assert has_element?(view, "#timeline img[src='#{path}']")

    [thread_message] =
      build_conn() |> get("/api/users/dashboard/threads/#{ctx.name}") |> json_response(200)

    assert [%{"url" => ^path, "mime" => "image/png"}] = thread_message["images"]

    {:ok, messages, _} =
      live(
        build_conn(),
        "/messages?user=dashboard&agent=#{ctx.name}"
      )

    assert has_element?(messages, "#thread img[src='#{path}']")
  end

  test "eval image follows tool results and prefix remains unchanged", ctx do
    {model, pid} = start!(ctx)
    path = Path.join(Application.fetch_env!(:nano, :test_dir), "#{ctx.name}.png")
    File.write!(path, png())
    Fake.push(model, calls: [eval: "SeedImages.view(#{inspect(path)})"])
    Fake.push(model, text: "seen")
    send(pid, :look)
    assert_receive {:openrouter_request, ^model, first}, 2_000
    assert_receive {:openrouter_request, ^model, second}, 2_000

    assert [
             %{"role" => "system"},
             %{"role" => "user"},
             %{"role" => "assistant"},
             %{"role" => "tool"},
             %{"role" => "user", "content" => parts}
           ] = second["messages"]

    assert Enum.any?(parts, &(&1["type"] == "image_url"))
    assert hd(second["messages"]) == hd(first["messages"])

    assert Enum.at(second["messages"], 1)["content"] ==
             hd(Enum.at(first["messages"], 1)["content"])["text"]

    eventually(fn -> NanoAgent.info(ctx.name).status == :idle end)
    assert :sys.get_state(pid).input_modalities == ["text", "image"]
    # Restart while the catalog no longer lists image support: persisted capability wins.
    Fake.models(500)
    Process.exit(pid, :operator_restart)
    eventually(fn -> (p = NanoAgent.whereis(ctx.name)) && p != pid end)
    assert NanoAgent.info(ctx.name).input_modalities == ["text", "image"]
    assert_receive {:openrouter_request, ^model, restarted}, 2_000

    assert Enum.any?(restarted["messages"], fn m ->
             is_list(m["content"]) && Enum.any?(m["content"], &(&1["type"] == "image_url"))
           end)

    Fake.push(model, text: "back")
  end

  test "unsupported model gets explicit warning, no image wire data", ctx do
    {model, pid} = start!(ctx, ["text"])
    {:ok, ref} = SeedImages.ingest_bytes(png())
    Fake.push(model, text: "unavailable")
    send(pid, {:seed_image, ref})
    assert_receive {:openrouter_request, ^model, body}, 2_000
    encoded = Jason.encode!(body)
    assert encoded =~ "does not support image input"
    refute encoded =~ "data:image"
    assert NanoAgent.info(ctx.name).system_prompt =~ "cannot see images"
  end

  test "dashboard file upload delivers images and renders them live", ctx do
    {model, _} = start!(ctx)
    Fake.push(model, text: "seen")
    {:ok, view, _} = live(build_conn(), "/agents/#{ctx.name}")

    upload =
      file_input(view, "#send-images", :images, [
        %{name: "picture.png", content: png(), type: "image/png"}
      ])

    assert render_upload(upload, "picture.png") =~ "picture.png"
    view |> form("#send-images", text: "Picture") |> render_submit()
    assert_receive {:openrouter_request, ^model, body}, 2_000
    assert Jason.encode!(body) =~ "data:image/png;base64"
    eventually(fn -> has_element?(view, "#timeline img") end)
    assert render(view) =~ "Image message sent"
  end

  test "invalid uploads never enter conversation", ctx do
    {model, _} = start!(ctx)

    conn =
      post_json("/api/users/dashboard/say", %{
        to: ctx.name,
        text: "bad",
        images: [%{data: Base.encode64("not an image")}]
      })

    assert json_response(conn, 422)["error"] =~ "Unsupported"
    refute_receive {:openrouter_request, ^model, _}, 50
    assert NanoAgent.info(ctx.name).budget.turns_used == 0
  end

  test "raw logs redact image payloads but outgoing bytes are exact", ctx do
    {model, pid} = start!(ctx)
    old = Nano.Settings.get(:raw_model_log)
    Nano.Settings.put(:raw_model_log, ctx.name)
    on_exit(fn -> Nano.Settings.put(:raw_model_log, old) end)
    Fake.push(model, text: "seen")
    {:ok, ref} = SeedImages.ingest_bytes(png())
    send(pid, {:seed_image, ref})
    assert_receive {:openrouter_request, ^model, body}, 2_000
    assert Jason.encode!(body) =~ Base.encode64(png())
    eventually(fn -> NanoAgent.info(ctx.name).status == :idle end)

    files =
      Path.wildcard(Path.join(Nano.RawLog.dir(), "#{NanoAgent.info(ctx.name).id}/*.request.txt"))

    assert files != []

    for file <- files do
      text = File.read!(file)
      refute text =~ Base.encode64(png())
      assert text =~ "image bytes omitted"
    end
  end

  test "Codex actual request contains input_image rather than text-wrapped content" do
    alias Nano.FakeChatGPT, as: Codex
    alias Nano.ChatGPT.Auth
    Codex.start()
    Codex.listen()
    Auth.logout()

    on_exit(fn ->
      Auth.logout()
      :persistent_term.erase({Nano.ChatGPT, :models})
    end)

    Codex.auth(:poll, [{200, :approved}])
    Codex.auth(:token, [{200, Codex.tokens()}])
    assert %{status: :pending} = Auth.login()
    eventually(fn -> Auth.status().status == :connected end)
    model = Codex.model()

    Codex.models([
      %{"slug" => model, "context_window" => 272_000, "input_modalities" => ["text", "image"]}
    ])

    :persistent_term.erase({Nano.ChatGPT, :models})

    assert {:ok, %{input_modalities: ["text", "image"]}} =
             Nano.Model.lookup("openai-codex/" <> model)

    {:ok, ref} = SeedImages.ingest_bytes(png())

    messages = [
      %{"role" => "system", "content" => "Look"},
      %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => "Picture"}, SeedImages.part(ref)]
      }
    ]

    Codex.push(model, text: "seen")

    assert {:ok, _} =
             Nano.Model.chat("openai-codex/" <> model, messages, [], "low", nil, ["text", "image"])

    assert_receive {:chatgpt_request, ^model, body, _}, 2_000

    assert [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => "Picture"},
                 %{"type" => "input_image", "image_url" => url}
               ]
             }
           ] = body["input"]

    assert url == "data:image/png;base64," <> Base.encode64(png())
  end
end

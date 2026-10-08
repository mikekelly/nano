defmodule Seedling.ImageLifecycleTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NanoWeb.Endpoint
  alias Nano.FakeOpenRouter, as: Fake
  alias Seedling.Images

  defp start_agent(opts \\ []) do
    Fake.start()
    modalities = Keyword.get(opts, :modalities, ["text", "image"])
    model = Fake.model(%{"architecture" => %{"input_modalities" => modalities}})
    name = "image-life-#{System.unique_integer([:positive])}"
    agent_opts = Fake.opts(model, Keyword.drop(opts, [:modalities]))
    Fake.listen(model)
    {:ok, pid} = NanoAgent.start([name: name] ++ agent_opts)
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    %{name: name, pid: pid, model: model, id: NanoAgent.info(name).id}
  end

  defp request(ctx) do
    assert_receive {:openrouter_request, model, body}, 3000
    assert model == ctx.model
    body
  end

  defp text(%{"content" => text}) when is_binary(text), do: text
  defp text(%{"content" => parts}), do: Enum.find_value(parts, "", & &1["text"])

  defp image_urls(body) do
    for message <- body["messages"],
        is_list(message["content"]),
        %{"type" => "image_url", "image_url" => %{"url" => url}} <- message["content"],
        do: url
  end

  defp eventually(fun, tries \\ 150) do
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

  defp entry(ctx, type) do
    eventually(fn -> Enum.any?(Nano.Log.read(ctx.id), &(&1["type"] == type)) end)
    Nano.Log.read(ctx.id) |> Enum.filter(&(&1["type"] == type)) |> List.last()
  end

  test "event bytes remain immutable, capabilities survive restart without a model list, and no image data is persisted" do
    ctx = start_agent()
    {:ok, ref} = Images.store(Seedling.ImageFixture.png())
    {:ok, url} = Images.data_url(ref)
    assert NanoAgent.info(ctx.name).system_prompt =~ "You can see attached images"
    Fake.push(ctx.model, text: "seen")
    send(ctx.pid, %{message: "look", images: [ref]})
    assert image_urls(request(ctx)) == [url]
    eventually(fn -> NanoAgent.info(ctx.name).status == :idle end)
    saved = Nano.StateStore.get(ctx.name)
    assert saved.input_modalities == ["text", "image"]
    assert hd(saved.transcript)["images"] == [ref]
    refute :erlang.term_to_binary(saved) =~ "data:image"
    log = File.read!(Path.join(Application.fetch_env!(:nano, :log_dir), ctx.id <> ".jsonl"))
    refute log =~ Base.encode64(Seedling.ImageFixture.png())
    assert entry(ctx, "event_received")["images"] == [ref]
    # Restart should use saved capabilities, not infer them from a fresh provider list.
    Fake.models(500)
    :persistent_term.erase({Nano.OpenRouter, :models})
    assert :ok = Nano.Ops.restart_agent(ctx.name)

    eventually(fn ->
      (info = NanoAgent.info(ctx.name)) && info.pid != ctx.pid && info.restart_count == 1
    end)

    assert NanoAgent.info(ctx.name).input_modalities == ["text", "image"]
    Fake.push(ctx.model, text: "again")
    NanoAgent.notify(ctx.name, :again)
    assert image_urls(request(ctx)) == [url]
  end

  test "eval image results arrive after the whole OpenRouter tool batch, not in tool content" do
    ctx = start_agent()
    path = Path.join(Application.fetch_env!(:nano, :test_dir), "view-#{ctx.id}.png")
    File.write!(path, Seedling.ImageFixture.png())

    Fake.push(ctx.model,
      calls: [eval: "picture = Seedling.Images.view(#{inspect(path)})", eval: "1 + 1"]
    )

    Fake.push(ctx.model, text: "seen")
    send(ctx.pid, :inspect_picture)
    request(ctx)
    body = request(ctx)

    assert Enum.map(body["messages"], & &1["role"]) == [
             "system",
             "user",
             "assistant",
             "tool",
             "tool",
             "user"
           ]

    assert [url] = image_urls(body)
    assert url == "data:image/png;base64," <> Base.encode64(Seedling.ImageFixture.png())
    eventually(fn -> NanoAgent.info(ctx.name).status == :idle end)
    results = Enum.filter(Nano.Log.read(ctx.id), &(&1["type"] == "tool_result"))
    assert length(hd(results)["images"]) == 1
    assert Enum.all?(results, &(not String.contains?(&1["result"], "base64")))
    saved = Nano.StateStore.get(ctx.name)

    assert saved.transcript
           |> Enum.filter(&(&1["role"] == "tool"))
           |> hd()
           |> Map.fetch!("images")
           |> length() == 1
  end

  test "a context stop accounts for image tokens, not base64 bytes or only a tiny reference" do
    ctx = start_agent(max_context: 4900, system_prompt: "short")
    {:ok, ref} = Images.store(Seedling.ImageFixture.png())
    send(ctx.pid, %{image: ref})
    eventually(fn -> NanoAgent.info(ctx.name).halted == :context end)
    refute_receive {:openrouter_request, _, _}, 100
    exhausted = entry(ctx, "budget_exhausted")
    assert exhausted["estimate"] >= 4800
    assert exhausted["estimate"] < 20_000
  end

  test "Codex agent lifecycle hydrates event and eval images into their distinct Responses positions" do
    alias Nano.FakeChatGPT, as: Codex
    Codex.start()
    Codex.listen()
    Nano.ChatGPT.Auth.logout()
    Codex.auth(:poll, [{200, :approved}])
    assert %{status: :pending} = Nano.ChatGPT.Auth.login()
    eventually(fn -> Nano.ChatGPT.Auth.status().status == :connected end)
    model = "image-codex-#{System.unique_integer([:positive])}"

    Codex.models([
      %{
        "slug" => model,
        "context_window" => 272_000,
        "input_modalities" => ["text", "image"],
        "supported_reasoning_levels" => [%{"effort" => "none"}],
        "default_reasoning_level" => "none"
      }
    ])

    :persistent_term.erase({Nano.ChatGPT, :models})
    name = "image-life-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      NanoAgent.start([name: name] ++ Fake.opts("openai-codex/" <> model, max_context: 100_000))

    on_exit(fn ->
      Nano.Ops.stop_agent(name)
      Nano.ChatGPT.Auth.logout()
      :persistent_term.erase({Nano.ChatGPT, :models})
    end)

    {:ok, ref} = Images.store(Seedling.ImageFixture.png())
    {:ok, url} = Images.data_url(ref)
    Codex.push(model, calls: [eval: "{:ok, #{inspect(ref)}}"])
    Codex.push(model, text: "seen")
    send(pid, %{message: "look", image: ref})
    assert_receive {:chatgpt_request, ^model, first, _}, 3000

    assert [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [_, %{"type" => "input_image", "image_url" => ^url}]
             }
           ] = first["input"]

    assert_receive {:chatgpt_request, ^model, second, _}, 3000

    assert [
             _,
             %{"type" => "function_call"},
             %{
               "type" => "function_call_output",
               "output" => [_, %{"type" => "input_image", "image_url" => ^url}]
             }
           ] = second["input"]

    eventually(fn -> NanoAgent.info(name).status == :idle end)
    refute :erlang.term_to_binary(Nano.StateStore.get(name)) =~ "base64"
  end

  test "dashboard upload reaches a vision model and renders the same immutable image in both timeline views" do
    ctx = start_agent()

    Fake.push(ctx.model,
      calls: [
        eval:
          "Seedling.Images.view(#{inspect(Path.join(Application.fetch_env!(:nano, :test_dir), "timeline-#{ctx.id}.png"))})"
      ]
    )

    Fake.push(ctx.model, text: "seen")

    File.write!(
      Path.join(Application.fetch_env!(:nano, :test_dir), "timeline-#{ctx.id}.png"),
      Seedling.ImageFixture.png()
    )

    {:ok, view, _} = live(build_conn(), "/agents/#{ctx.name}")

    upload =
      file_input(view, "#send-images-form", :image, [
        %{name: "picture.png", content: Seedling.ImageFixture.png(), type: "image/png"}
      ])

    render_upload(upload, "picture.png")
    view |> form("#send-images-form", %{caption: "look at this"}) |> render_submit()
    first = request(ctx)
    assert [url] = image_urls(first)
    assert text(List.last(first["messages"])) =~ "look at this"
    assert image_urls(request(ctx)) == [url, url]
    eventually(fn -> NanoAgent.info(ctx.name).status == :idle end)
    {:ok, ref} = Images.store(Seedling.ImageFixture.png())

    for suffix <- ["", "?view=debug"] do
      {:ok, timeline, _} = live(build_conn(), "/agents/#{ctx.name}" <> suffix)
      html = timeline |> element("#timeline") |> render()
      assert length(String.split(html, "alt=\"Attached image\"")) - 1 == 2
      assert has_element?(timeline, "#timeline img[src='/api/images/#{ref["id"]}']")
    end

    assert build_conn() |> get("/api/images/" <> ref["id"]) |> response(200) ==
             Seedling.ImageFixture.png()
  end

  test "text-only event and eval notices never send images, while operator logs retain attachment refs" do
    ctx = start_agent(modalities: ["text"])
    {:ok, ref} = Images.store(Seedling.ImageFixture.png())
    Fake.push(ctx.model, calls: [eval: "{:ok, #{inspect(ref)}}"])
    Fake.push(ctx.model, text: "cannot see")
    send(ctx.pid, %{image: ref})
    first = request(ctx)
    assert text(List.last(first["messages"])) =~ "cannot see images"
    assert image_urls(first) == []
    second = request(ctx)
    assert text(List.last(second["messages"])) =~ "cannot see images"
    assert image_urls(second) == []
    assert entry(ctx, "event_received")["images"] == [ref]
    assert entry(ctx, "event_received")["image_notice"] =~ "cannot see images"
    assert entry(ctx, "tool_result")["images"] == [ref]
    assert entry(ctx, "tool_result")["image_notice"] =~ "cannot see images"
    eventually(fn -> NanoAgent.info(ctx.name).status == :idle end)

    for suffix <- ["", "?view=debug"] do
      {:ok, timeline, _} = live(build_conn(), "/agents/#{ctx.name}" <> suffix)
      html = timeline |> element("#timeline") |> render()
      assert length(String.split(html, "alt=\"Attached image\"")) - 1 == 2
      assert has_element?(timeline, "#timeline p.dim", "cannot see images")
    end
  end

  test "invalid mailbox references produce an explicit notice and never malformed provider parts" do
    ctx = start_agent()
    Fake.push(ctx.model, text: "no image")

    send(ctx.pid, %{
      image: %{
        "type" => "image_reference",
        "id" => "../../secret",
        "mime_type" => "image/png",
        "width" => 1,
        "height" => 1
      }
    })

    body = request(ctx)
    assert image_urls(body) == []
    assert text(List.last(body["messages"])) =~ "invalid, missing or corrupt"
    assert text(List.last(body["messages"])) =~ "No image data was sent"
  end

  test "text-only eval image notice remains visible when the inspected value is truncated" do
    ctx = start_agent(modalities: ["text"])
    {:ok, ref} = Images.store(Seedling.ImageFixture.png())
    code = "{String.duplicate(\"x\", 100_000), #{inspect(ref)}}"
    Fake.push(ctx.model, calls: [eval: code])
    Fake.push(ctx.model, text: "cannot see")
    send(ctx.pid, :inspect_picture)
    request(ctx)
    returned = request(ctx)
    assert text(List.last(returned["messages"])) =~ "cannot see images"
    assert image_urls(returned) == []
    assert entry(ctx, "tool_result")["truncated"]
  end
end

defmodule Nano.ImageProvidersTest do
  use ExUnit.Case, async: false
  alias Nano.{FakeOpenRouter, FakeChatGPT, RawLog}

  setup do
    root = Path.join(System.tmp_dir!(), "deneb-images-wire-#{System.unique_integer([:positive])}")
    saved = Application.get_env(:nano, :images_dir)
    Application.put_env(:nano, :images_dir, root)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:nano, :images_dir, saved),
        else: Application.delete_env(:nano, :images_dir)

      File.rm_rf!(root)
    end)

    data = Nano.ImageFixtures.png()
    {:ok, ref} = Images.ingest_bytes(data)
    %{ref: ref, url: "data:image/png;base64," <> Base.encode64(data)}
  end

  defp messages(ref) do
    [
      %{"role" => "system", "content" => "test"},
      %{"role" => "user", "content" => Images.content("look", [ref], ["image"])},
      %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          %{"id" => "a", "function" => %{"name" => "eval", "arguments" => "{}"}},
          %{"id" => "b", "function" => %{"name" => "eval", "arguments" => "{}"}}
        ]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "a",
        "content" => Images.content("seen", [ref], ["image"])
      },
      %{"role" => "tool", "tool_call_id" => "b", "content" => "finished"}
    ]
  end

  defp recording(fun) do
    name = "image-wire-#{System.unique_integer([:positive])}/call"
    {result, files} = RawLog.recording(name, fun)
    on_exit(fn -> for file <- files, do: File.rm(Path.join(RawLog.dir(), file)) end)
    recorded = Enum.map_join(files, &File.read!(Path.join(RawLog.dir(), &1)))
    {result, recorded}
  end

  test "OpenRouter expands store bytes only on wire and logs no base64 on success/error", %{
    ref: ref,
    url: url
  } do
    FakeOpenRouter.start()
    model = FakeOpenRouter.model()
    original = messages(ref)
    FakeOpenRouter.push(model, text: "echo " <> url)
    {{:ok, reply}, raw} = recording(fn -> Nano.OpenRouter.chat(model, original, []) end)
    assert_receive {:openrouter_request, ^model, request}
    assert [_, user, assistant, tool_a, tool_b, images] = request["messages"]
    assert assistant["content"] == nil
    assert tool_a["tool_call_id"] == "a" and is_binary(tool_a["content"])
    assert tool_b["tool_call_id"] == "b" and is_binary(tool_b["content"])
    assert List.last(user["content"])["image_url"]["url"] == url
    assert List.last(images["content"])["image_url"]["url"] == url
    assert reply.message["content"] == "echo [redacted image data]"
    refute raw =~ "base64"
    assert raw =~ "[redacted image data]"
    refute Jason.encode!(original) =~ "base64"

    FakeOpenRouter.push(model, status: 400, body: %{"error" => %{"message" => "invalid " <> url}})
    {{:error, error}, raw} = recording(fn -> Nano.OpenRouter.chat(model, original, []) end)
    assert error.class == :refused
    refute inspect(error) =~ "base64"
    refute raw =~ "base64"
  end

  test "Codex user input_image and function_call_output list; request and SSE logs redacted", %{
    ref: ref,
    url: url
  } do
    FakeChatGPT.start()
    FakeChatGPT.listen()
    Nano.ChatGPT.Auth.logout()
    on_exit(fn -> Nano.ChatGPT.Auth.logout() end)
    FakeChatGPT.auth(:poll, [{200, :approved}])
    assert %{status: :pending} = Nano.ChatGPT.Auth.login()
    eventually(fn -> Nano.ChatGPT.Auth.status().status == :connected end)
    model = FakeChatGPT.model()
    FakeChatGPT.push(model, text: "echo " <> url)
    {{:ok, reply}, raw} = recording(fn -> Nano.ChatGPT.chat(model, messages(ref), [], "low") end)
    assert_receive {:chatgpt_request, ^model, request, _}
    assert [user, call_a, call_b, out_a, out_b] = request["input"]

    assert user["content"] == [
             %{"type" => "input_text", "text" => "look"},
             %{"type" => "input_image", "image_url" => url}
           ]

    assert call_a["call_id"] == "a" and call_b["call_id"] == "b"
    assert out_a["type"] == "function_call_output"

    assert out_a["output"] == [
             %{"type" => "input_text", "text" => "seen"},
             %{"type" => "input_image", "image_url" => url}
           ]

    assert out_b["output"] == "finished"
    assert reply.message["content"] == "echo [redacted image data]"
    refute raw =~ "base64"

    FakeChatGPT.push(model, failed: %{"code" => "invalid_prompt", "message" => url})

    {{:error, error}, raw} =
      recording(fn -> Nano.ChatGPT.chat(model, messages(ref), [], "low") end)

    assert error.class == :refused
    refute inspect(error) =~ "base64"
    refute raw =~ "base64"
  end

  test "deleted and corrupt stored bytes produce text notices and successful requests", %{
    ref: ref
  } do
    FakeOpenRouter.start()
    model = FakeOpenRouter.model()
    path = Path.join(Images.directory(), ref["id"])

    for action <- [fn -> File.write!(path, "corrupt") end, fn -> File.rm!(path) end] do
      action.()
      FakeOpenRouter.push(model, text: "ok")
      assert {:ok, _} = Nano.OpenRouter.chat(model, messages(ref), [])
      assert_receive {:openrouter_request, ^model, request}
      encoded = Jason.encode!(request)
      assert encoded =~ "Image unavailable"
      refute encoded =~ "image_ref"
      refute encoded =~ "base64"
    end
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
end

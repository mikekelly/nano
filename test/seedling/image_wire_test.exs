defmodule Seedling.ImageWireTest do
  use ExUnit.Case, async: false
  alias Seedling.Images
  alias Nano.FakeOpenRouter, as: Router
  alias Nano.FakeChatGPT, as: Codex

  setup do
    {:ok, ref} = Images.store(Seedling.ImageFixture.png())
    {:ok, url} = Images.data_url(ref)
    {:ok, ref: ref, url: url}
  end

  test "OpenRouter scripted request: user parts, tool promotion after all outputs, stable prefix",
       %{ref: ref, url: url} do
    Router.start()
    model = Router.model(%{"architecture" => %{"input_modalities" => ["text", "image"]}})
    Router.push(model, text: "seen")
    assert {:ok, entry} = Nano.Model.lookup(model)
    assert entry.input_modalities == ["text", "image"]

    transcript = [
      %{"role" => "system", "content" => "look"},
      %{"role" => "user", "content" => "what?", "images" => [ref]},
      %{"role" => "assistant", "tool_calls" => [call("a"), call("b")]},
      %{"role" => "tool", "tool_call_id" => "a", "content" => "picture", "images" => [ref]},
      %{"role" => "tool", "tool_call_id" => "b", "content" => "done"}
    ]

    assert {:ok, _} = Nano.OpenRouter.chat(model, transcript, [])
    assert_receive {:openrouter_request, ^model, body}
    assert [_, user, _, first_tool, second_tool, promoted] = body["messages"]

    assert [
             %{"type" => "text", "text" => "what?"},
             %{"type" => "image_url", "image_url" => %{"url" => ^url, "detail" => "high"}}
           ] = user["content"]

    assert first_tool["content"] == "picture"
    assert second_tool["content"] == "done"
    assert promoted["role"] == "user"
    assert List.last(promoted["content"])["image_url"]["url"] == url
    refute Jason.encode!(transcript) =~ "base64"
    Router.push(model, text: "seen again")

    assert {:ok, _} =
             Nano.OpenRouter.chat(
               model,
               transcript ++ [%{"role" => "user", "content" => "again"}],
               []
             )

    assert_receive {:openrouter_request, ^model, next}
    assert Enum.take(next["messages"], 5) == Enum.take(body["messages"], 5)
  end

  test "Codex scripted request: input_image in user and function_call_output", %{
    ref: ref,
    url: url
  } do
    Codex.start()
    Codex.listen()
    Nano.ChatGPT.Auth.logout()
    Codex.auth(:poll, [{200, :approved}])
    assert %{status: :pending} = Nano.ChatGPT.Auth.login()
    eventually(fn -> Nano.ChatGPT.Auth.status().status == :connected end)

    on_exit(fn ->
      Nano.ChatGPT.Auth.logout()
      :persistent_term.erase({Nano.ChatGPT, :models})
    end)

    # Explicit provider catalog modalities; no inference from a model's name.
    model = "vision-#{System.unique_integer([:positive])}"

    Codex.models([
      %{"slug" => model, "context_window" => 10000, "input_modalities" => ["text", "image"]}
    ])

    :persistent_term.erase({Nano.ChatGPT, :models})
    assert [%{input_modalities: ["text", "image"]}] = Nano.ChatGPT.models()
    Codex.push(model, text: "seen")

    transcript = [
      %{"role" => "system", "content" => "look"},
      %{"role" => "user", "content" => "what?", "images" => [ref]},
      %{"role" => "assistant", "tool_calls" => [call("a")]},
      %{"role" => "tool", "tool_call_id" => "a", "content" => "picture", "images" => [ref]}
    ]

    assert {:ok, _} = Nano.ChatGPT.chat(model, transcript, [], "low")
    assert_receive {:chatgpt_request, ^model, body, _}
    assert [user, _, tool] = body["input"]

    assert [
             %{"type" => "input_text", "text" => "what?"},
             %{"type" => "input_image", "image_url" => ^url, "detail" => "high"}
           ] = user["content"]

    assert tool["type"] == "function_call_output"
    assert List.last(tool["output"])["image_url"] == url
  end

  test "raw request log omits base64 while provider still receives it", %{ref: ref, url: url} do
    Router.start()
    model = Router.model()
    Router.push(model, text: "seen")
    path = "image-test-#{System.unique_integer([:positive])}/request"

    {{:ok, _}, files} =
      Nano.RawLog.recording(path, fn ->
        Nano.OpenRouter.chat(
          model,
          [
            %{"role" => "system", "content" => "look"},
            %{"role" => "user", "content" => "caption", "images" => [ref]}
          ],
          []
        )
      end)

    assert_receive {:openrouter_request, ^model, body}

    assert List.last(body["messages"])["content"] |> List.last() |> get_in(["image_url", "url"]) ==
             url

    request = Enum.find(files, &String.ends_with?(&1, ".request.txt"))
    raw = File.read!(Path.join(Nano.RawLog.dir(), request))
    assert raw =~ "[image data omitted]"
    refute raw =~ Base.encode64(Seedling.ImageFixture.png())
    assert raw =~ "caption"
  end

  defp call(id),
    do: %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => "eval", "arguments" => "{}"}
    }

  defp eventually(fun, tries \\ 200) do
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

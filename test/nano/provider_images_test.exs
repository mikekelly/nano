defmodule Nano.ProviderImagesTest do
  use ExUnit.Case, async: false
  alias Nano.{FakeChatGPT, FakeOpenRouter, RawLog}

  setup do
    dir =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "wire-images-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:nano, :image_dir)
    Application.put_env(:nano, :image_dir, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nano, :image_dir, previous),
        else: Application.delete_env(:nano, :image_dir)

      File.rm_rf!(dir)
      Nano.ChatGPT.Auth.logout()
    end)

    # Valid one-pixel GIF, with unique extension bytes so parallel suites cannot share objects.
    nonce = :crypto.strong_rand_bytes(12)

    bytes =
      <<"GIF89a", 1::little-16, 1::little-16, 0, 0, 0, 33, 254, 12, nonce::binary, 0, 44,
        0::little-16, 0::little-16, 1::little-16, 1::little-16, 0, 2, 2, 68, 1, 0, 59>>

    {:ok, ref} = Nano.Images.import_bytes(bytes)
    {:ok, url} = Nano.Images.data_url(ref)
    parts = [%{"type" => "text", "text" => "look"}, %{"type" => "image_ref", "image_ref" => ref}]

    messages = [
      %{"role" => "system", "content" => "system"},
      %{"role" => "user", "content" => parts}
    ]

    %{url: url, parts: parts, messages: messages}
  end

  test "OpenRouter hydrates only wire messages and preserves cache controls; errors and raw logs redact images",
       c do
    FakeOpenRouter.start()
    model = FakeOpenRouter.model()
    FakeOpenRouter.listen(model)
    FakeOpenRouter.push(model, status: 400, body: %{"error" => %{"message" => "echo " <> c.url}})
    name = "image-wire-#{System.unique_integer([:positive])}/1-1"

    {{:error, error}, files} =
      RawLog.recording(name, fn -> Nano.OpenRouter.chat(model, c.messages, []) end)

    assert_receive {:openrouter_request, ^model, body}

    assert [%{"content" => [%{"cache_control" => _}]}, %{"content" => [text, image]}] =
             body["messages"]

    assert text == %{"type" => "text", "text" => "look"}

    assert image == %{
             "type" => "image_url",
             "image_url" => %{"url" => c.url},
             "cache_control" => %{"type" => "ephemeral"}
           }

    assert List.last(c.messages)["content"] == c.parts
    refute inspect(error) =~ c.url
    assert error.body["error"]["message"] =~ "[redacted image data URL]"

    for file <- files do
      content = File.read!(Path.join(RawLog.dir(), file))
      refute content =~ c.url
      refute content =~ String.split(c.url, ",") |> List.last()
    end
  end

  test "Codex converts user and tool content lists into input text and images", c do
    FakeChatGPT.start()
    FakeChatGPT.listen()
    FakeChatGPT.auth(:poll, [{200, :approved}])
    FakeChatGPT.auth(:token, [{200, FakeChatGPT.tokens()}])
    Nano.ChatGPT.Auth.logout()
    assert %{status: :pending} = Nano.ChatGPT.Auth.login()
    wait_connected(250)
    model = FakeChatGPT.model()
    FakeChatGPT.push(model, text: "ok")

    messages =
      c.messages ++ [%{"role" => "tool", "tool_call_id" => "call-1", "content" => c.parts}]

    name = "image-codex-#{System.unique_integer([:positive])}/1-1"

    {{:ok, _}, files} =
      RawLog.recording(name, fn -> Nano.ChatGPT.chat(model, messages, [], "off") end)

    assert_receive {:chatgpt_request, ^model, body, _}, 3000

    expected = [
      %{"type" => "input_text", "text" => "look"},
      %{"type" => "input_image", "image_url" => c.url}
    ]

    assert [user, tool] = body["input"]
    assert user["content"] == expected
    assert tool["output"] == expected

    for file <- files,
        do:
          refute(
            File.read!(Path.join(RawLog.dir(), file)) =~ String.split(c.url, ",") |> List.last()
          )
  end

  test "redaction handles nested errors and JSON-escaped slashes", c do
    assert RawLog.redact(%{"nested" => [c.url]}) == %{"nested" => ["[redacted image data URL]"]}
    escaped = String.replace(c.url, "/", "\\/")
    refute RawLog.redact("echo \"#{escaped}\"") =~ String.split(c.url, ",") |> List.last()
    assert RawLog.redact("ordinary body") == "ordinary body"
  end

  defp wait_connected(0), do: flunk("fake subscription did not connect")

  defp wait_connected(n) do
    if Nano.ChatGPT.Auth.status().status != :connected do
      Process.sleep(20)
      wait_connected(n - 1)
    end
  end
end

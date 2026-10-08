defmodule Images.WireTest do
  use ExUnit.Case, async: true
  alias Images.Wire

  @ref %{
    "type" => "image_ref",
    "id" => String.duplicate("a", 64),
    "mime" => "image/png",
    "width" => 1,
    "height" => 1,
    "bytes" => 3
  }
  @text %{"type" => "text", "text" => "look"}
  @url "data:image/png;base64,YWJj"
  defp reader(@ref), do: {:ok, "abc", "image/png"}

  test "user mixed content expands deterministically without modifying references" do
    original = [%{"role" => "user", "content" => [@text, @ref, @text]}]
    assert [%{"content" => [@text, image, @text]}] = Wire.openrouter(original, &reader/1)
    assert image == %{"type" => "image_url", "image_url" => %{"url" => @url}}
    assert Wire.openrouter(original, &reader/1) == Wire.openrouter(original, &reader/1)
    assert hd(original)["content"] == [@text, @ref, @text]

    assert Wire.codex_content([@text, @ref], &reader/1) == [
             %{"type" => "input_text", "text" => "look"},
             %{"type" => "input_image", "image_url" => @url}
           ]
  end

  test "tool images follow the entire result batch, retain order and attribution" do
    call = %{"role" => "assistant", "tool_calls" => [%{"id" => "a"}, %{"id" => "b"}]}
    a = %{"role" => "tool", "tool_call_id" => "a", "content" => [@text, @ref]}
    b = %{"role" => "tool", "tool_call_id" => "b", "content" => [@ref, @text]}
    user = %{"role" => "user", "content" => "next"}
    assert [^call, ta, tb, images, ^user] = Wire.openrouter([call, a, b, user], &reader/1)
    assert ta["role"] == "tool" and tb["role"] == "tool"
    assert is_binary(ta["content"]) and is_binary(tb["content"])
    assert images["role"] == "user"
    assert [label_a, image, label_b, image] = images["content"]
    assert label_a["text"] =~ "a:"
    assert label_b["text"] =~ "b:"
    assert image["image_url"]["url"] == @url
    assert Wire.openrouter([a, b], &reader/1) == [ta, tb, images]
  end

  test "text-only messages stay unchanged and distinct tool batches do not mix" do
    tool = %{"role" => "tool", "content" => "ok"}
    user = %{"role" => "user", "content" => "hi"}
    assert Wire.openrouter([user, tool, user]) == [user, tool, user]
    assert Wire.openrouter([]) == []
    a = Map.merge(tool, %{"content" => [@ref], "tool_call_id" => "a"})

    assert [_, %{"role" => "user"}, ^user, _, %{"role" => "user"}] =
             Wire.openrouter([a, user, a], &reader/1)
  end

  test "missing, corrupt and exceptional readers become explicit notices" do
    for reader <- [
          fn _ -> {:error, "missing"} end,
          fn _ -> {:error, "hash mismatch"} end,
          fn _ -> raise "disk problem" end,
          fn _ -> throw(:bad) end,
          fn _ -> {:ok, "abc", "text/html"} end
        ] do
      assert [%{"type" => "input_text", "text" => notice}] = Wire.codex_content([@ref], reader)
      assert notice =~ "Image unavailable"

      assert [%{"content" => [%{"type" => "text", "text" => ^notice}]}] =
               Wire.openrouter([%{"role" => "user", "content" => [@ref]}], reader)
    end
  end

  test "catalog modalities are conservative without valid metadata" do
    for unknown <- [nil, "image", [], [123]],
        do: assert(Nano.Model.input_modalities(unknown) == ["text"])

    assert Nano.Model.input_modalities(["text", "image", "audio", "image"]) == [
             "text",
             "image",
             "audio"
           ]
  end

  test "redaction covers plain, escaped JSON and nested echoed response and error strings" do
    for url <- [@url, "data:image/jpeg;base64,/9j/+abc==", ~S(data:image\/png;base64,abc\/def==)] do
      assert Nano.RawLog.redact("prefix #{url} suffix") == "prefix [redacted image data] suffix"
      encoded = Jason.encode!(%{error: %{message: "bad #{url}"}})
      refute Nano.RawLog.redact(encoded) =~ "base64"

      assert Nano.RawLog.sanitize(%{"message" => [url]}) == %{
               "message" => ["[redacted image data]"]
             }
    end

    assert Nano.RawLog.redact("hello https://example.com/image.png") ==
             "hello https://example.com/image.png"
  end
end

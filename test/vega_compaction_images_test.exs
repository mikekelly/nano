defmodule Vega.CompactionImagesTest do
  use ExUnit.Case, async: true
  defp image(i), do: %{"type" => "image_ref", "id" => "image-#{i}", "detail" => "auto"}
  defp images(n), do: %{"role" => "user", "content" => Enum.map(1..n, &image/1)}

  test "native retained pricing differs from metadata-only summarizer input pricing" do
    transcript = Enum.map(1..20, fn i -> %{"role" => "user", "content" => [image(i)]} end)
    assert Vega.Compaction.tokens(transcript) < 2_000
    assert Vega.Compaction.retained_tokens(transcript) >= 20 * 4_800
    assert {:ok, {_old, kept}} = Vega.Compaction.plan(transcript, 80_000)
    assert Vega.Compaction.retained_tokens(kept) <= 20_000
    assert length(kept) == 4
  end

  test "newest complete multimodal exchange larger than target is retained whole" do
    older = [
      %{"role" => "user", "content" => "old goal"},
      %{"role" => "assistant", "content" => "done"}
    ]

    latest = [
      images(4),
      %{"role" => "assistant", "tool_calls" => [%{"id" => "a"}, %{"id" => "b"}]},
      %{"role" => "tool", "tool_call_id" => "a", "content" => "ok"},
      %{"role" => "tool", "tool_call_id" => "b", "content" => "ok"}
    ]

    assert Vega.Compaction.retained_tokens(latest) > div(24_000, 4)
    assert {:ok, {removed, kept}} = Vega.Compaction.plan(older ++ latest, 24_000)
    # No trimming away the image delivery or severing the assistant tool/result pair.
    assert kept == latest
    assert removed == older
  end

  test "later tool-loop exchanges can compact without a new user delivery" do
    transcript = [
      %{"role" => "user", "content" => String.duplicate("old", 10_000)},
      %{"role" => "assistant", "tool_calls" => [%{"id" => "a"}]},
      %{"role" => "tool", "tool_call_id" => "a", "content" => String.duplicate("old", 10_000)},
      %{"role" => "assistant", "tool_calls" => [%{"id" => "b"}]},
      %{"role" => "tool", "tool_call_id" => "b", "content" => "recent"}
    ]

    assert {:ok, {old, kept}} = Vega.Compaction.plan(transcript, 24_000)
    assert length(old) == 3
    assert kept == Enum.drop(transcript, 3)
  end

  test "fallback never permits
 an unanswerable image exchange or incomplete tools" do
    assert {:error, _} =
             Vega.Compaction.plan([%{"role" => "user", "content" => "old"}, images(5)], 24_000)

    transcript = [
      %{"role" => "user", "content" => "old"},
      images(4),
      %{"role" => "assistant", "tool_calls" => [%{"id" => "a"}, %{"id" => "b"}]},
      %{"role" => "tool", "tool_call_id" => "a", "content" => "ok"}
    ]

    assert {:error, _} = Vega.Compaction.plan(transcript, 24_000)
  end
end

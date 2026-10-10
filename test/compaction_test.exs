defmodule CompactionTest do
  use ExUnit.Case, async: true

  test "literal parser preserves code quotes and interpolation without executing" do
    code = ~S|Compaction.provide_summary(~S"Goal: #{raise :oops} \\ code")|
    assert {:ok, ~S|Goal: #{raise :oops} \\ code|} = Compaction.parse(code)

    for bad <- [
          "Compaction.provide_summary(\"\")",
          "Compaction.provide_summary(\"a\"); send(me, :bad)",
          "Compaction.provide_summary(to_string(1))",
          "broken ("
        ] do
      assert {:error, _} = Compaction.parse(bad)
    end

    assert {:error, _} = Compaction.validate(String.duplicate("a", 24_001))
  end

  test "U06 byte feedback measures multibyte input and gives a safe byte target" do
    assert {:error, _} = Compaction.validate(<<255>>)
    assert :ok = Compaction.validate(String.duplicate("é", 6000))
    assert {:error, feedback} = Compaction.validate(String.duplicate("é", 6001))
    assert feedback =~ "12002 UTF-8 bytes"
    assert feedback =~ "12,000 UTF-8 bytes"
    assert feedback =~ "8,000 UTF-8 bytes"
    refute Compaction.note() =~ "12,000 tokens"
  end

  test "events remain exact, chronological and first brief is pinned" do
    event = fn n -> "<event seq=\"#{n}\">#{String.duplicate("x", 100)}</event>" end

    transcript =
      for n <- 1..10,
          do: %{"role" => "user", "content" => event.(n) <> "\n<harness>budget</harness>"}

    kept = Compaction.rebuild(transcript, "Goal: continue", 1_000, "/test/full.jsonl")
    assert hd(kept)["content"] == event.(1)
    assert Enum.at(kept, -2)["content"] == event.(10)
    refute Enum.any?(kept, &String.contains?(&1["content"], "budget"))
    assert List.last(kept)["content"] =~ "/test/full.jsonl"

    excluded =
      Compaction.rebuild(transcript, "Goal: summarized report", 1_000, "log", [event.(10)])

    refute Enum.any?(excluded, &(&1["content"] == event.(10)))
  end

  test "multimodal event bundles retain refs once, budget images, and remain stable across rebuilds" do
    ref = %{"type" => "image_ref", "image_ref" => %{image_ref: String.duplicate("a", 64)}}
    event = fn n -> "<event seq=\"#{n}\">event #{n}</event>" end

    image = %{
      "role" => "user",
      "content" => [
        %{"type" => "text", "text" => event.(2)},
        %{"type" => "text", "text" => event.(3) <> "\n<harness>budget</harness>"},
        ref
      ]
    }

    transcript = [%{"role" => "user", "content" => event.(1)}, image]
    kept = Compaction.rebuild(transcript, "Goal: image", 60_000, "log")
    assert [_, %{"content" => [text, ^ref]}, _] = kept
    assert text["text"] == event.(2) <> "\n" <> event.(3)
    refute text["text"] =~ "budget"
    assert Enum.at(Compaction.rebuild(kept, "Goal: twice", 60_000, "log"), 1) == Enum.at(kept, 1)
    small = Compaction.rebuild(transcript, "Goal: image summarized", 20_000, "log")
    assert length(small) == 2
    refute inspect(small) =~ "image_ref"
    # Entirely excluded deliveries drop refs, mixed ones retain attribution atomically.
    assert length(
             Compaction.rebuild(transcript, "Goal: reports", 60_000, "log", [event.(2), event.(3)])
           ) == 2

    assert Enum.at(Compaction.rebuild(transcript, "Goal: mixed", 60_000, "log", [event.(2)]), 1) ==
             Enum.at(kept, 1)
  end

  test "oversized first image burst pins words and honest omission metadata, not image tokens" do
    ref = %{"type" => "image_ref", "image_ref" => %{image_ref: String.duplicate("b", 64)}}

    initial = %{
      "role" => "user",
      "content" => [
        %{"type" => "text", "text" => "<event seq=\"1\">first brief</event>"}
        | List.duplicate(ref, 10)
      ]
    }

    kept = Compaction.rebuild([initial], "Goal: semantic image observations", 20_000, "log")
    assert [first, _] = kept
    assert is_binary(first["content"])
    assert first["content"] =~ "first brief"
    assert first["content"] =~ "Pixels are no longer available"
    assert first["content"] =~ String.duplicate("b", 64)
    assert Nano.ImageInput.estimated_bytes(first["content"]) < div(20_000, 5) * 2
    repeated = Compaction.rebuild(kept, "Goal: checkpoint twice", 20_000, "log")
    assert hd(repeated) == first
    refute inspect(kept) =~ "image_ref"
  end
end

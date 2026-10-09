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
end

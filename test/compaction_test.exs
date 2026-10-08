defmodule CompactionTest do
  use ExUnit.Case, async: true

  test "only a literal summary call is accepted without execution" do
    assert {:ok, "checkpoint"} = Compaction.parse(~s|Compaction.provide_summary("checkpoint")|)
    assert {:error, _} = Compaction.parse(~s|Compaction.provide_summary("")|)

    assert {:error, _} =
             Compaction.parse(~s|send(self(), :evil); Compaction.provide_summary("ok")|)

    assert {:error, _} =
             Compaction.parse(~s|Compaction.provide_summary(File.read!("/etc/passwd"))|)
  end

  test "events are kept verbatim, checkpoint last, pending untouched" do
    event = ~s|<event seq="1">hello</event>|

    s = %{
      transcript: [
        %{"role" => "user", "content" => event <> "<harness>budget</harness>"},
        %{"role" => "assistant", "content" => "old"}
      ],
      max_context: 100_000,
      id: "test",
      pending: ["new"]
    }

    compacted = Compaction.apply_summary(s, "Goal: test")
    assert hd(compacted.transcript)["content"] == event
    assert List.last(compacted.transcript)["content"] =~ "Goal: test"
    assert compacted.pending == ["new"]
    assert compacted.context_used == 0
  end
end

defmodule Nano.CompactionTest do
  use ExUnit.Case, async: true

  test "cut never leaves orphaned tool results" do
    messages = [
      %{"role" => "user", "content" => String.duplicate("old", 8000)},
      %{"role" => "assistant", "content" => "", "tool_calls" => [%{"id" => "a"}]},
      %{"role" => "tool", "tool_call_id" => "a", "content" => String.duplicate("x", 12000)},
      %{"role" => "user", "content" => "continue"}
    ]

    {old, recent} = Nano.Compaction.split(messages, 20000)
    assert length(old) == 1
    assert hd(recent)["role"] == "assistant"
    assert old ++ recent == messages
  end

  test "bounded serialization retains newest progress and deterministic paths" do
    old = %{
      "role" => "user",
      "content" => "previous checkpoint: important decision" <> String.duplicate("x", 20000)
    }

    call = %{
      "role" => "assistant",
      "tool_calls" => [
        %{
          "function" => %{"name" => "eval", "arguments" => "File.read!(\"/app/lib/critical.ex\")"}
        }
      ]
    }

    latest = %{"role" => "tool", "content" => String.duplicate("z", 20000) <> "LATEST_STATUS"}
    text = Nano.Compaction.serialize([old, call, latest], 10000)
    assert text =~ "previous checkpoint"
    assert text =~ "LATEST_STATUS"
    assert text =~ "omitted"
    assert Nano.Compaction.files([call]) == ["/app/lib/critical.ex"]
    assert Nano.Compaction.summary_limit(10000) == 1250
  end

  test "small history is kept intact and reserve scales" do
    messages = [%{"role" => "user", "content" => "hi"}]
    assert Nano.Compaction.split(messages, 30000) == {[], messages}
    assert Nano.Compaction.reserve(272_000) == 16384
    assert Nano.Compaction.reserve(10000) == 4096
  end
end

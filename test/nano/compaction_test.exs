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

  test "small history is kept intact and reserve scales" do
    messages = [%{"role" => "user", "content" => "hi"}]
    assert Nano.Compaction.split(messages, 30000) == {[], messages}
    assert Nano.Compaction.reserve(272_000) == 16384
    assert Nano.Compaction.reserve(10000) == 4096
  end
end

defmodule Seedling.CompactionTest do
  use ExUnit.Case, async: true
  alias Seedling.Compaction, as: C

  defp message(code),
    do: %{
      "tool_calls" => [
        %{"function" => %{"name" => "eval", "arguments" => Jason.encode!(%{code: code})}}
      ]
    }

  defp event(text, kind \\ :external), do: %{text: text, kind: kind}

  test "strict AST extraction accepts only one literal call and never executes code" do
    assert {:ok, "checkpoint"} =
             C.extract(message(~S|Seedling.Compaction.provide_summary("checkpoint")|))

    for code <- [
          ~S|Seedling.Compaction.provide_summary("")|,
          ~S|Seedling.Compaction.provide_summary(" \n")|,
          ~S|x = Seedling.Compaction.provide_summary("checkpoint")|,
          ~S|Seedling.Compaction.provide_summary("checkpoint"); File.write!("/not-written", "bad")|,
          ~S|Seedling.Compaction.provide_summary(File.read!("/not-read"))|,
          ~S|Seedling.Compaction.provide_summary("#{File.read!("/not-read")}")|,
          ~S|Seedling.Compaction.provide_summary(1)|,
          ~S|Other.Compaction.provide_summary("checkpoint")|,
          "invalid ("
        ] do
      assert {:error, _} = C.extract(message(code)), code
    end

    m = message(~S|Seedling.Compaction.provide_summary("checkpoint")|)
    assert {:error, _} = C.extract(Map.put(m, "tool_calls", m["tool_calls"] ++ m["tool_calls"]))
    assert {:error, _} = C.extract(%{"content" => "checkpoint"})

    assert {:error, _} =
             C.extract(
               message("Seedling.Compaction.provide_summary(\"#{String.duplicate("x", 24000)}\")")
             )

    assert {:error, _} = C.validate(nil)
    assert {:error, _} = C.provide_summary("outside an eval")
  end

  test "retention pins first brief, selects newest external events, never edits their words" do
    events = [
      event("first brief"),
      event(String.duplicate("old", 200)),
      event("child findings", :child_result),
      event("newest request")
    ]

    retained = C.select_events(events, 200)
    assert retained == [hd(events), List.last(events)]
    {messages, ^retained} = C.rebuild(events, "checkpoint", window: 200, log: "/logs/full.jsonl")

    assert Enum.take(messages, 2) ==
             Enum.map(retained, &%{"role" => "user", "content" => &1.text})

    summary = List.last(messages)["content"]
    assert summary =~ "written by your own model"
    assert summary =~ "/logs/full.jsonl"
    assert String.ends_with?(summary, "checkpoint")
    refute summary =~ "child findings"
  end

  test "oversized first brief remains exact and older smaller events may fill remaining room" do
    large = event(String.duplicate("a", 10000))
    assert C.select_events([large, event("new")], 200) == [large]

    assert C.select_events([event("brief"), event("small"), large], 200) == [
             event("brief"),
             event("small")
           ]

    assert C.select_events([event("report", :child_result)], 200) == []
  end

  test "migration recovers events but never harness notes, assistant turns or tool results" do
    event = ~s(<event seq="1" at="now">exact brief</event>)

    s =
      C.migrate(%{
        transcript: [
          %{"role" => "user", "content" => event <> "\n<harness>budget</harness>"},
          %{"role" => "assistant", "content" => event},
          %{"role" => "tool", "content" => event}
        ],
        pending: ["<harness>note</harness>", ~s(<event seq="2" at="later">later message</event>)]
      })

    assert s.compaction_events == [%{text: event, kind: :external, images: []}]
    assert length(s.compaction_pending_events) == 1
    assert C.migrate(s) == s
    assert C.reserve(272_000) == 16384
    assert C.reserve(20000) == 5000
  end
end

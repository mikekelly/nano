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

  test "raw sigils preserve quoted code without evaluating interpolation" do
    code = "Compaction.provide_summary(~S|literal " <> <<35>> <> "{danger()} \\ path|)"
    assert {:ok, text} = Compaction.parse(code)
    assert text == "literal " <> <<35>> <> "{danger()} \\ path"
  end

  test "transport retries identical request and usage includes refused replies" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    owner = self()

    chat = fn _, messages, _, _, _ ->
      send(owner, {:request, messages})
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      case n do
        0 ->
          {:error, :connection_lost}

        1 ->
          {:ok, %{message: %{}, usage: %{"total_tokens" => 5}, cost: 1}}

        2 ->
          {:ok,
           %{
             message: %{
               "tool_calls" => [
                 %{
                   "function" => %{
                     "name" => "eval",
                     "arguments" =>
                       Jason.encode!(%{code: ~s|Compaction.provide_summary("Goal: continue")|})
                   }
                 }
               ]
             },
             usage: %{"total_tokens" => 9},
             cost: 2
           }}
      end
    end

    assert {:ok, "Goal: continue", metrics} =
             Compaction.run_with_usage("test", "low", [], chat: chat)

    assert metrics.attempts == 3
    assert length(metrics.responses) == 2
    assert_receive {:request, first}
    assert_receive {:request, second}
    assert_receive {:request, third}
    assert first == second
    assert third != second
    Agent.stop(counter)
  end

  test "hung provider calls time out and stop after three attempts" do
    owner = self()

    chat = fn _, _, _, _, _ ->
      send(owner, {:worker, self()})
      Process.sleep(:infinity)
    end

    assert {:error, _, %{attempts: 3, responses: []}} =
             Compaction.run_with_usage("test", "low", [], chat: chat, timeout: 5)

    for _ <- 1..3 do
      assert_receive {:worker, worker}
      refute Process.alive?(worker)
    end
  end

  test "literal raw heredoc accepted and interpolating sigils refused" do
    assert {:ok, "Goal\n"} =
             Compaction.parse("Compaction.provide_summary(~S\"\"\"\nGoal\n\"\"\")")

    assert {:error, _} = Compaction.parse("Compaction.provide_summary(~s|Goal|)")
    assert {:error, _} = Compaction.parse("Compaction.provide_summary(~S|Goal|u)")
  end
end

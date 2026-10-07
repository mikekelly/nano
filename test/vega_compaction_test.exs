defmodule Vega.CompactionTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()
    model = Fake.model()
    name = "compact-#{System.unique_integer([:positive])}"
    Fake.listen(model)
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model, max_context: 40_000))

    on_exit(fn ->
      if live = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, live)
        NanoAgent.kill_tasks(live)
      end

      Nano.StateStore.delete(name)
    end)

    %{model: model, pid: pid, name: name}
  end

  defp req(model) do
    assert_receive {:openrouter_request, ^model, body}, 3_000
    body
  end

  defp wait(pid, fun, tries \\ 100)
  defp wait(_pid, _fun, 0), do: flunk("state did not converge")

  defp wait(pid, fun, tries) do
    s = :sys.get_state(pid)

    if fun.(s),
      do: s,
      else:
        (
          Process.sleep(20)
          wait(pid, fun, tries - 1)
        )
  end

  test "real agent crosses threshold mid-tool loop; pid, bindings, mailbox and durable summary survive",
       c do
    Fake.push(c.model,
      text: String.duplicate("old facts ", 2_000),
      calls: [eval: "kept_binding = 42", idle: nil],
      usage: {10_000, 100, 0}
    )

    send(c.pid, :first)
    req(c.model)
    wait(c.pid, &(&1.status == :idle and &1.call_seq == 2))

    Fake.push(c.model,
      text: String.duplicate("recent facts ", 1_000),
      calls: [eval: "kept_binding + 1"],
      usage: {25_000, 100, 0}
    )

    send(c.pid, :second)
    req(c.model)
    summary_req = req(c.model)
    assert summary_req["max_tokens"] == 5_000
    assert (summary_req["tools"] || []) == []
    assert Jason.encode!(summary_req) =~ "old facts"
    refute Jason.encode!(summary_req) =~ "recent facts"
    # Arrivals during summarization must remain queued and not start a competing request.
    send(c.pid, :during_summary)
    s = wait(c.pid, &(length(&1.pending) == 1))
    assert s.status == :compacting
    original = s.transcript
    Fake.push(c.model, text: "Goals and facts; kept_binding is 42; continue second task.")
    resumed = req(c.model)
    assert NanoAgent.whereis(c.name) == c.pid
    assert Jason.encode!(resumed) =~ "harness automatically compacted"
    assert Jason.encode!(resumed) =~ "recent facts"
    refute Jason.encode!(resumed) =~ "old facts"
    Fake.push(c.model, calls: [idle: nil])
    delivered = req(c.model)
    assert Jason.encode!(delivered) =~ "during_summary"
    Fake.push(c.model, calls: [idle: nil])
    final = wait(c.pid, &(&1.status == :idle and &1.pending == [] and &1.call_seq == 5))
    assert final.bindings[:kept_binding] == 42
    assert final.context_used < 40_000 - Vega.Compaction.reserve()
    assert length(final.transcript) < length(original) + 5
    saved = Nano.StateStore.get(c.name)
    assert hd(saved.transcript)["content"] =~ "kept_binding is 42"
    entries = Nano.Log.read(final.id)
    assert Enum.any?(entries, &(&1["type"] == "compaction_completed"))

    assert Enum.any?(
             entries,
             &(&1["type"] == "model_response" and String.contains?(&1["text"] || "", "old facts"))
           )
  end

  test "provider error retains original history and explicitly halts", c do
    Fake.push(c.model,
      text: String.duplicate("old ", 2_000),
      calls: [idle: nil],
      usage: {25_000, 100, 0}
    )

    send(c.pid, :first)
    req(c.model)
    wait(c.pid, &(&1.status == :idle and &1.call_seq == 1))
    send(c.pid, :second)
    req(c.model)
    original = :sys.get_state(c.pid).transcript
    Fake.push(c.model, status: 400)
    final = wait(c.pid, &(&1.halted == :compaction_failed))
    assert final.transcript == original
    assert Enum.join(final.pending) =~ "original history is retained"
    refute_receive {:openrouter_request, _, _}, 100
  end

  test "truncated and oversized summaries are refused without replacing history", c do
    Fake.push(c.model, text: "partial", finish_reason: "length")

    assert {:error, _, _} =
             Vega.Compaction.summarize(c.model, [%{"role" => "user", "content" => "old"}], 40_000)

    req(c.model)
    Fake.push(c.model, text: String.duplicate("x", 11_000))

    assert {:error, _, _} =
             Vega.Compaction.summarize(c.model, [%{"role" => "user", "content" => "old"}], 40_000)

    req(c.model)
  end

  test "summarizer timeout is visible and leaves transcript intact", c do
    saved = Application.get_env(:nano, :compaction_timeout_ms)
    Application.put_env(:nano, :compaction_timeout_ms, 30)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:nano, :compaction_timeout_ms, saved),
        else: Application.delete_env(:nano, :compaction_timeout_ms)
    end)

    Fake.push(c.model, text: "old", calls: [idle: nil], usage: {25_000, 100, 0})
    send(c.pid, :first)
    req(c.model)
    wait(c.pid, &(&1.status == :idle and &1.call_seq == 1))
    send(c.pid, :second)
    req(c.model)
    original = :sys.get_state(c.pid).transcript
    final = wait(c.pid, &(&1.halted == :compaction_failed))
    assert final.transcript == original
    assert Enum.join(final.pending) =~ "timeout"
  end

  test "plan cuts only after all parallel tool results" do
    call = fn id -> %{"id" => id} end

    transcript = [
      %{"role" => "user", "content" => String.duplicate("x", 20_000)},
      %{"role" => "assistant", "tool_calls" => [call.("a"), call.("b")]},
      %{"role" => "tool", "tool_call_id" => "a", "content" => String.duplicate("z", 20_000)},
      %{"role" => "tool", "tool_call_id" => "b", "content" => "ok"},
      %{"role" => "user", "content" => "recent"}
    ]

    assert {:ok, {old, kept}} = Vega.Compaction.plan(transcript, 40_000)
    assert length(old) == 4
    assert kept == [List.last(transcript)]
    assert {:error, _} = Vega.Compaction.plan(Enum.take(transcript, 3), 40_000)
  end
end

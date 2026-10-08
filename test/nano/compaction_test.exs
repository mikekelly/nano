defmodule Nano.CompactionTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()
    model = Fake.model()
    name = "compact-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      NanoAgent.start(
        [name: name, system_prompt: "You are a test agent."] ++
          Fake.opts(model, max_context: 20_000)
      )

    Fake.listen(model)

    on_exit(fn ->
      if p = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)
        NanoAgent.kill_tasks(p)
      end

      Nano.StateStore.delete(name)
    end)

    %{pid: pid, name: name, model: model}
  end

  defp request(model) do
    assert_receive {:openrouter_request, ^model, body}, 3_000
    body
  end

  defp wait(fun, n \\ 200)
  defp wait(fun, 0), do: assert(fun.())

  defp wait(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait(fun, n - 1)
        )
  end

  test "real GenServer threshold crossing automatically summarizes, keeps identity/mailbox/bindings and resumes",
       c do
    Fake.push(c.model, calls: [eval: "kept_binding = 42"])
    Fake.push(c.model, text: "first complete")
    send(c.pid, :first)
    request(c.model)
    request(c.model)
    wait(fn -> NanoAgent.info(c.name).status == :idle end)

    Fake.push(c.model, text: "second complete", usage: {15_500, 10, 0})
    send(c.pid, :second)
    request(c.model)
    summary_call = request(c.model)
    assert summary_call["tools"] == []
    assert summary_call["max_tokens"] <= 13_000
    assert hd(summary_call["messages"])["content"] |> inspect() =~ "Do NOT continue"
    assert :sys.get_state(c.pid).status == :compacting
    # A new message during the summary stays queued, and this process stays responsive.
    send(c.pid, {:during_compaction, self()})
    :sys.get_state(c.pid)

    Fake.push(c.model,
      text:
        "Goal: test\nConstraints & Preferences: preserve binding\nProgress: Done first\nKey Decisions: keep 42\nNext Steps: continue\nCritical Context: kept_binding = 42"
    )

    Fake.push(c.model, calls: [eval: "kept_binding"])
    resumed = request(c.model)
    assert inspect(resumed["messages"]) =~ "History compacted automatically by the harness"
    assert inspect(resumed["messages"]) =~ ":during_compaction"
    assert NanoAgent.whereis(c.name) == c.pid
    Fake.push(c.model, text: "continued")
    result = request(c.model)

    assert Enum.any?(
             result["messages"],
             &(&1["role"] == "tool" and inspect(&1["content"]) =~ "42")
           )

    wait(fn -> NanoAgent.info(c.name).status == :idle end)
    assert NanoAgent.info(c.name).compactions == 1
    assert NanoAgent.info(c.name).halted == nil
    assert NanoAgent.info(c.name).budget.context_used < 20_000
    id = NanoAgent.info(c.name).id
    assert Enum.any?(Nano.Log.read(id), &(&1["type"] == "compaction_completed"))

    assert Enum.any?(
             Nano.Log.read(id),
             &(&1["type"] == "event_received" and &1["message"] =~ ":first")
           )
  end

  test "summary failure is visible and never silently discards history", c do
    Fake.push(c.model, text: "first")
    send(c.pid, :first)
    request(c.model)
    wait(fn -> NanoAgent.info(c.name).status == :idle end)
    Fake.push(c.model, text: "second", usage: {15_500, 10, 0})
    Fake.push(c.model, status: 400, body: %{"error" => %{"message" => "bad summary"}})
    send(c.pid, :second)
    request(c.model)
    request(c.model)
    wait(fn -> NanoAgent.info(c.name).halted == :context end)
    s = :sys.get_state(c.pid)
    assert length(s.transcript) == 4
    assert inspect(s.pending) =~ "Automatic harness compaction failed"
    assert Enum.any?(Nano.Log.read(s.id), &(&1["type"] == "compaction_failed"))
  end

  test "cut retains complete tool call/result pairs and serialization bounds tool output" do
    messages = [
      %{"role" => "user", "content" => "old"},
      %{"role" => "assistant", "tool_calls" => [%{"id" => "a"}]},
      %{"role" => "tool", "tool_call_id" => "a", "content" => String.duplicate("x", 20_000)},
      %{"role" => "user", "content" => "new"},
      %{"role" => "assistant", "tool_calls" => [%{"id" => "b"}]},
      %{"role" => "tool", "tool_call_id" => "b", "content" => "new result"}
    ]

    assert {:ok, older, recent} = Nano.Compaction.plan(messages, 20_000)
    assert hd(recent)["content"] == "new"
    assert List.last(recent)["tool_call_id"] == "b"
    assert byte_size(Nano.Compaction.serialize(older)) < 3_000
  end
end

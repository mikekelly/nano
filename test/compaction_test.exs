defmodule CompactionTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  test "parser accepts only data, including raw quoted code" do
    assert {:ok, "hello"} = Compaction.parse(~s|Compaction.provide_summary("hello")|)
    assert {:ok, ~S|#{x}\\|} = Compaction.parse(~S|Compaction.provide_summary(~S"#{x}\\")|)

    for code <- [
          "System.halt()",
          ~s|Compaction.provide_summary("")|,
          ~s|Compaction.provide_summary("a"); send(self(), :bad)|,
          ~s|Compaction.provide_summary(to_string(1))|
        ] do
      assert {:error, _} = Compaction.parse(code)
    end
  end

  test "automatic compaction runs in a real agent and keeps identity and queued events" do
    Fake.start()
    model = Fake.model()
    Fake.listen(model)
    name = "compact-#{System.unique_integer([:positive])}"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model, max_context: 32_000))

    on_exit(fn ->
      if p = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)

      NanoAgent.kill_tasks(pid)
      Nano.StateStore.delete(name)
    end)

    :sys.replace_state(pid, fn s -> %{s | context_used: 23_000, measured_bytes: 100_000} end)
    send(pid, :original_brief)
    assert_receive {:openrouter_request, ^model, body}, 2000
    assert inspect(body) =~ "Automatic compaction"
    send(pid, :during_compaction)

    Fake.push(model,
      calls: [
        eval: ~s|Compaction.provide_summary("Goal: verify. Progress: Done. Next Steps: idle.")|
      ]
    )

    assert_receive {:openrouter_request, ^model, body}, 2000
    assert inspect(body) =~ "original_brief"
    assert inspect(body) =~ "during_compaction"
    assert inspect(body) =~ "Your conversation before this point was compacted"
    Fake.push(model, calls: [idle: nil])
    Process.sleep(50)
    assert NanoAgent.whereis(name) == pid
    assert NanoAgent.info(name).halted == nil
    assert NanoAgent.info(name).budget.context_used < 23_000
  end
end

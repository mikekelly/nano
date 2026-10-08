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

  test "opt-in reproducible smoke driver executes its complete protocol", c do
    Fake.push(c.model, calls: [eval: "sentinel = 73"])
    Fake.push(c.model, text: "READY")
    Fake.push(c.model, text: "ACK", usage: {15_500, 10, 0})

    Fake.push(c.model,
      text: "Goal: retain sentinel\nProgress: set sentinel=73\nNext Steps: verify"
    )

    Fake.push(c.model, calls: [eval: "sentinel"])
    Fake.push(c.model, text: "73")
    path = Path.expand("../../priv/smoke/compaction.exs", __DIR__)
    assert_raise RuntimeError, ~r/confirm_spend/, fn -> Code.eval_file(path) end

    {driver, _} =
      Code.eval_string(File.read!(path), confirm_spend: true, notify: self(), model: c.model)

    assert_receive {:compaction_smoke, report_path, %{result: :passed, final_tool_result: "73"}},
                   5000

    assert report_path == driver.report_path
    assert File.read!(report_path) =~ "compactions: 1"
    wait(fn -> NanoAgent.whereis(driver.name) == nil end)
    File.rm!(report_path)
  end

  test "real GenServer threshold
 crossing automatically summarizes, keeps identity/mailbox/bindings and resumes",
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

  test "an in-flight checkpoint task without newly added file metadata survives hot upgrade", c do
    Fake.push(c.model, text: "first")
    send(c.pid, :first)
    request(c.model)
    wait(fn -> NanoAgent.info(c.name).status == :idle end)
    Fake.push(c.model, text: "second", usage: {15_500, 10, 0})
    send(c.pid, :second)
    request(c.model)
    request(c.model)
    :sys.replace_state(c.pid, &%{&1 | task: Map.delete(&1.task, :files)})
    Fake.push(c.model, text: "Goal: retain task\nProgress: two turns done\nNext Steps: continue")
    wait(fn -> NanoAgent.info(c.name).compactions == 1 end)
    assert NanoAgent.whereis(c.name) == c.pid
    assert NanoAgent.info(c.name).restart_count == 0
    assert NanoAgent.info(c.name).halted == nil
  end

  test "an oversized accepted
 checkpoint keeps the original transcript and count on failure",
       c do
    :sys.replace_state(c.pid, &%{&1 | system_prompt: String.duplicate("p", 12_000)})
    Fake.push(c.model, text: "first")
    send(c.pid, :first)
    request(c.model)
    wait(fn -> NanoAgent.info(c.name).status == :idle end)
    Fake.push(c.model, text: "second", usage: {15_500, 10, 0})
    send(c.pid, String.duplicate("x", 8_500))
    request(c.model)
    summary_call = request(c.model)
    assert summary_call["max_tokens"] == 2500
    original = :sys.get_state(c.pid).transcript
    Fake.push(c.model, text: String.duplicate("s", 9_990))
    wait(fn -> NanoAgent.info(c.name).halted == :context end)
    assert :sys.get_state(c.pid).transcript == original
    assert NanoAgent.info(c.name).compactions == 0
    assert inspect(:sys.get_state(c.pid).pending) =~ "checkpoint and recent history"
  end

  test "reply-length cutoff triggers a checkpoint even below the token threshold", c do
    Fake.push(c.model, text: "first")
    send(c.pid, :first)
    request(c.model)
    wait(fn -> NanoAgent.info(c.name).status == :idle end)
    Fake.push(c.model, text: "cut off", finish_reason: "length")
    Fake.push(c.model, text: "Goal: continue\nProgress: partial response\nNext Steps: resume")
    send(c.pid, :second)
    request(c.model)
    summary_call = request(c.model)
    assert summary_call["tools"] == []
    Fake.push(c.model, text: "completed after cutoff")
    resumed = request(c.model)
    assert inspect(resumed["messages"]) =~ "cut off"
    wait(fn -> NanoAgent.info(c.name).status == :idle end)
    assert NanoAgent.info(c.name).compactions == 1
    assert NanoAgent.info(c.name).halted == nil
  end

  test "a long single turn checkpoints at an assistant boundary without orphaning results",
       c do
    Fake.push(c.model, calls: [eval: "File.read!(\"/etc/hostname\")"])
    Fake.push(c.model, calls: [eval: "value = 81"], usage: {15_500, 10, 0})
    send(c.pid, :long_turn)
    request(c.model)
    request(c.model)
    summary_call = request(c.model)
    assert summary_call["tools"] == []

    Fake.push(c.model,
      text: "Goal: long task\nProgress: read hostname\nNext Steps: keep value=81"
    )

    Fake.push(c.model, text: "continued")
    resumed = request(c.model)
    assert inspect(resumed) =~ "Files read (literal eval paths): /etc/hostname"

    assert [
             %{"role" => "assistant", "tool_calls" => [call]},
             %{"role" => "tool", "tool_call_id" => id}
           ] = Enum.take(resumed["messages"], -2)

    assert call["id"] == id
    wait(fn -> NanoAgent.info(c.name).status == :idle end)
    assert NanoAgent.info(c.name).halted == nil
  end

  test "in-flight eval results from both seed tuple shapes survive a hot upgrade", c do
    for shape <- [:three, :four] do
      Fake.push(c.model, calls: [eval: "receive do :never -> :ok end"])
      Fake.push(c.model, text: "continued")
      send(c.pid, {:old_eval, shape})
      request(c.model)
      wait(fn -> match?(%{task: %{kind: :eval}}, Nano.StateStore.get(c.name)) end)
      s = :sys.get_state(c.pid)

      tuple =
        if shape == :three, do: {:ok, "42", [legacy: 42]}, else: {:ok, "42", [legacy: 42], ""}

      # Simulates completion of a task compiled under the seed module. No live module
      # replacement is needed; the actual completion message protocol is exercised.
      send(c.pid, {s.task.task.ref, tuple})
      resumed = request(c.model)
      assert inspect(List.last(resumed["messages"])["content"]) =~ "42"
      Process.exit(s.task.task.pid, :kill)
      wait(fn -> NanoAgent.info(c.name).status == :idle end)
      assert NanoAgent.whereis(c.name) == c.pid
      assert NanoAgent.info(c.name).restart_count == 0
    end
  end

  test "oversized serialized lifetimes use bounded chronological checkpoint updates and aggregate usage",
       c do
    older =
      for i <- 1..4,
          do: %{
            "role" => "user",
            "content" => "START-#{i}:" <> String.duplicate("x", 9_000) <> ":END-#{i}"
          }

    assert {:ok, chunks, output, limit} = Nano.Compaction.inputs(older, 20_000)
    assert length(chunks) == 2
    assert Enum.all?(chunks, &(byte_size(&1) + output * 4 + 1024 <= limit))

    Fake.push(c.model,
      text: "Goal: first checkpoint preserves alpha",
      usage: {100, 10, 0},
      cost: 0.01
    )

    Fake.push(c.model,
      text: "Goal: updated checkpoint preserves alpha and beta",
      usage: {200, 20, 0},
      cost: 0.02
    )

    task = Task.async(fn -> Nano.Compaction.summarize(c.model, "off", older, 20_000) end)
    first = request(c.model)
    assert first["tools"] == []
    assert List.last(first["messages"])["content"] =~ "START-1"
    second = request(c.model)
    text = List.last(second["messages"])["content"]
    assert text =~ "Previous structured checkpoint"
    assert text =~ "first checkpoint preserves alpha"
    assert text =~ "END-4"
    assert byte_size(text) <= limit
    assert {:ok, summary, aggregate} = Task.await(task)
    assert summary =~ "alpha and beta"
    assert aggregate.usage["prompt_tokens"] == 300
    assert aggregate.usage["completion_tokens"] == 30
    assert aggregate.summary_passes == 2
    assert_in_delta aggregate.cost, 0.03, 0.00001
  end

  test "later checkpoint-pass failure preserves original history and reports earlier successful usage",
       c do
    original =
      for i <- 1..8, do: %{"role" => "user", "content" => "#{i}:" <> String.duplicate("x", 9000)}

    :sys.replace_state(c.pid, &%{&1 | transcript: original, context_used: 15_500})
    Fake.push(c.model, text: "Goal: preserve earlier facts", usage: {100, 10, 0}, cost: 0.01)
    Fake.push(c.model, status: 400, body: %{"error" => %{"message" => "later pass rejected"}})
    send(c.pid, :trigger_checkpoint)
    request(c.model)
    request(c.model)
    wait(fn -> NanoAgent.info(c.name).halted == :context end)
    assert :sys.get_state(c.pid).transcript == original
    assert NanoAgent.info(c.name).compactions == 0

    error =
      Enum.find(Nano.Log.read(NanoAgent.info(c.name).id), &(&1["type"] == "compaction_failed"))[
        "error"
      ]

    assert error =~ "known_prompt_tokens: 100"
    assert error =~ "known_completion_tokens: 10"
    assert error =~ "known_cost: 0.01"
    assert error =~ "later pass rejected"
  end

  test "invalid later successful response reports all known usage without claiming checkpoint success",
       c do
    older = for _ <- 1..4, do: %{"role" => "user", "content" => String.duplicate("x", 9000)}
    Fake.push(c.model, text: "Goal: initial valid checkpoint", usage: {100, 10, 0}, cost: 0.01)
    Fake.push(c.model, text: String.duplicate("z", 10001), usage: {200, 20, 0}, cost: 0.02)
    task = Task.async(fn -> Nano.Compaction.summarize(c.model, "off", older, 20_000) end)
    request(c.model)
    request(c.model)
    assert {:error, detail} = Task.await(task)
    assert detail.known_prompt_tokens == 300
    assert detail.known_completion_tokens == 30
    assert detail.successful_summary_passes == 1
    assert_in_delta detail.known_cost, 0.03, 0.00001
    assert detail.reason =~ "exceeded its length bound"
  end

  test "summary staging has
 a finite pass bound before any model call" do
    huge = [%{"role" => "user", "content" => String.duplicate("x", 1_400_000)}]
    assert {:error, error} = Nano.Compaction.inputs(huge, 20_000)
    assert error =~ "64-pass"
  end

  test "a single oversized unicode
 record is continued without dropping text or splitting UTF-8" do
    older = [
      %{
        "role" => "user",
        "content" => "exact-path:/tmp/task.ex " <> String.duplicate("界", 20_000) <> " END"
      }
    ]

    assert {:ok, chunks, output, limit} = Nano.Compaction.inputs(older, 20_000)
    assert length(chunks) > 1
    assert Enum.all?(chunks, &(String.valid?(&1) and byte_size(&1) + output * 4 + 1024 <= limit))

    reconstructed =
      Enum.map_join(
        chunks,
        "",
        &Regex.replace(~r/\[user serialized record \d+, continuation segment \d+\]:\n/, &1, "")
      )

    assert reconstructed == Nano.Compaction.serialize(older)
  end

  test "retention target is soft
: a 50KB recent tool pair still compacts in a 272K window" do
    older =
      Enum.flat_map(1..10, fn _ ->
        [
          %{"role" => "user", "content" => String.duplicate("u", 50_000)},
          %{"role" => "assistant", "content" => "done"}
        ]
      end)

    recent = [
      %{"role" => "user", "content" => "new request"},
      %{
        "role" => "assistant",
        "tool_calls" => [
          %{"id" => "recent-call", "function" => %{"name" => "eval", "arguments" => "{}"}}
        ]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "recent-call",
        "content" => String.duplicate("r", 50_000)
      }
    ]

    transcript = older ++ recent
    assert Nano.Compaction.due?(272_000, Nano.Compaction.size(transcript))
    assert {:ok, prefix, suffix} = Nano.Compaction.plan(transcript, 272_000)
    assert prefix != []
    assert Nano.Compaction.size(suffix) > 20_000
    assert Nano.Compaction.size(suffix) < 272_000 - Nano.Compaction.reserve(272_000)

    assert [
             %{"role" => "assistant", "tool_calls" => [%{"id" => "recent-call"}]},
             %{"role" => "tool", "tool_call_id" => "recent-call"}
           ] = Enum.take(suffix, -2)

    # In a tiny window this same pair is truly irreducible, not merely over the soft target.
    assert :no_prefix = Nano.Compaction.plan(recent, 20_000)
  end

  test "cut retains complete tool
 call/result pairs and serialization bounds tool output" do
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

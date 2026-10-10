defmodule AttentionTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()
    name = "attention-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    model = Fake.model()
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model))

    on_exit(fn ->
      if pid = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(name)

      File.rm(
        Path.join([Application.fetch_env!(:nano, :state_dir), "frontmind", name <> ".json"])
      )
    end)

    %{name: name, model: model, pid: pid}
  end

  test "own note reaches first and mid-turn requests, then forced after compaction", c do
    assert {:ok, _} = FrontMind.set(c.pid, "Do not forget to test.")
    assert {:ok, _} = FrontMind.configure(c.name, threshold_tokens: 1)
    Fake.push(c.model, calls: [eval: "1 + 1"])
    Fake.push(c.model, calls: [eval: ~S|Compaction.provide_summary("Goal: test")|])
    Fake.push(c.model, text: "finished")
    send(c.pid, :start)

    for _ <- 1..3 do
      assert_receive {:openrouter_request, model, body}, 3000
      assert model == c.model
      assert text(List.last(body["messages"])) =~ "Do not forget to test."
    end

    :sys.get_state(c.pid)
    entries = Nano.Log.read(NanoAgent.info(c.name).id)
    bobs = Enum.filter(entries, &(&1["kind"] == "context_bob"))
    assert length(bobs) == 3
    assert Enum.any?(bobs, &(&1["reason"] == "distance"))
    assert Enum.any?(bobs, &(&1["reason"] == "compaction"))
  end

  test "disabled note is absent; enabled note survives process restart", c do
    assert {:ok, _} = FrontMind.set(c.name, "Keep this durable.")
    assert {:ok, _} = FrontMind.configure(c.name, bobbing: false)
    Fake.push(c.model, text: "done")
    send(c.pid, :start)
    assert_receive {:openrouter_request, _, body}, 3000

    refute Enum.any?(
             body["messages"],
             &(is_binary(&1["content"]) and String.contains?(&1["content"], "Keep this durable."))
           )

    :sys.get_state(c.pid)
    Fake.push(c.model, text: "restart acknowledged")
    Process.exit(c.pid, :kill)
    # A supervisor restart is asynchronous; wait without making model calls.
    wait_restart(c.name, c.pid, 100)
    assert_receive {:openrouter_request, _, _}, 3000
    wait_idle(c.name, 100)
    assert {:ok, %{note: "Keep this durable."}} = FrontMind.get(c.name)
    assert {:ok, _} = FrontMind.configure(c.name, bobbing: true)
    Fake.push(c.model, text: "again")
    NanoAgent.notify(c.name, :continue)
    assert_receive {:openrouter_request, _, body}, 3000
    assert text(List.last(body["messages"])) =~ "Keep this durable."
  end

  test "optional drift is bounded, logged, never changes note and can be disabled", c do
    assert {:ok, _} = FrontMind.set(c.name, "Focus on tests")

    assert {:ok, _} =
             FrontMind.configure(c.name,
               drift: true,
               drift_interval_tokens: 1,
               threshold_tokens: 100_000
             )

    original = Nano.StateStore.get(c.name)
    s = %{original | transcript: [%{"role" => "user", "content" => "start"}]}
    first = Nano.Attention.before_request(s, decision: fn _ -> flunk("too early") end)

    grown = %{
      first
      | transcript:
          first.transcript ++
            [%{"role" => "assistant", "content" => String.duplicate("off task ", 1000)}]
    }

    second =
      Nano.Attention.before_request(grown,
        decision: fn input ->
          assert input.note == "Focus on tests"
          assert String.length(input.recent_activity) <= 3000
          {:ok, 0.9}
        end
      )

    assert List.last(second.transcript)["content"] =~ "drift probability 0.9"
    assert {:ok, %{note: "Focus on tests"}} = FrontMind.get(c.name)
    entries = Nano.Log.read(original.id)
    assert Enum.any?(entries, &(&1["kind"] == "drift_judgement" and &1["probability"] == 0.9))
    assert Enum.any?(entries, &(&1["kind"] == "context_bob" and &1["drift_probability"] == 0.9))

    grown = %{
      second
      | transcript: second.transcript ++ [%{"role" => "assistant", "content" => "more"}]
    }

    fallback = Nano.Attention.before_request(grown, decision: fn _ -> {:error, :unavailable} end)
    assert fallback.attention_drift.probability == nil
    assert {:ok, _} = FrontMind.configure(c.name, drift: false)
    Nano.Attention.before_request(fallback, decision: fn _ -> flunk("disabled drift called") end)
  end

  test "image-rich activity triggers both note distance and drift interval", c do
    assert {:ok, _} = FrontMind.set(c.name, "Inspect the attached images")

    assert {:ok, _} =
             FrontMind.configure(c.name,
               drift: true,
               drift_interval_tokens: 16000,
               threshold_tokens: 8000
             )

    s = Nano.StateStore.get(c.name)

    first =
      Nano.Attention.before_request(
        %{s | transcript: [%{"role" => "user", "content" => "start"}]},
        decision: fn _ -> flunk("too early") end
      )

    image = %{
      "role" => "user",
      "content" => [
        %{"type" => "image_ref", "image_ref" => %{"hash" => String.duplicate("b", 64)}}
      ]
    }

    grown = %{first | transcript: first.transcript ++ List.duplicate(image, 4)}

    second =
      Nano.Attention.before_request(grown,
        decision: fn state ->
          assert state.note == "Inspect the attached images"
          assert String.length(state.recent_activity) <= 3000
          {:ok, 0.2}
        end
      )

    assert length(second.transcript) == length(grown.transcript) + 1
    assert second.attention_drift.probability == 0.2
    entries = Nano.Log.read(s.id)

    assert Enum.any?(
             entries,
             &(&1["kind"] == "drift_judgement" and &1["distance_tokens"] >= 19200)
           )

    assert Enum.any?(
             entries,
             &(&1["kind"] == "context_bob" and &1["reason"] == "distance" and
                 &1["distance_tokens"] >= 19200)
           )
  end

  test "goals are independently bobbed and disabled", c do
    assert {:ok, goal} =
             Goals.add(c.name, "Test harness",
               why: "Prove requests carry own goals",
               status: :active
             )

    s = Nano.StateStore.get(c.name)
    first = Nano.Attention.before_request(s)
    assert List.last(first.transcript)["content"] =~ "Test harness"
    assert List.last(first.transcript)["content"] =~ "own goals"
    assert {:ok, _} = Goals.configure(c.name, bobbing: false)
    assert Nano.Attention.before_request(s).transcript == s.transcript
    assert {:ok, _} = Goals.update(c.name, goal.id, status: :done)
  end

  defp text(%{"content" => [%{"text" => text}]}), do: text

  defp text(%{"content" => text}), do: text
  defp wait_idle(_, 0), do: flunk("idle timed out")

  defp wait_idle(name, n) do
    if NanoAgent.info(name).status == :idle,
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_idle(name, n - 1)
        )
  end

  defp wait_restart(_, _, 0), do: flunk("restart timed out")

  defp wait_restart(name, old, n) do
    case NanoAgent.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        :sys.get_state(pid)

      _ ->
        Process.sleep(10)
        wait_restart(name, old, n - 1)
    end
  end
end

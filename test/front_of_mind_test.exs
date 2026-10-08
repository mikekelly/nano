defmodule FrontOfMindTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "deneb-fom-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    parent = self()
    opts = [root: root, logger: fn _, type, fields -> send(parent, {type, fields}) end]
    %{opts: opts, s: %{id: "test", name: "agent", transcript: []}}
  end

  test "note bounds count Unicode characters and persists across calling processes", %{opts: opts} do
    assert {:ok, r} = FrontOfMind.set("agent", String.duplicate("🌱", 1000), opts)
    assert r["written_at"]
    assert {:ok, ^r} = Task.async(fn -> FrontOfMind.get("agent", opts) end) |> Task.await()

    for value <- ["", String.duplicate("x", 1001), nil, <<255>>] do
      assert {:error, :note_must_be_1_to_1000_characters} = FrontOfMind.set("agent", value, opts)
    end

    assert {:ok, %{"text" => nil}} = FrontOfMind.clear("agent", opts)
  end

  test "initial bob attributes own note, unchanged prefix, token distance on every call", %{
    s: s,
    opts: opts
  } do
    FrontOfMind.set("agent", "do not forget", opts)
    FrontOfMind.configure("agent", [threshold_tokens: 100], opts)
    s1 = FrontOfMind.before_call(s, opts)
    assert length(s1.transcript) == 1
    note = hd(s1.transcript)["content"]
    assert note =~ "Your own saved note"
    assert note =~ "not an operator instruction"
    assert note =~ "do not forget"
    assert_receive {:front_of_mind_configuration, _}
    assert_receive {:front_of_mind_bob, %{reason: "new_or_compacted"}}
    assert FrontOfMind.before_call(s1, opts) == s1 |> Map.update!(:front_of_mind_calls, &(&1 + 1))

    grown = %{
      s1
      | transcript:
          s1.transcript ++ [%{"role" => "tool", "content" => String.duplicate("x", 400)}]
    }

    s2 = FrontOfMind.before_call(grown, opts)
    assert Enum.take(s2.transcript, 2) == grown.transcript
    assert length(s2.transcript) == 3
    assert_receive {:front_of_mind_bob, %{reason: "token_distance", estimated_distance_tokens: d}}
    assert d >= 100
  end

  test "replacement, compaction, disabled and clear behavior", %{s: s, opts: opts} do
    FrontOfMind.set("agent", "first", opts)
    s = FrontOfMind.before_call(s, opts)
    FrontOfMind.set("agent", "second", opts)
    s = FrontOfMind.before_call(s, opts)
    assert List.last(s.transcript)["content"] =~ "second"
    assert_receive {:front_of_mind_bob, %{reason: "note_changed"}}

    compact =
      %{s | transcript: [%{"role" => "user", "content" => "checkpoint"}]}
      |> FrontOfMind.after_compaction()

    bobbed = FrontOfMind.before_call(compact, opts)
    assert length(bobbed.transcript) == 2
    FrontOfMind.configure("agent", [enabled: false], opts)
    assert FrontOfMind.before_call(compact, opts).transcript == compact.transcript
    FrontOfMind.configure("agent", [enabled: true], opts)
    assert length(FrontOfMind.before_call(compact, opts).transcript) == 2
    FrontOfMind.clear("agent", opts)
    assert FrontOfMind.before_call(compact, opts).transcript == compact.transcript
  end

  test "configuration validation rejects unknown and unsafe dials", %{opts: opts} do
    for config <- [
          [enabled: 1],
          [threshold_tokens: 0],
          [threshold_tokens: 1.1],
          [drift_every_calls: 0],
          [drift_threshold: 1.01],
          [unexpected: true]
        ] do
      assert {:error, :invalid_configuration} = FrontOfMind.configure("agent", config, opts)
    end

    assert {:ok, _} = FrontOfMind.configure("agent", [enabled: false], opts)
  end

  test "drift judgment is logged, triggers one bob, never rewrites note", %{s: s, opts: opts} do
    FrontOfMind.set("agent", "goal", opts)
    FrontOfMind.configure("agent", [drift_enabled: true], opts)
    s = FrontOfMind.before_call(s, opts)
    {:ok, record} = FrontOfMind.get("agent", opts)

    assert {:ok, updated} =
             FrontOfMind.check_drift(
               s,
               record,
               "activity",
               Keyword.put(opts, :judge, fn "goal", "activity" -> {:ok, 0.9} end)
             )

    assert updated["text"] == "goal"
    assert_receive {:front_of_mind_drift, %{probability: 0.9, stored: true}}
    s2 = FrontOfMind.before_call(s, opts)
    assert List.last(s2.transcript)["content"] =~ "drift probability 0.9"
    assert_receive {:front_of_mind_bob, %{reason: "likely_drift", probability: 0.9}}
    assert FrontOfMind.before_call(s2, opts).transcript == s2.transcript
    FrontOfMind.set("agent", "new goal", opts)

    assert {:error, :stale_note} =
             FrontOfMind.check_drift(
               s,
               record,
               "",
               Keyword.put(opts, :judge, fn _, _ -> {:ok, 0.99} end)
             )

    assert {:ok, %{"text" => "new goal"} = record} = FrontOfMind.get("agent", opts)
    refute Map.has_key?(record, "drift")
  end

  test "judgment failure is explicit and logged; periodic work bounded and off by default", %{
    s: s,
    opts: opts
  } do
    FrontOfMind.set("agent", "goal", opts)
    parent = self()
    opts = Keyword.put(opts, :drift_runner, fn job -> send(parent, {:job, job}) end)
    s = FrontOfMind.before_call(s, opts)
    refute_receive {:job, _}
    FrontOfMind.configure("agent", [drift_enabled: true, drift_every_calls: 1], opts)
    s = FrontOfMind.before_call(s, opts)
    assert_receive {:job, job}
    assert is_function(job, 0)
    FrontOfMind.before_call(s, opts)
    refute_receive {:job, _}
    {:ok, r} = FrontOfMind.get("agent", opts)

    for result <- [{:error, :timeout}, {:ok, 2.0}, {:ok, "yes"}] do
      assert {:error, :judgment_failed} =
               FrontOfMind.check_drift(s, r, "", Keyword.put(opts, :judge, fn _, _ -> result end))

      assert_receive {:front_of_mind_drift, %{error: _}}
    end
  end

  test "missing notes leave state unchanged; reusable bobbing policy catches shrink", %{
    s: s,
    opts: opts
  } do
    assert FrontOfMind.before_call(s, opts) == s

    assert {false, 9, "below_threshold"} =
             FrontOfMind.Bobbing.due?(%{tokens: 1, version: 1}, 10, 1, 10, false)

    assert {true, 10, "token_distance"} =
             FrontOfMind.Bobbing.due?(%{tokens: 1, version: 1}, 11, 1, 10, false)

    assert {true, 0, "context_rebuilt"} =
             FrontOfMind.Bobbing.due?(%{tokens: 10, version: 1}, 1, 1, 10, false)
  end
end

defmodule Seedling.FrontOfMindTest do
  use ExUnit.Case, async: true
  alias Seedling.{FrontOfMind, Goals, Bobbing, DurableStore}

  setup do
    root =
      Path.join(System.tmp_dir!(), "atlas-mind-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [root: root]}
  end

  test "note is bounded in characters, replaced, timestamped, durable and clearable", ctx do
    assert {:ok, note} = FrontOfMind.set("alice", String.duplicate("🐣", 1_000), ctx.opts)
    assert String.length(note.note) == 1_000
    assert {:ok, _, _} = DateTime.from_iso8601(note.written_at)

    assert {:error, :note_too_long} =
             FrontOfMind.set("alice", String.duplicate("a", 1_001), ctx.opts)

    assert {:error, :empty_note} = FrontOfMind.set("alice", "  ", ctx.opts)
    assert {:error, :invalid_note} = FrontOfMind.set("alice", <<255>>, ctx.opts)
    assert {:ok, saved} = FrontOfMind.get("alice", ctx.opts ++ [refresh: true])
    assert saved == note
    assert {:ok, updated} = FrontOfMind.set("alice", "Replacement", ctx.opts)
    assert updated.revision > note.revision
    assert {:ok, nil} = FrontOfMind.clear("alice", ctx.opts)
    assert {:ok, %{note: nil}} = FrontOfMind.get("alice", ctx.opts ++ [refresh: true])
    assert {:ok, %{messages: []}} = FrontOfMind.before_call("alice", 20_000, ctx.opts)
  end

  test "initial, distance, replacement and compaction bobs include measured own-note metadata",
       ctx do
    {:ok, note} = FrontOfMind.set("alice", "Keep scope narrow", ctx.opts)
    {:ok, config} = FrontOfMind.configure("alice", [threshold: 100], ctx.opts)
    assert config["drift"] == false

    assert {:ok, %{messages: [message], events: [config_event, first]}} =
             FrontOfMind.before_call("alice", 20, ctx.opts)

    assert config_event.type == :bobbing_config
    assert first.reason == "initial"
    assert first.source_written_at == note.written_at
    assert first.estimated_bob_tokens > 0
    assert message =~ "Agent's own front of mind reminder"
    assert message =~ "not an operator instruction"
    assert {:ok, %{messages: []}} = FrontOfMind.before_call("alice", 120, ctx.opts)
    assert {:ok, %{events: [distance]}} = FrontOfMind.before_call("alice", 121, ctx.opts)
    assert distance.reason == "distance"
    assert distance.distance_tokens == 101
    FrontOfMind.set("alice", "New priority", ctx.opts)

    assert {:ok, %{events: [%{reason: "updated"}]}} =
             FrontOfMind.before_call("alice", 122, ctx.opts)

    assert {:ok, %{messages: [text], events: [%{reason: "compaction"}]}} =
             FrontOfMind.before_call("alice", 10, ctx.opts ++ [compacted: true])

    assert text =~ "New priority"
    assert {:ok, %{events: []}} = FrontOfMind.before_call("alice", 11, ctx.opts)

    assert {:ok, %{events: [%{reason: "context_reset"}]}} =
             FrontOfMind.before_call("alice", 0, ctx.opts)

    assert {:error, :invalid_token_tip} = FrontOfMind.before_call("alice", -1, ctx.opts)
  end

  test "independent toggles persist and configuration changes are logged", ctx do
    FrontOfMind.set("alice", "Remember", ctx.opts)
    assert {:error, :invalid_config} = FrontOfMind.configure("alice", [threshold: 0], ctx.opts)
    assert {:error, :invalid_config} = FrontOfMind.configure("alice", [unknown: true], ctx.opts)

    assert {:ok, _} =
             FrontOfMind.configure(
               "alice",
               [bobbing: false, goals: false, drift: false],
               ctx.opts
             )

    assert {:ok, %{messages: [], events: [%{type: :bobbing_config}]}} =
             FrontOfMind.before_call("alice", 5_000, ctx.opts ++ [compacted: true])

    assert {:ok, %{config: %{"bobbing" => false}}} =
             FrontOfMind.get("alice", ctx.opts ++ [refresh: true])

    FrontOfMind.configure("alice", [bobbing: true], ctx.opts)
    assert {:ok, %{messages: [_]}} = FrontOfMind.before_call("alice", 5_001, ctx.opts)
  end

  test "goals reuse the policy without copying the goal into the note", ctx do
    {:ok, goal} = Goals.create("alice", [title: "Ship", why: "Operators need it"], ctx.opts)
    Goals.create("alice", [title: "Test", why: "Safety", parent_id: goal["id"]], ctx.opts)
    assert {:ok, %{messages: []}} = FrontOfMind.before_call("alice", 100, ctx.opts)
    FrontOfMind.configure("alice", [goals: true], ctx.opts)

    assert {:ok, %{messages: [message], events: [_, bob]}} =
             FrontOfMind.before_call("alice", 101, ctx.opts)

    assert bob.source == "goals"
    assert message =~ "Current goal: Ship"
    assert message =~ "Next step: Test"
    assert {:ok, %{note: nil}} = FrontOfMind.get("alice", ctx.opts)
  end

  test "drift is bounded, occasional, measured and never changes the note", ctx do
    me = self()
    FrontOfMind.set("alice", "Build goals", ctx.opts)

    FrontOfMind.configure(
      "alice",
      [drift: true, drift_interval: 100, threshold: 10_000],
      ctx.opts
    )

    adapter = fn note, activity ->
      send(me, {:judged, note, activity})
      {:ok, %{probability: 0.9, model: "fake", usage: %{"input_tokens" => 42}}}
    end

    opts = ctx.opts ++ [recent_activity: String.duplicate("x", 3_000), drift_adapter: adapter]
    assert {:ok, %{events: [_, judgement, bob]}} = FrontOfMind.before_call("alice", 100, opts)
    assert judgement.type == :drift_judgement
    assert judgement.probability == 0.9
    assert judgement.usage == %{"input_tokens" => 42}
    assert is_integer(judgement.latency_ms)
    assert bob.drift_probability == 0.9
    assert_receive {:judged, "Build goals", activity}
    assert String.length(activity) == 2_000
    assert {:ok, %{events: []}} = FrontOfMind.before_call("alice", 200, opts)
    refute_receive {:judged, _, _}, 10
    assert {:ok, %{events: [_, %{reason: "drift"}]}} = FrontOfMind.before_call("alice", 201, opts)
    assert {:ok, %{note: "Build goals"}} = FrontOfMind.get("alice", ctx.opts)
  end

  test "missing drift credentials and bad adapters are explicit, not fake probabilities", ctx do
    FrontOfMind.set("alice", "Note", ctx.opts)
    FrontOfMind.configure("alice", [drift: true, bobbing: false], ctx.opts)
    opts = ctx.opts ++ [recent_activity: "Work", drift_options: [api_key: nil]]

    assert {:ok, %{messages: [], events: [_, error]}} =
             FrontOfMind.before_call("alice", 100, opts)

    assert error.status == "unavailable"
    assert error.reason == ":missing_credentials"
    refute Map.has_key?(error, :probability)

    assert {:ok, %{events: [%{reason: ":adapter_failed"}]}} =
             FrontOfMind.before_call(
               "alice",
               3_000,
               ctx.opts ++ [recent_activity: "Work", drift_adapter: fn _, _ -> raise "bad" end]
             )
  end

  test "an adapter can use other libraries without blocking storage and stale judgements do not steer a new note",
       ctx do
    FrontOfMind.set("alice", "Old priority", ctx.opts)
    FrontOfMind.configure("alice", [drift: true], ctx.opts)

    adapter = fn _, _ ->
      assert {:ok, _} =
               Goals.create("bob", [title: "Other agent", why: "Does not deadlock"], ctx.opts)

      FrontOfMind.set("alice", "New priority", ctx.opts)
      {:ok, %{probability: 0.99}}
    end

    assert {:ok, %{messages: [text], events: [_, judgement, bob]}} =
             FrontOfMind.before_call(
               "alice",
               100,
               ctx.opts ++ [recent_activity: "Activity", drift_adapter: adapter]
             )

    assert text =~ "New priority"
    assert judgement.status == "superseded"
    assert bob.drift_probability == nil
  end

  test "corrupt note documents are reported and unchanged",
       ctx do
    {:ok, path} = DurableStore.path("front_of_mind", "alice", ctx.opts)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}")

    assert {:error, :invalid_note_document} =
             FrontOfMind.set("alice", "Do not overwrite", ctx.opts)

    assert File.read!(path) == "{}"
  end

  test "pure bobbing hook preserves cursor when disabled and strict threshold boundary" do
    source = %{source: "test", text: "Own words", version: 1, written_at: "now"}
    assert {:skip, %{}} = Bobbing.check(source, %{}, 99, enabled: false)
    assert {:bob, cursor, %{reason: "initial"}} = Bobbing.check(source, %{}, 100, threshold: 50)
    assert {:skip, ^cursor} = Bobbing.check(source, cursor, 150, threshold: 50)
    assert {:bob, _, %{distance_tokens: 51}} = Bobbing.check(source, cursor, 151, threshold: 50)
    assert {:skip, ^cursor} = Bobbing.check(nil, cursor, 1_000)
  end
end

defmodule Seedling.FrontOfMindTest do
  use ExUnit.Case, async: true
  alias Seedling.{FrontOfMind, CapabilityStore, Bobbing, Goals}

  setup do
    root = Path.join(System.tmp_dir!(), "orion-bob-" <> CapabilityStore.id())
    name = "bob-" <> CapabilityStore.id()
    s = %{name: name, id: name, transcript: [], request_id: 0}
    on_exit(fn -> File.rm_rf(root) end)
    %{opts: [root: root], s: s}
  end

  test "unicode limit, attribution, token-distance mid-turn bob and compaction reset", %{
    s: s,
    opts: opts
  } do
    assert {:error, :note_must_be_1_to_1000_characters} =
             FrontOfMind.set(s.name, String.duplicate("界", 1001), opts)

    assert {:ok, :ok} = FrontOfMind.set(s.name, "Stay within budget", opts)
    assert {:ok, :ok} = FrontOfMind.configure(s.name, [threshold: 100], opts)
    first = FrontOfMind.before_request(s, opts)
    assert length(first.transcript) == 1
    assert hd(first.transcript)["content"] =~ "#{s.name}'s own note"
    assert hd(first.transcript)["content"] =~ "not an outside instruction"
    assert FrontOfMind.before_request(first, opts) == first

    second =
      Map.update!(
        first,
        :transcript,
        &(&1 ++ [%{"role" => "assistant", "content" => String.duplicate("x", 300)}])
      )
      |> FrontOfMind.before_request(opts)

    assert length(second.transcript) == 3
    entries = Nano.Log.read(s.id)
    assert Enum.count(entries, &(&1["type"] == "context_bob")) == 2
    assert List.last(entries)["distance_tokens"] >= 100

    compacted =
      %{second | transcript: [%{"role" => "user", "content" => "summary"}]}
      |> Bobbing.reset()
      |> FrontOfMind.before_request(opts)

    assert length(compacted.transcript) == 2
    assert {:ok, :ok} = FrontOfMind.clear(s.name, opts)
    assert FrontOfMind.before_request(compacted, opts) == compacted
  end

  test "off comparison retains note and goals independently opt into reusable bobbing", %{
    s: s,
    opts: opts
  } do
    assert {:ok, :ok} = FrontOfMind.set(s.name, "Keep it cheap", opts)
    assert {:ok, :ok} = FrontOfMind.configure(s.name, [enabled: false], opts)
    assert FrontOfMind.before_request(s, opts) == s
    assert {:ok, %{"note" => "Keep it cheap"}} = FrontOfMind.get(s.name, opts)
    assert {:ok, _} = Goals.create(s.name, "Test", "Evidence", opts)
    assert {:ok, :ok} = Goals.configure(s.name, [bobbing: true], opts)
    result = FrontOfMind.before_request(s, opts)
    assert hd(result.transcript)["content"] =~ "own open goals"
    assert hd(result.transcript)["content"] =~ "Evidence"
  end
end

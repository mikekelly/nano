defmodule FrontMindTest do
  use ExUnit.Case, async: true

  setup do
    name = "mind-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    on_exit(fn ->
      File.rm(
        Path.join([Application.fetch_env!(:nano, :state_dir), "frontmind", name <> ".json"])
      )
    end)

    %{name: name}
  end

  test "limits count Unicode characters, replacement and clear persist", %{name: name} do
    note = String.duplicate("界", 1000)
    assert {:ok, first} = FrontMind.set(name, note)
    assert first.note == note
    assert {:ok, ^first} = FrontMind.get(name)
    assert {:error, :note_must_be_1_to_1000_characters} = FrontMind.set(name, note <> "x")
    assert {:error, _} = FrontMind.set(name, " ")
    assert {:error, _} = FrontMind.set(name, <<255>>)
    assert {:ok, second} = FrontMind.set(name, "new")
    assert second.version != first.version
    assert second.written_at != nil
    assert {:ok, %{note: nil}} = FrontMind.clear(name)
    assert {:ok, %{note: nil}} = FrontMind.get(name)
  end

  test "controls are independent and reject invalid values", %{name: name} do
    assert {:ok, data} =
             FrontMind.configure(name, bobbing: false, drift: true, threshold_tokens: 42)

    assert data.drift and not data.bobbing
    assert {:ok, ^data} = FrontMind.get(name)

    for options <- [[threshold_tokens: 0], [drift: 1], [unknown: true]] do
      assert {:error, :invalid_configuration} = FrontMind.configure(name, options)
    end

    assert {:error, :invalid_agent} = FrontMind.set("../escape", "bad")
  end

  test "corrupt files do not crash callers or get silently overwritten", %{name: name} do
    path = Path.join([Application.fetch_env!(:nano, :state_dir), "frontmind", name <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"note":"valid", "threshold_tokens":"bad"}))
    assert {:error, :invalid_frontmind_file} = FrontMind.get(name)
    assert {:error, :invalid_frontmind_file} = FrontMind.set(name, "replacement")
    assert File.read!(path) =~ "bad"
  end

  test "parallel modifications do not lose independent fields", %{name: name} do
    tasks = [
      Task.async(fn -> FrontMind.set(name, "note") end),
      Task.async(fn -> FrontMind.configure(name, threshold_tokens: 21) end)
    ]

    Enum.each(tasks, &Task.await/1)
    assert {:ok, %{note: "note", threshold_tokens: 21}} = FrontMind.get(name)
  end
end

defmodule ContextBobTest do
  use ExUnit.Case, async: true

  test "token suffix, exact threshold, append-only prefix and changed source" do
    source = %{key: :note, text: "own note", version: 1, threshold_tokens: 50}
    original = [%{"role" => "user", "content" => "first"}]
    {first, cursors, [%{reason: :first}]} = Nano.ContextBob.apply(original, %{}, [source])
    assert Enum.take(first, 1) == original
    assert {^first, ^cursors, []} = Nano.ContextBob.apply(first, cursors, [source])
    growth = %{"role" => "assistant", "content" => String.duplicate("a", 100)}
    grown = first ++ [growth]
    distance = Nano.ContextBob.tokens(growth)
    assert distance == Nano.ContextBob.distance(grown, cursors.note)

    {bobbed, _, [%{reason: :distance, distance_tokens: ^distance}]} =
      Nano.ContextBob.apply(grown, cursors, [%{source | threshold_tokens: distance}])

    assert Enum.take(bobbed, length(grown)) == grown

    assert {_, _, [%{reason: :changed}]} =
             Nano.ContextBob.apply(first, cursors, [%{source | version: 2}])

    assert {_, _, [%{reason: :missing_anchor}]} =
             Nano.ContextBob.apply(original, cursors, [source])

    assert {_, _, [%{reason: :compaction}]} =
             Nano.ContextBob.apply(first, cursors, [source], true)
  end

  test "image references count visual context, not just short hash JSON" do
    source = %{key: :note, text: "own note", version: 1, threshold_tokens: 8000}
    {first, cursors, _} = Nano.ContextBob.apply([], %{}, [source])

    image = %{
      "role" => "user",
      "content" => [
        %{"type" => "image_ref", "image_ref" => %{"hash" => String.duplicate("a", 64)}}
      ]
    }

    text_only_estimate = div(byte_size(Jason.encode!(image)) + 1, 2)
    assert Nano.ContextBob.tokens(image) == text_only_estimate + 4800
    assert Nano.ContextBob.tokens(image) == div(Nano.ImageInput.estimated_bytes(image) + 1, 2)
    assert {_, _, []} = Nano.ContextBob.apply(first ++ [image], cursors, [source])
    grown = first ++ [image, image]
    distance = 2 * Nano.ContextBob.tokens(image)

    {bobbed, _, [%{reason: :distance, distance_tokens: ^distance}]} =
      Nano.ContextBob.apply(grown, cursors, [source])

    assert Enum.take(bobbed, length(grown)) == grown
    assert distance > source.threshold_tokens
  end

  test "multiple sources bob independently" do
    sources =
      for key <- [:note, :goal],
          do: %{key: key, text: to_string(key), version: 1, threshold_tokens: 10000}

    {t, c, events} = Nano.ContextBob.apply([], %{}, sources)
    assert length(events) == 2
    assert length(t) == 2
    assert {^t, ^c, []} = Nano.ContextBob.apply(t, c, sources)
  end
end

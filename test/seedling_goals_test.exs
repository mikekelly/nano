defmodule Seedling.GoalsTest do
  use ExUnit.Case, async: true
  alias Seedling.Goals

  setup do
    root =
      Path.join(System.tmp_dir!(), "lyra-goals-" <> Base.encode16(:crypto.strong_rand_bytes(10)))

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [root: root], root: root}
  end

  test "tree, why, updates and durable reread", %{opts: opts} do
    assert {:ok, []} = Goals.list("agent", opts)
    assert {:ok, parent} = Goals.add("agent", "Build", [why: "durability"] ++ opts)

    assert {:ok, child} =
             Goals.add("agent", "Test", [parent: parent.id, why: "confidence"] ++ opts)

    assert {:ok, [%{children: [%{id: id}]}]} = Goals.tree("agent", opts)
    assert id == child.id
    assert {:ok, text} = Goals.review("agent", opts)
    assert text =~ "durability"
    assert {:ok, _} = Goals.update("agent", parent.id, [status: :done], opts)
    assert %{goals: [%{id: ^id}], error: nil} = Goals.dashboard("agent", opts)
    task = Task.async(fn -> Goals.list("agent", opts) end)
    assert {:ok, [persisted, _]} = Task.await(task)
    assert persisted.status == "done"
    assert persisted.why == "durability"
    assert {:ok, []} = Goals.list("other", opts)
  end

  test "validation and bounded review", %{opts: opts} do
    assert {:error, :parent_not_found} = Goals.add("a", "orphan", [parent: "missing"] ++ opts)
    assert {:ok, g} = Goals.add("a", "goal", opts)
    assert {:error, :invalid_fields} = Goals.update("a", g.id, [parent: g.id], opts)
    assert {:error, :invalid_goal} = Goals.update("a", g.id, [status: :unknown], opts)
    assert {:ok, summary} = Goals.review("a", [limit: 0] ++ opts)
    assert summary =~ "1 more"
  end

  test "concurrent writers do not lose updates", %{opts: opts} do
    1..20
    |> Task.async_stream(fn n -> Goals.add("a", "goal #{n}", opts) end,
      max_concurrency: 5,
      timeout: 30_000
    )
    |> Enum.each(fn r -> assert {:ok, {:ok, _}} = r end)

    assert {:ok, goals} = Goals.list("a", opts)
    assert length(goals) == 20
  end

  test "corruption is surfaced", %{opts: opts, root: root} do
    Goals.add("a", "goal", opts)
    [file] = Path.wildcard(Path.join(root, "*.json"))
    File.write!(file, "not json")
    assert {:error, :corrupt} = Goals.list("a", opts)
    assert %{error: ":corrupt"} = Goals.dashboard("a", opts)
  end

  test "index sorts fragments and writes NOTES", %{root: root} do
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "docs/seedling-z.md"), "Z capability")
    File.write!(Path.join(root, "docs/seedling-a.md"), "A capability")
    assert {:ok, text} = Seedling.Index.render(root: root)
    assert text =~ ~r/A capability.*Z capability/s
    assert {:ok, file} = Seedling.Index.generate(root: root)
    assert File.read!(file) == text
  end
end

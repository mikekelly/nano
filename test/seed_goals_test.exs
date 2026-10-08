defmodule SeedGoalsTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "seed-goals-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [root: root]}
  end

  test "tree survives reads and enforces closure", %{opts: opts} do
    {:ok, p} = SeedGoals.add("a", "parent", [why: "reason"] ++ opts)
    {:ok, c} = SeedGoals.add("a", "child", [parent: p["id"], next: "test"] ++ opts)
    assert {:error, :open_children} = SeedGoals.update("a", p["id"], [status: :done], opts)
    assert {:ok, _} = SeedGoals.update("a", c["id"], [status: :done], opts)
    assert {:ok, _} = SeedGoals.update("a", p["id"], [status: :done], opts)
    assert {:ok, %{open: 0}} = SeedGoals.review("a", opts)
    assert {:ok, _} = SeedGoals.update("a", c["id"], [status: :active], opts)
    assert {:ok, %{open: 2, items: [first | _]}} = SeedGoals.review("a", opts)
    assert first["id"] == c["id"]
    assert {:ok, %{total: 0}} = SeedGoals.review("other", opts)
  end

  test "bounded review, invalid input, concurrent writes", %{opts: opts} do
    assert {:error, :invalid_goal} = SeedGoals.add("a", "", opts)
    assert {:error, :parent_not_found} = SeedGoals.add("a", "x", [parent: "missing"] ++ opts)

    1..30
    |> Task.async_stream(fn n -> SeedGoals.add("a", "goal #{n}", opts) end, max_concurrency: 8)
    |> Enum.each(fn {:ok, result} -> assert {:ok, _} = result end)

    assert {:ok, %{total: 30, truncated: true, items: items}} = SeedGoals.review("a", opts)
    assert length(items) == 5
  end

  test "memory replaces, reviews and refuses corrupt storage", %{opts: opts} do
    assert {:ok, _} = SeedMemory.put("../a", "key", "fact", [why: "reason"] ++ opts)
    assert {:ok, _} = SeedMemory.put("../a", "key", "new", opts)
    assert {:ok, %{"text" => "new"}} = SeedMemory.get("../a", "key", opts)
    assert {:ok, %{total: 1}} = SeedMemory.review("../a", opts)
    path = SeedMemory.Store.path("../a", "memory", opts)
    File.write!(path, "invalid")
    assert {:error, _} = SeedMemory.put("../a", "key", "lost", opts)
    assert File.read!(path) == "invalid"
  end
end

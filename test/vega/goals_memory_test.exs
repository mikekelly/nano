defmodule Vega.GoalsMemoryTest do
  use ExUnit.Case, async: true
  alias Vega.{Goals, Memory, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "vega-goals-test-" <> Store.id())
    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [root: root]}
  end

  test "fresh identity, restart-independent trees and bounded why review", %{opts: o} do
    assert {:ok, []} = Goals.list("alice", o)
    assert {:ok, g} = Goals.add("alice", "Ship", [why: "Import data"] ++ o)
    assert {:ok, c} = Goals.add("alice", "Test", [parent_id: g["id"], why: "Safety"] ++ o)
    assert {:ok, %{"status" => "active"}} = Goals.update("alice", g["id"], %{status: "active"}, o)

    assert {:ok, [%{"steps" => [%{"id" => child}]}]} =
             Task.async(fn -> Goals.tree("alice", o) end) |> Task.await()

    assert child == c["id"]

    assert {:ok,
            %{
              goals: [%{"why" => "Import data"}],
              omitted: 1,
              counts: %{"active" => 1, "pending" => 1}
            }} = Goals.review("alice", [limit: 1] ++ o)

    assert {:ok, _} = Goals.update("alice", g["id"], [status: "done"], o)
    assert {:ok, [^c]} = Goals.list("alice", [open_only: true] ++ o)
  end

  test "cycles, orphan parents and immutable fields rejected", %{opts: o} do
    {:ok, g} = Goals.add("a", "root", o)
    {:ok, c} = Goals.add("a", "child", [parent_id: g["id"]] ++ o)
    assert {:error, :cycle} = Goals.update("a", g["id"], [parent_id: c["id"]], o)
    assert {:error, :cycle} = Goals.update("a", g["id"], [parent_id: g["id"]], o)
    assert {:error, :parent_not_found} = Goals.add("a", "bad", [parent_id: "no"] ++ o)
    assert {:error, :invalid_fields} = Goals.update("a", g["id"], [id: "new"], o)
    assert {:error, :not_found} = Goals.update("a", "missing", [title: "x"], o)
    assert {:ok, %{"parent_id" => nil}} = Goals.get("a", g["id"], o)
  end

  test "deletion explicit cascade", %{opts: o} do
    {:ok, g} = Goals.add("a", "root", o)
    {:ok, c} = Goals.add("a", "child", [parent_id: g["id"]] ++ o)
    Goals.add("a", "grandchild", [parent_id: c["id"]] ++ o)
    assert {:error, :has_children} = Goals.delete("a", g["id"], o)
    assert {:ok, :deleted} = Goals.delete("a", g["id"], [cascade: true] ++ o)
    assert {:ok, []} = Goals.tree("a", o)
    assert {:error, :not_found} = Goals.delete("a", g["id"], o)
  end

  test "validation and no writes on error", %{opts: o} do
    assert {:error, :invalid_title} = Goals.add("a", " ", o)
    assert {:error, :invalid_why} = Goals.add("a", "x", [why: nil] ++ o)
    assert {:error, :invalid_status} = Goals.add("a", "x", [status: "unknown"] ++ o)
    assert {:error, :invalid_identity} = Goals.add("", "x", o)
    assert {:error, :invalid_content} = Memory.put("a", "", o)
    assert {:error, :invalid_tags} = Memory.put("a", "x", [tags: [1]] ++ o)
    assert {:error, :invalid_provenance} = Memory.put("a", "x", [provenance: "none"] ++ o)
    assert {:ok, []} = Goals.list("a", o)
  end

  test "identity is stable and path-safe, cross-identity isolated", %{opts: o} do
    assert {:ok, g} = Goals.add("../bob/☃", "x", o)
    assert {:ok, ^g} = Goals.get("../bob/☃", g["id"], o)
    assert {:ok, []} = Goals.list("bob", o)
    {:ok, path} = Store.path("goals", "../bob/☃", o)
    assert Path.dirname(path) == Path.join(o[:root], "goals")
  end

  test "provenance preserved and revision changes with update/delete", %{opts: o} do
    {:ok, m} =
      Memory.put(
        "a",
        "Learned parser",
        [tags: ["elixir"], provenance: %{"source" => "event", "seq" => 23}] ++ o
      )

    {:ok, read} = Task.async(fn -> Memory.get("a", m["id"], o) end) |> Task.await()
    assert read == m
    assert {:ok, n} = Memory.update("a", m["id"], [content: "Corrected parser"], o)
    assert n["revision"] == 2
    assert n["provenance"] == m["provenance"]
    assert n["created_at"] == m["created_at"]
    assert {:error, :invalid_fields} = Memory.update("a", m["id"], [revision: 8], o)
    assert {:ok, :deleted} = Memory.delete("a", m["id"], o)
    assert {:error, :not_found} = Memory.get("a", m["id"], o)
    assert {:ok, []} = Memory.retrieve("a", "parser", o)
  end

  test "retrieval ranks relevance and obeys entire JSON budget", %{opts: o} do
    {:ok, a} = Memory.put("a", "Elixir parser safety", o)
    Memory.put("a", "unrelated music", o)
    Memory.put("a", "Elixir concurrency", o)
    assert {:ok, [^a | _]} = Memory.retrieve("a", "elixir parser", o)
    assert {:ok, []} = Memory.retrieve("a", "missing", o)
    assert {:ok, []} = Memory.retrieve("a", "", [max_bytes: 2] ++ o)
    assert {:ok, result} = Memory.retrieve("a", "", [max_bytes: 450, limit: 1] ++ o)
    assert length(result) <= 1
    assert byte_size(Jason.encode!(result)) <= 450
    assert {:ok, []} = Memory.retrieve("a", "", [limit: 0] ++ o)
  end

  test "parallel same-identity writers lose no records", %{opts: o} do
    for i <- 1..20 do
      Task.async(fn -> Goals.add("a", "goal #{i}", o) end)
    end
    |> Enum.each(fn t -> assert {:ok, _} = Task.await(t, 20_000) end)

    assert {:ok, entries} = Goals.list("a", o)
    assert length(entries) == 20
    assert entries |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 20
  end

  test "corruption is reported, never overwritten", %{opts: o} do
    {:ok, g} = Goals.add("a", "x", o)
    {:ok, path} = Store.path("goals", "a", o)
    File.write!(path, "{bad")
    assert {:error, :corrupt_store} = Goals.review("a", o)
    assert {:error, :corrupt_store} = Goals.update("a", g["id"], [title: "new"], o)
    assert File.read!(path) == "{bad"
  end

  test "structurally corrupt records and graph cycles rejected", %{opts: o} do
    {:ok, g} = Goals.add("a", "x", o)
    {:ok, path} = Store.path("goals", "a", o)

    for entries <- [
          [%{}],
          [Map.put(g, "parent_id", g["id"])],
          [Map.put(g, "parent_id", "missing")],
          [g, g]
        ] do
      File.write!(path, Jason.encode!(%{version: 1, entries: entries}))
      assert {:error, :corrupt_store} = Goals.tree("a", o)
      assert {:error, :corrupt_store} = Goals.add("a", "new", o)
    end
  end

  test "IO failures surfaced", %{opts: o} do
    File.mkdir_p!(o[:root])
    File.write!(Path.join(o[:root], "not-dir"), "x")
    assert {:error, _} = Goals.add("a", "x", root: Path.join(o[:root], "not-dir"))
  end
end

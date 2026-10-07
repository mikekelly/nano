defmodule Nano.GoalsMemoryTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "nova-goals-test-" <> Nano.DurableStore.id())
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, opts: [root: root], root: root}
  end

  test "goals retain rationale, hierarchy and status across writer processes", %{opts: opts} do
    {:ok, parent} =
      Task.async(fn -> Nano.Goals.add("a", "Release", [why: "Help users"] ++ opts) end)
      |> Task.await()

    {:ok, child} =
      Nano.Goals.add("a", "Test", [why: "Find defects", parent: parent["id"]] ++ opts)

    assert child["parent"] == parent["id"]

    assert {:error, :parent_not_found} =
             Nano.Goals.add("a", "bad", [why: "why", parent: "missing"] ++ opts)

    assert {:error, :invalid_title_or_why} = Nano.Goals.add("a", "no why", opts)

    assert {:ok, %{"status" => "done"}} =
             Nano.Goals.update("a", child["id"], [status: :done, note: "Passed"], opts)

    assert {:ok, %{total: 1, goals: [goal], omitted: 0}} = Nano.Goals.review("a", opts)
    assert goal["why"] == "Help users"
    assert {:ok, [_, _]} = Nano.Goals.list("a", opts)
    assert {:ok, []} = Nano.Goals.list("b", opts)

    assert {:error, :invalid_changes} =
             Nano.Goals.update("a", parent["id"], [parent: child["id"]], opts)

    assert {:error, :invalid_changes} =
             Nano.Goals.update("a", parent["id"], [status: :bogus], opts)

    assert {:error, :not_found} = Nano.Goals.update("a", "missing", [status: :done], opts)
  end

  test "concurrent writers do not lose goals or memories", %{opts: opts} do
    results =
      1..40
      |> Task.async_stream(
        fn i ->
          {:ok, _} = Nano.Goals.add("same", "Goal #{i}", [why: "Important"] ++ opts)
          Nano.Memory.put("same", "key#{i}", "Fact #{i}", opts)
        end,
        max_concurrency: 20,
        timeout: 30_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert {:ok, goals} = Nano.Goals.list("same", opts)
    assert length(goals) == 40

    assert {:ok, %{total: 40, omitted: 37, goals: goals}} =
             Nano.Goals.review("same", [limit: 3] ++ opts)

    assert length(goals) == 3
    assert {:ok, %{total: 40, omitted: 32}} = Nano.Memory.review("same", opts)
  end

  test "memory recall, replacement, search and forgetting", %{opts: opts} do
    {:ok, first} =
      Nano.Memory.put(
        "a",
        "test",
        "Long " <> String.duplicate("x", 1000),
        [why: "Regression", tags: ["QA"]] ++ opts
      )

    assert {:ok, %{total: 1, memories: [excerpt]}} =
             Nano.Memory.review("a", [query: "qa"] ++ opts)

    assert String.length(excerpt["text"]) == 320
    {:ok, next} = Nano.Memory.put("a", "test", "Updated", opts)
    assert next["created_at"] == first["created_at"]
    assert {:ok, ^next} = Nano.Memory.get("a", "test", opts)
    assert {:ok, %{total: 0}} = Nano.Memory.review("a", [query: "absent"] ++ opts)
    assert {:ok, :deleted} = Nano.Memory.forget("a", "test", opts)
    assert {:error, :not_found} = Nano.Memory.get("a", "test", opts)
    assert {:error, :not_found} = Nano.Memory.forget("a", "test", opts)
    assert {:error, :invalid_memory} = Nano.Memory.put("a", "test", "", opts)
  end

  test "bounded reviews and safe path names", %{opts: opts, root: root} do
    owner = "../../" <> String.duplicate("a", 500)

    {:ok, _} =
      Nano.Goals.add(
        owner,
        String.duplicate("t", 1000),
        [why: String.duplicate("w", 8000)] ++ opts
      )

    assert {:ok, %{goals: [g]}} = Nano.Goals.review(owner, opts)
    assert String.length(g["title"]) == 160
    assert String.length(g["why"]) == 240
    assert [path] = Path.wildcard(Path.join(root, "goals/*.json"))
    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "corrupt and oversized stores are errors and never overwritten", %{opts: opts, root: root} do
    {:ok, _} = Nano.Goals.add("a", "Goal", [why: "Why"] ++ opts)
    [path] = Path.wildcard(Path.join(root, "goals/*.json"))
    File.write!(path, "not json")
    assert {:error, :corrupt_store} = Nano.Goals.review("a", opts)
    assert {:error, :corrupt_store} = Nano.Goals.add("a", "New", [why: "Why"] ++ opts)
    assert File.read!(path) == "not json"
    File.write!(path, ~s({"version":1,"entries":{"bad":{}}}))
    assert {:error, :corrupt_store} = Nano.Goals.review("a", opts)
    File.write!(path, String.duplicate("x", 2_000_001))
    assert {:error, :store_too_large} = Nano.Goals.review("a", opts)
  end

  test "snapshots survive independent BEAM boots", %{root: root} do
    paths =
      [Nano.Goals, Jason]
      |> Enum.map(fn mod -> mod |> :code.which() |> List.to_string() |> Path.dirname() end)

    args = Enum.flat_map(paths, &["-pa", &1])
    opts = inspect(root: root)

    write =
      "{:ok, _} = Nano.Goals.add(\"reboot\", \"Deliver\", [why: \"Needed\"] ++ #{opts}); {:ok, _} = Nano.Memory.put(\"reboot\", \"lesson\", \"Remember\", #{opts})"

    read =
      "{:ok, [%{\"why\" => \"Needed\"}]} = Nano.Goals.list(\"reboot\", #{opts}); {:ok, %{\"text\" => \"Remember\"}} = Nano.Memory.get(\"reboot\", \"lesson\", #{opts})"

    # Each child has its own VM; no application env changes in this test's node.
    assert {_, 0} =
             System.cmd("elixir", args ++ ["-e", write],
               env: [{"ERL_FLAGS", "+S 2:2"}],
               stderr_to_stdout: true
             )

    assert {_, 0} =
             System.cmd("elixir", args ++ ["-e", read],
               env: [{"ERL_FLAGS", "+S 2:2"}],
               stderr_to_stdout: true
             )
  end

  test "invalid limits and changes are explicit errors", %{opts: opts} do
    assert {:error, :invalid_limit} = Nano.Goals.review("a", [limit: "no"] ++ opts)
    assert {:error, :invalid_limit} = Nano.Memory.review("a", [limit: 1.5] ++ opts)
    assert {:error, :invalid_changes} = Nano.Goals.update("a", "id", :invalid, opts)
    assert {:error, :invalid_changes} = Nano.Goals.update("a", "id", [status: %{}], opts)
    assert {:error, :invalid_owner} = Nano.Goals.list("", opts)
  end

  test "I/O failures are returned", %{root: root} do
    File.write!(root, "file not directory")
    assert {:error, :enotdir} = Nano.Goals.add("a", "Goal", why: "Why", root: root)
  end
end

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

  test "maximum snapshot rejection preserves committed memory", %{opts: opts, root: root} do
    text = String.duplicate("m", 32_000)

    failed =
      Enum.reduce_while(1..80, nil, fn i, _ ->
        case Nano.Memory.put("full", "key#{i}", text, opts) do
          {:ok, _} -> {:cont, nil}
          {:error, :store_too_large} -> {:halt, i}
          other -> flunk("unexpected write result #{inspect(other)}")
        end
      end)

    assert is_integer(failed) and failed > 1
    [path] = Path.wildcard(Path.join(root, "memory/*.json"))
    committed = File.read!(path)
    assert byte_size(committed) <= 2_000_000
    assert {:error, :store_too_large} = Nano.Memory.put("full", "key#{failed}", text, opts)
    assert File.read!(path) == committed
    assert {:error, :not_found} = Nano.Memory.get("full", "key#{failed}", opts)
    assert {:ok, %{"text" => ^text}} = Nano.Memory.get("full", "key1", opts)
    assert Path.wildcard(Path.join(root, "memory/*.tmp")) == []
  end

  test "readers see only committed snapshots during writes", %{opts: opts} do
    {:ok, _} = Nano.Memory.put("race", "key", "before", opts)

    writer =
      Task.async(fn ->
        for i <- 1..60 do
          assert {:ok, _} = Nano.Memory.put("race", "key", "value#{i}", opts)
          assert {:ok, _} = Nano.Goals.add("race", "Goal #{i}", [why: "Valid"] ++ opts)
        end
      end)

    for _ <- 1..120 do
      assert {:ok, %{"text" => text}} = Nano.Memory.get("race", "key", opts)
      assert text == "before" or String.starts_with?(text, "value")
      assert {:ok, %{goals: _, total: n}} = Nano.Goals.review("race", opts)
      assert n in 0..60
    end

    Task.await(writer, 10_000)
    assert {:ok, %{total: 60}} = Nano.Goals.review("race", opts)
  end

  test "killed transaction owners release locks without changing disk", %{opts: opts} do
    {:ok, old} = Nano.Goals.add("lock", "Original", [why: "Needed"] ++ opts)
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Nano.DurableStore.transact("goals", "lock", opts, fn _ ->
          send(parent, :locked)

          receive do
            :never -> {:error, :never}
          end
        end)
      end)

    assert_receive :locked
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:ok, [^old]} = Nano.Goals.list("lock", opts)

    assert {:ok, _} =
             Task.async(fn -> Nano.Goals.add("lock", "Next", [why: "Continue"] ++ opts) end)
             |> Task.await(2_000)
  end

  test "cancelled parents do not silently cancel children; unicode remains valid", %{opts: opts} do
    {:ok, parent} =
      Nano.Goals.add("a", String.duplicate("🧭", 200), [why: String.duplicate("é", 1000)] ++ opts)

    {:ok, child} =
      Nano.Goals.add("a", "Child", [why: "Independent step", parent: parent["id"]] ++ opts)

    assert {:ok, %{goals: [excerpt]}} = Nano.Goals.review("a", [limit: 1] ++ opts)
    assert String.valid?(excerpt["title"])
    assert String.length(excerpt["title"]) == 160
    assert String.length(excerpt["why"]) == 240
    assert {:ok, _} = Nano.Goals.update("a", parent["id"], [status: :cancelled], opts)
    assert {:ok, %{goals: [g], total: 1}} = Nano.Goals.review("a", opts)
    assert g["id"] == child["id"]
    assert {:ok, %{goals: [], omitted: 1}} = Nano.Goals.review("a", [limit: -1] ++ opts)
    assert {:error, :invalid_memory} = Nano.Memory.put("a", "bad", <<255>>, opts)
  end

  test "schema bound violations and read I/O errors are explicit", %{opts: opts, root: root} do
    {:ok, _} = Nano.Memory.put("a", "key", "Text", opts)
    [path] = Path.wildcard(Path.join(root, "memory/*.json"))
    json = path |> File.read!() |> Jason.decode!()
    entry = json["entries"]["key"] |> Map.put("tags", List.duplicate("tag", 21))
    json = put_in(json, ["entries", "key"], entry)
    File.write!(path, Jason.encode!(json))
    assert {:error, :corrupt_store} = Nano.Memory.review("a", opts)
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, :eisdir} = Nano.Memory.get("a", "key", opts)
  end

  test "I/O failures are returned", %{root: root} do
    File.write!(root, "file not directory")
    assert {:error, :enotdir} = Nano.Goals.add("a", "Goal", why: "Why", root: root)
  end
end

defmodule GoalsTest do
  use ExUnit.Case, async: true

  setup do
    root =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "goals-#{System.unique_integer([:positive])}"
      )

    %{opts: [root: root]}
  end

  defp goal(id, extra \\ %{}),
    do: Map.merge(%{id: id, title: "Do #{id}", why: "Because #{id}"}, extra)

  test "tree and rationale survive writer exit, with explicit cross-owner reads", %{opts: opts} do
    task = Task.async(fn -> Goals.create("parent", goal("root"), opts) end)
    assert {:ok, %{"id" => "root", "revision" => 1}} = Task.await(task)
    assert {:ok, child} = Goals.create("parent", goal("child", %{parent_id: "root"}), opts)
    assert child["why"] == "Because child"
    assert {:ok, [_, _]} = Goals.list("parent", opts)
    assert {:ok, []} = Goals.list("other", opts)
    assert {:ok, %{"parent_id" => "root"}} = Goals.get("parent", "child", opts)
    assert {:ok, []} = Goals.list("parent", root: opts[:root] <> "-other")
  end

  test "patches preserve fields, revisions reject stale edits, closed parents do not hide children",
       %{opts: opts} do
    assert {:ok, _} = Goals.create("a", goal("p"), opts)
    assert {:ok, _} = Goals.create("a", goal("c", %{parent_id: "p"}), opts)
    assert {:ok, updated} = Goals.update("a", "p", %{"status" => "done"}, opts)
    assert updated["why"] == "Because p"
    assert updated["revision"] == 2

    assert {:error, :conflict} =
             Goals.update("a", "p", %{title: "stale"}, opts ++ [expected_revision: 1])

    assert {:ok, %{goals: [%{"id" => "c"}], total: 1}} = Goals.open("a", opts)

    assert {:ok, %{"revision" => 3}} =
             Goals.update("a", "p", %{status: :open}, opts ++ [expected_revision: 2])
  end

  test "invalid creates and patches leave durable state untouched", %{opts: opts} do
    assert {:error, :invalid_goal} = Goals.create("a", %{title: "missing why"}, opts)
    assert {:error, :invalid_attributes} = Goals.create("a", %{"title" => "y", title: "x"}, opts)
    assert {:ok, first} = Goals.create("a", goal("p"), opts)
    assert {:error, :already_exists} = Goals.create("a", goal("p"), opts)

    for patch <- [
          %{why: " "},
          %{title: String.duplicate("a", 513)},
          %{status: :unknown},
          %{why: <<255>>}
        ] do
      assert {:error, :invalid_goal} = Goals.update("a", "p", patch, opts)
    end

    assert {:error, :invalid_attributes} = Goals.update("a", "p", %{id: "q"}, opts)
    assert {:error, :not_found} = Goals.update("a", "missing", %{title: "q"}, opts)
    assert {:ok, ^first} = Goals.get("a", "p", opts)
  end

  test "reparenting validates missing parents and cycles atomically", %{opts: opts} do
    assert {:ok, _} = Goals.create("a", goal("p"), opts)
    assert {:ok, _} = Goals.create("a", goal("c", %{parent_id: "p"}), opts)
    assert {:error, :cycle} = Goals.update("a", "p", %{parent_id: "c"}, opts)
    assert {:error, :cycle} = Goals.update("a", "p", %{parent_id: "p"}, opts)
    assert {:error, :parent_not_found} = Goals.update("a", "c", %{parent_id: "missing"}, opts)

    assert {:error, :parent_not_found} =
             Goals.create("a", goal("bad", %{parent_id: "missing"}), opts)

    assert {:ok, %{"parent_id" => nil}} = Goals.update("a", "c", %{parent_id: nil}, opts)
    assert {:ok, _} = Goals.update("a", "p", %{parent_id: "c"}, opts)
  end

  test "concurrent additions and field patches do not lose updates or other memory", %{opts: opts} do
    assert {:ok, "keep"} = Memory.put("a", "unrelated", "keep", opts)
    tasks = for n <- 1..24, do: Task.async(fn -> Goals.create("a", goal("g#{n}"), opts) end)
    assert Enum.all?(Task.await_many(tasks, 30_000), &match?({:ok, _}, &1))
    assert {:ok, goals} = Goals.list("a", opts)
    assert length(goals) == 24

    tasks =
      for patch <- [%{title: "new title"}, %{why: "new why"}, %{status: :blocked}],
          do: Task.async(fn -> Goals.update("a", "g1", patch, opts) end)

    assert Enum.all?(Task.await_many(tasks, 30_000), &match?({:ok, _}, &1))

    assert {:ok,
            %{"title" => "new title", "why" => "new why", "status" => "blocked", "revision" => 4}} =
             Goals.get("a", "g1", opts)

    assert {:ok, "keep"} = Memory.get("a", "unrelated", opts)
  end

  test "simultaneous reciprocal reparenting cannot create a cycle", %{opts: opts} do
    for id <- ["p", "c"], do: assert({:ok, _} = Goals.create("a", goal(id), opts))

    tasks =
      for {id, parent} <- [{"p", "c"}, {"c", "p"}],
          do: Task.async(fn -> Goals.update("a", id, %{parent_id: parent}, opts) end)

    results = Task.await_many(tasks)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :cycle} in results
    assert {:ok, [_, _]} = Goals.list("a", opts)
  end

  test "summary is bounded UTF-8 and shows rationale, ancestry, counts and omission", %{
    opts: opts
  } do
    assert {:ok, empty} = Goals.summary("a", opts)
    assert empty =~ "Open goals: 0"

    for n <- 1..5 do
      assert {:ok, _} = Goals.create("a", goal("g#{n}", %{why: String.duplicate("理", 200)}), opts)
    end

    assert {:ok, _} = Goals.update("a", "g5", %{status: :in_progress}, opts)
    assert {:ok, %{goals: [%{"id" => "g5"}], omitted: 4}} = Goals.open("a", opts ++ [limit: 1])
    assert {:ok, text} = Goals.summary("a", opts ++ [bytes: 256])
    assert byte_size(text) <= 256
    assert String.valid?(text)
    assert text =~ "why:"
    assert text =~ "parent=-"
    assert text =~ "truncated"
    assert {:ok, text} = Goals.summary("a", opts ++ [limit: 1, bytes: 2000])
    assert text =~ "omitted 4"
    assert {:error, {:invalid_option, :limit}} = Goals.summary("a", opts ++ [limit: 0])
    assert {:error, {:invalid_option, :bytes}} = Goals.summary("a", opts ++ [bytes: 16_001])
  end

  test "corrupt or incompatible stores are reported and not overwritten", %{opts: opts} do
    assert {:ok, _} = Memory.put("a", "__goals_v1__", %{"version" => 99}, opts)
    assert {:error, :invalid_goal_store} = Goals.summary("a", opts)
    assert {:error, :invalid_goal_store} = Goals.create("a", goal("p"), opts)
    assert {:ok, %{"version" => 99}} = Memory.get("a", "__goals_v1__", opts)
  end
end

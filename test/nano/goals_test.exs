defmodule Nano.GoalsTest do
  # Not async: NANO_GOALS_DIR is process-wide, and the store is a named process.
  use ExUnit.Case, async: false

  alias Nano.Goals

  setup do
    dir = Path.join(System.tmp_dir!(), "nano-goals-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    old = System.get_env("NANO_GOALS_DIR")
    System.put_env("NANO_GOALS_DIR", dir)

    on_exit(fn ->
      if old, do: System.put_env("NANO_GOALS_DIR", old), else: System.delete_env("NANO_GOALS_DIR")
      File.rm_rf(dir)
    end)

    :ets.delete_all_objects(Nano.Goals.Store.table())
    %{agent: "t#{System.unique_integer([:positive])}"}
  end

  test "add creates an open goal with an id and event history", %{agent: agent} do
    {:ok, g} = Goals.add("do the thing", agent: agent, note: "because")
    assert g.status == :open
    assert g.agent == agent
    assert g.note == "because"
    assert is_binary(g.id)
    assert [%{event: "created"}] = Goals.history(g.id)
  end

  test "sub-goals form a tree", %{agent: agent} do
    {:ok, root} = Goals.add("root", agent: agent)
    {:ok, _child} = Goals.add("child", agent: agent, parent: root.id)
    tree = Goals.tree(agent: agent)
    assert tree =~ "root"
    # the child is indented
    assert tree =~ "  ☐"
  end

  test "status changes are recorded and reopenable", %{agent: agent} do
    {:ok, g} = Goals.add("x", agent: agent)
    {:ok, done} = Goals.done(g.id, "finished")
    assert done.status == :done
    assert done.note == "finished"
    {:ok, blocked} = Goals.block(g.id, "waiting")
    assert blocked.status == :blocked
    {:ok, reopened} = Goals.reopen(g.id)
    assert reopened.status == :open

    assert Goals.history(g.id) |> Enum.map(& &1.event) == [
             "created",
             "done",
             "blocked",
             "reopened"
           ]
  end

  test "progress keeps the status but adds to the history", %{agent: agent} do
    {:ok, g} = Goals.add("x", agent: agent)
    {:ok, updated} = Goals.progress(g.id, "halfway")
    assert updated.status == :open
    assert updated.note == "halfway"
    assert Goals.history(g.id) |> Enum.map(& &1.event) == ["created", "progress"]
  end

  test "open/1 lists only open goals for the agent", %{agent: agent} do
    {:ok, a} = Goals.add("a", agent: agent)
    {:ok, _b} = Goals.add("b", agent: agent)
    Goals.done(a.id)
    assert Enum.map(Goals.open(agent), & &1.text) == ["b"]
  end

  test "goals survive a reload from disk (a simulated restart)", %{agent: agent} do
    {:ok, g} = Goals.add("persist me", agent: agent)
    Goals.done(g.id, "done")
    :ets.delete_all_objects(Nano.Goals.Store.table())
    assert [%{text: "persist me", status: :done}] = Goals.list(agent: agent)
  end

  test "review prints a short block", %{agent: agent} do
    {:ok, _} = Goals.add("open one", agent: agent)
    review = Goals.review(agent)
    assert review =~ "1 open"
    assert review =~ "open one"
  end

  test "a goal by another agent is readable", %{agent: agent} do
    Goals.add("by someone", agent: "other-agent")
    assert Enum.any?(Goals.list(), &(&1.text == "by someone"))
    assert Enum.any?(Goals.list(agent: "other-agent"), &(&1.text == "by someone"))
  end

  test "unknown id returns {:error, :not_found}", %{agent: _} do
    assert {:error, :not_found} = Goals.done("nope")
  end
end

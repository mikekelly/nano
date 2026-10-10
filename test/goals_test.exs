defmodule GoalsTest do
  use ExUnit.Case, async: true

  setup do
    name = "goals-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    path = Path.join([Application.fetch_env!(:nano, :state_dir), "goals", name <> ".term"])
    on_exit(fn -> File.rm(path) end)
    {:ok, name: name, path: path}
  end

  test "hierarchy, mandatory why, statuses and cycle validation", %{name: n} do
    assert {:error, :why_required} = Goals.add(n, "root")
    assert {:ok, a} = Goals.add(n, "root", why: "purpose")
    assert {:ok, b} = Goals.add(n, "child", why: "step", parent: a.id)
    assert [%{id: id, children: [%{id: child}]}] = Goals.tree(n)
    assert {id, child} == {a.id, b.id}
    assert {:error, :cycle} = Goals.update(n, a.id, parent: b.id)
    assert {:error, :invalid_status} = Goals.update(n, a.id, status: :bogus)
    assert {:error, :parent_not_found} = Goals.update(n, b.id, parent: "absent")

    for status <- [:active, :blocked, :done, :cancelled, :pending] do
      assert {:ok, %{status: ^status}} = Goals.update(n, b.id, status: status)
    end
  end

  test "durable bob source and bounded review", %{name: n, path: p} do
    assert Goals.current(n) == nil
    assert {:ok, g} = Goals.add(n, "title", why: "purpose", next_step: "test")
    assert %{text: text, version: 1, written_at: at, threshold_tokens: 8000} = Goals.current(n)
    assert text =~ "test"
    assert {:ok, _, _} = DateTime.from_iso8601(at)
    assert File.exists?(p)
    assert String.length(Goals.review(n, max_chars: 10)) == 10
    assert {:ok, _} = Goals.configure(n, bobbing: false)
    assert Goals.current(n) == nil
    assert {:ok, _} = Goals.configure(n, bobbing: true, threshold_tokens: 12)
    assert %{version: 3, threshold_tokens: 12} = Goals.current(n)
    assert {:error, :invalid_configuration} = Goals.configure(n, threshold_tokens: 0)
    assert {:ok, _} = Goals.update(n, g.id, status: :done)
    assert Goals.current(n) == nil
    assert Goals.review(n) == "No open goals."
    assert [%{status: :done}] = Goals.tree(n)
  end

  test "concurrent mutations do not lose updates", %{name: n, path: p} do
    results =
      1..30
      |> Task.async_stream(fn i -> Goals.add(n, "goal #{i}", why: "concurrency") end,
        max_concurrency: 10
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert length(Goals.tree(n)) == 30
    assert %{version: 30} = Goals.current(n)
    assert Path.wildcard(p <> ".tmp-*") == []
    assert Goals.review(n, limit: 1) =~ "more goals omitted"
  end

  test "pid resolution, invalid paths and corrupt files", %{name: n, path: p} do
    :yes = Nano.Names.register_name({:agent, n}, self())
    assert {:ok, _} = Goals.add(self(), "pid", why: "stable")
    assert Goals.tree(self()) == Goals.tree(n)
    assert {:error, :invalid_agent} = Goals.add("../bad", "x", why: "y")
    File.write!(p, "corrupt")
    assert Goals.tree(n) == []
    assert Goals.current(n) == nil
    assert {:error, :corrupt_goals} = Goals.add(n, "x", why: "y")
    assert File.read!(p) == "corrupt"
  end

  test "does not touch agent saved state", %{name: n} do
    Nano.StateStore.put(n, %{name: n, sentinel: :unchanged})
    assert {:ok, _} = Goals.add(n, "x", why: "y")
    assert %{sentinel: :unchanged} = Nano.StateStore.get(n)
    on_exit(fn -> Nano.StateStore.delete(n) end)
  end
end

defmodule GoalsDashboardTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NanoWeb.Endpoint
  test "goal summary renders and refreshes without agent calls" do
    name = "goals-page-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    path = Path.join([Application.fetch_env!(:nano, :state_dir), "goals", name <> ".term"])
    on_exit(fn -> File.rm(path) end)

    assert {:ok, goal} =
             Goals.add(name, "Dashboard purpose",
               why: "Operators see intent",
               next_step: "Verify refresh"
             )

    assert {:ok, view, _} = live(build_conn(), "/agents/#{name}")
    assert has_element?(view, "#agent-goals", "Dashboard purpose")
    assert has_element?(view, "#agent-goals", "Operators see intent")
    assert {:ok, _} = Goals.update(name, goal.id, status: :done)
    send(view.pid, :refresh)
    assert render(view) =~ "No open goals."
  end
end

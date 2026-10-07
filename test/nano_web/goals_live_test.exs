defmodule NanoWeb.GoalsLiveTest do
  # The application setting is scoped to this test VM and restored; no live-node env edits.
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NanoWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "nova-goals-live-" <> Nano.DurableStore.id())
    old = Application.fetch_env(:nano, :library_root)
    Application.put_env(:nano, :library_root, root)
    name = "goals-" <> Nano.DurableStore.id()

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:nano, :library_root, value)
        :error -> Application.delete_env(:nano, :library_root)
      end

      File.rm_rf!(root)
      Nano.Ops.stop_agent(name)
    end)

    %{name: name, root: root, conn: build_conn()}
  end

  test "shows open goals and rationale, escapes content, refreshes status, survives stop", ctx do
    Nano.FakeOpenRouter.start()

    {:ok, pid} =
      Nano.Ops.start_agent(ctx.name, Nano.FakeOpenRouter.opts(Nano.FakeOpenRouter.model()))

    {:ok, goal} =
      Nano.Goals.add(ctx.name, "Verify <script>alert(1)</script>", why: "Evidence & safety")

    {:ok, child} =
      Nano.Goals.add(ctx.name, "Review sources", why: "Avoid stale facts", parent: goal["id"])

    {:ok, done} = Nano.Goals.add(ctx.name, "Already finished", why: "History")
    Nano.Goals.update(ctx.name, done["id"], status: :done)
    # Goals reads must not call the agent, even when suspended.
    :sys.suspend(pid)
    on_exit(fn -> if Process.alive?(pid), do: :sys.resume(pid) end)
    {:ok, view, html} = live(ctx.conn, "/agents/#{ctx.name}")
    assert has_element?(view, "#goals", "2 open")
    assert has_element?(view, "#goal-#{child["id"]}", "Step of #{goal["id"]}")
    assert html =~ "Evidence &amp; safety"
    refute has_element?(view, "#goals script")
    refute has_element?(view, "#goals", "Already finished")
    Nano.Goals.update(ctx.name, child["id"], status: :done)
    send(view.pid, :refresh)
    assert has_element?(view, "#goals", "1 open")
    refute has_element?(view, "#goal-#{child["id"]}")
    :sys.resume(pid)
    Nano.Ops.stop_agent(ctx.name)
    send(view.pid, :refresh)
    assert has_element?(view, "#goals", "Why: Evidence & safety")
  end

  test "empty, bounded and unreadable goal stores are visible", ctx do
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}")
    assert has_element?(view, "#goals", "No open goals recorded")
    for i <- 1..14, do: Nano.Goals.add(ctx.name, "Goal #{i}", why: "Useful")
    send(view.pid, :refresh)
    assert has_element?(view, "#goals", "14 open · 2 more not shown")

    assert length(
             view
             |> element("#goals")
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("li")
             |> LazyHTML.to_tree()
           ) == 12

    [path] = Path.wildcard(Path.join(ctx.root, "goals/*.json"))
    File.write!(path, "bad json")
    send(view.pid, :refresh)
    assert has_element?(view, "#goals .error", "Goals unavailable: :corrupt_store")
  end
end

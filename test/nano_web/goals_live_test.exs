defmodule NanoWeb.GoalsLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias NanoWeb.AgentLive

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "deneb-goalpanel-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, owner: "stopped-owner"}
  end

  defp socket(owner) do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, name: owner}}
  end

  defp snapshot(ctx) do
    AgentLive.refresh_goals(socket(ctx.owner), root: ctx.root).assigns.goals
  end

  defp panel(ctx), do: render_component(&AgentLive.goals_panel/1, result: snapshot(ctx))

  defp create(ctx, attrs) do
    {:ok, goal} =
      Goals.create(ctx.owner, Map.merge(%{title: "Task", why: "Keep context"}, attrs),
        root: ctx.root
      )

    goal
  end

  test "empty store is distinct from unavailable", ctx do
    html = panel(ctx)
    assert html =~ "No open goals."
    assert html =~ "0 open"
    refute html =~ "Goals unavailable"
  end

  test "rationale, status and parent identifiers survive closed parents and escape markup", ctx do
    parent = create(ctx, %{id: "parent-goal", status: :done})

    create(ctx, %{
      id: "child-goal",
      title: "<script>title</script>",
      why: "<b>uncertain evidence</b>",
      parent_id: parent["id"],
      status: :blocked
    })

    create(ctx, %{id: "working", status: :in_progress})
    create(ctx, %{id: "cancelled-goal", status: :cancelled})
    html = panel(ctx)
    assert html =~ "blocked"
    assert html =~ "in_progress"
    assert html =~ "child-goal"
    assert html =~ "parent-goal"
    assert html =~ "none (root)"
    assert html =~ "Why"
    assert html =~ "&lt;b&gt;uncertain evidence&lt;/b&gt;"
    assert html =~ "&lt;script&gt;title&lt;/script&gt;"
    refute html =~ "<script>"
    refute html =~ "cancelled-goal"
    assert html =~ "2 open"
  end

  test "refresh reads new disk snapshots and caps the panel at twenty goals", ctx do
    for i <- 1..23, do: create(ctx, %{id: "goal-#{i}"})
    sock = AgentLive.refresh_goals(socket(ctx.owner), root: ctx.root)
    assert {:ok, %{total: 23, omitted: 3, goals: goals}} = sock.assigns.goals
    assert length(goals) == 20
    html = render_component(&AgentLive.goals_panel/1, result: sock.assigns.goals)
    assert html =~ "23 open"
    assert html =~ "showing 20"
    assert html =~ "3 omitted"
    assert html =~ "Panel truncated"
    {:ok, _} = Goals.update(ctx.owner, hd(goals)["id"], %{status: :done}, root: ctx.root)
    sock = AgentLive.refresh_goals(sock, root: ctx.root)
    assert {:ok, %{total: 22, omitted: 2}} = sock.assigns.goals
  end

  test "corrupt goals and unreadable memory render unavailable instead of empty", ctx do
    {:ok, _} = Memory.put(ctx.owner, "__goals_v1__", %{"bad" => "tree"}, root: ctx.root)
    assert panel(ctx) =~ "Goals unavailable"
    refute panel(ctx) =~ "No open goals."

    path =
      Path.join(
        ctx.root,
        Base.encode16(:crypto.hash(:sha256, ctx.owner), case: :lower) <> ".json"
      )

    File.write!(path, "{invalid json")
    assert panel(ctx) =~ "Goals unavailable"
    File.rm!(path)
    File.mkdir!(path)
    assert panel(ctx) =~ "Goals unavailable"
  end

  test "full stopped-owner page keeps the panel outside the running-agent controls", ctx do
    create(ctx, %{title: "Durable stopped task", why: "Resume later"})

    html =
      render_component(&AgentLive.render/1,
        name: ctx.owner,
        agent: nil,
        id: nil,
        unread: 0,
        notice: nil,
        goals: snapshot(ctx),
        view: "reading",
        streams: %{entries: []}
      )

    assert html =~ "No agent named"
    assert html =~ ~s(id="open-goals")
    assert html =~ "Durable stopped task"
    assert html =~ "Resume later"
  end
end

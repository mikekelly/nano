defmodule Seedling.GoalsTest do
  use ExUnit.Case, async: true
  alias Seedling.{Goals, DurableStore}

  setup do
    root =
      Path.join(System.tmp_dir!(), "atlas-goals-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [root: root], agent: "alice"}
  end

  defp create(ctx, title, extra \\ []) do
    {:ok, goal} =
      Goals.create(ctx.agent, [title: title, why: "Useful because " <> title] ++ extra, ctx.opts)

    goal
  end

  test "durable nested goals preserve why, status, stable IDs and ownership", ctx do
    parent = create(ctx, "Ship")
    step = create(ctx, "Test", parent_id: parent["id"])
    assert {:ok, ^parent} = Goals.get("alice", parent["id"], ctx.opts)
    assert {:ok, []} = Goals.list("bob", ctx.opts)
    assert {:ok, [%{"children" => [%{"id" => id}]}]} = Goals.tree("alice", ctx.opts)
    assert id == step["id"]
    assert {:ok, _} = Goals.focus("alice", parent["id"], ctx.opts)
    assert {:ok, source} = Goals.bobbing_source("alice", ctx.opts)
    assert source.text =~ "Why: Useful because Ship"
    assert source.text =~ "Next step: Test"
    # A disk reload, independent of the cached entry or owning agent process.
    assert {:ok, [^parent, ^step]} = Goals.list("alice", ctx.opts ++ [refresh: true])
    {:ok, path} = DurableStore.path("goals", "alice", ctx.opts)
    assert Jason.decode!(File.read!(path))["current"] == parent["id"]
  end

  test "completion is explicit, descendants survive and focus clears", ctx do
    parent = create(ctx, "Root")
    child = create(ctx, "Child", parent_id: parent["id"])

    assert {:error, :unfinished_children} =
             Goals.set_status("alice", parent["id"], :done, ctx.opts)

    assert {:ok, _} = Goals.focus("alice", child["id"], ctx.opts)
    assert {:ok, done} = Goals.set_status("alice", child["id"], :done, ctx.opts)
    assert done["why"] == child["why"]
    assert {:ok, _} = Goals.set_status("alice", parent["id"], :done, ctx.opts)
    assert {:ok, %{open: 0, total: 2, current_id: nil}} = Goals.review("alice", ctx.opts)
    assert {:ok, nil} = Goals.bobbing_source("alice", ctx.opts)
    assert {:error, :goal_closed} = Goals.focus("alice", child["id"], ctx.opts)
    assert {:error, :parent_closed} = Goals.set_status("alice", child["id"], :open, ctx.opts)

    assert {:error, :parent_closed} =
             Goals.create(
               "alice",
               [title: "Another", why: "Reason", parent_id: parent["id"]],
               ctx.opts
             )

    assert {:ok, _} = Goals.set_status("alice", parent["id"], :active, ctx.opts)
    assert {:ok, _} = Goals.set_status("alice", child["id"], :blocked, ctx.opts)
  end

  test "reparent rejects cycles and missing parents; delete is a subtree", ctx do
    root = create(ctx, "Root")
    child = create(ctx, "Child", parent_id: root["id"])
    grandchild = create(ctx, "Grandchild", parent_id: child["id"])
    create(ctx, "Other")

    assert {:error, :cycle} =
             Goals.update("alice", root["id"], [parent_id: grandchild["id"]], ctx.opts)

    assert {:error, :cycle} = Goals.update("alice", root["id"], [parent_id: root["id"]], ctx.opts)

    assert {:error, :parent_not_found} =
             Goals.update("alice", root["id"], [parent_id: "missing"], ctx.opts)

    assert {:error, :not_found} = Goals.update("alice", "missing", [why: "No"], ctx.opts)
    assert {:ok, _} = Goals.focus("alice", grandchild["id"], ctx.opts)
    assert {:ok, 3} = Goals.delete("alice", root["id"], ctx.opts)
    assert {:ok, [%{"title" => "Other"}]} = Goals.list("alice", ctx.opts)
    assert {:ok, %{current_id: nil}} = Goals.dashboard("alice", ctx.opts)
  end

  test "bounded cheap review includes focused goal and honest cuts", ctx do
    for n <- 1..7, do: create(ctx, "Goal #{n}")
    {:ok, goals} = Goals.list("alice", ctx.opts)
    last = List.last(goals)
    Goals.focus("alice", last["id"], ctx.opts)
    assert {:ok, review} = Goals.review("alice", ctx.opts ++ [limit: 1, max_chars: 180])
    assert review.text =~ "Goal 7"
    assert review.text =~ "[review limited]"
    assert review.truncated
    assert review.open == 7
    assert String.length(review.text) <= 180

    assert {:ok, %{truncated: false}} =
             Goals.review("alice", ctx.opts ++ [limit: 50, max_chars: 4_000])
  end

  test "invalid attributes fail without changing persisted tree", ctx do
    assert {:error, :invalid_why} = Goals.create("alice", [title: "Missing why"], ctx.opts)

    assert {:error, :invalid_title} =
             Goals.create("alice", [title: String.duplicate("x", 241), why: "Reason"], ctx.opts)

    assert {:error, :invalid_status} =
             Goals.create("alice", [title: "x", why: "y", status: :imaginary], ctx.opts)

    assert {:error, :invalid_attributes} =
             Goals.create("alice", [title: "x", why: "y", id: "override"], ctx.opts)

    assert {:error, :invalid_name} = Goals.list(nil, ctx.opts)
    assert {:ok, []} = Goals.list("alice", ctx.opts)
  end

  test "mutations are serialized without lost concurrent additions", ctx do
    tasks = for n <- 1..20, do: Task.async(fn -> create(ctx, "Concurrent #{n}") end)
    Enum.each(tasks, &Task.await/1)
    assert {:ok, goals} = Goals.list("alice", ctx.opts)
    assert length(goals) == 20
    assert length(Enum.uniq_by(goals, & &1["id"])) == 20
  end

  test "corrupt files are reported rather than overwritten", ctx do
    {:ok, path} = DurableStore.path("goals", "alice", ctx.opts)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "bad json")
    assert {:error, :invalid_json} = Goals.list("alice", ctx.opts)
    assert {:error, :invalid_json} = Goals.create("alice", [title: "x", why: "y"], ctx.opts)
    assert File.read!(path) == "bad json"

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "revision" => 0,
        "goals" => [%{"id" => "bad"}],
        "current" => nil
      })
    )

    assert {:error, :invalid_goal_document} = Goals.list("alice", ctx.opts ++ [refresh: true])
  end

  test "dashboard asynchronously warms disk and does not wait for owning agent", ctx do
    assert :loading = Goals.dashboard("cold", ctx.opts)
    assert {:ok, []} = Goals.list("cold", ctx.opts)
    assert {:ok, %{open: 0}} = Goals.dashboard("cold", ctx.opts)
    goal = create(ctx, "Visible")
    assert {:ok, %{goals: [^goal]}} = Goals.dashboard("alice", ctx.opts)
  end

  test "large tree reviews and dashboard stay bounded and the goal limit is enforced", ctx do
    now = DateTime.to_iso8601(DateTime.utc_now())

    goals =
      for n <- 1..1_000 do
        %{
          "id" => to_string(n),
          "title" => "Goal #{n}",
          "why" => "Reason",
          "status" => "open",
          "parent_id" => if(n == 1, do: nil, else: to_string(n - 1)),
          "created_at" => now,
          "updated_at" => now
        }
      end

    {:ok, path} = DurableStore.path("goals", "alice", ctx.opts)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{"version" => 1, "revision" => 0, "current" => nil, "goals" => goals})
    )

    assert {:ok, %{open: 1_000, truncated: true, text: text}} = Goals.review("alice", ctx.opts)
    assert String.length(text) <= 1_000
    assert {:ok, %{goals: selected, truncated: true}} = Goals.dashboard("alice", ctx.opts)
    assert length(selected) == 50

    assert {:error, :goal_limit} =
             Goals.create("alice", [title: "Overflow", why: "No room"], ctx.opts)

    # A corrupt cycle must be rejected, never followed recursively forever.
    goals = List.update_at(goals, 0, &Map.put(&1, "parent_id", "1000"))

    File.write!(
      path,
      Jason.encode!(%{"version" => 1, "revision" => 0, "current" => nil, "goals" => goals})
    )

    assert {:error, :invalid_goal_document} = Goals.list("alice", ctx.opts ++ [refresh: true])
  end

  test "name cannot escape storage root",
       ctx do
    assert {:ok, _} = Goals.create("../../escape", [title: "Safe", why: "Hashed path"], ctx.opts)
    {:ok, path} = DurableStore.path("goals", "../../escape", ctx.opts)
    assert String.starts_with?(path, Path.expand(ctx.opts[:root]) <> "/goals/")
    refute path =~ ".."
  end
end

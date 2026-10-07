defmodule Seedling.GoalsTest do
  use ExUnit.Case, async: false
  alias Seedling.Goals
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NanoWeb.Endpoint

  setup do
    old = Application.get_env(:nano, :goals_dir)
    dir = Path.join(System.tmp_dir!(), "goals-#{System.unique_integer([:positive])}")
    Application.put_env(:nano, :goals_dir, dir)

    on_exit(fn ->
      if old,
        do: Application.put_env(:nano, :goals_dir, old),
        else: Application.delete_env(:nano, :goals_dir)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "vague brief, decomposition, progress, fresh process review, completion" do
    assert {:ok, []} = Goals.list("parent")
    assert {:ok, root} = Goals.add("parent", "Make onboarding easier", why: "Reduce setup time")
    assert {:ok, child} = Goals.add("parent", "Measure current setup", parent: root["id"])
    assert {:ok, _} = Goals.update("parent", child["id"], status: :active)
    assert {:ok, review} = Task.async(fn -> Goals.review("parent") end) |> Task.await()
    assert review.text =~ "Reduce setup time"
    assert review.text =~ root["id"]
    assert {:ok, _} = Goals.complete("parent", child["id"], "Measured 12 minutes")
    assert {:ok, [open]} = Goals.list("parent", open: true)
    assert open["id"] == root["id"]
    assert {:ok, _} = Goals.complete("parent", root["id"])
    assert {:ok, %{open: 0, total: 2}} = Goals.review("parent")
    assert {:ok, saved} = Goals.get("parent", child["id"])
    assert saved["note"] == "Measured 12 minutes"
  end

  test "dashboard reads durable goals even for an offline agent" do
    {:ok, goal} =
      Goals.add("offline-goal-owner", "Visible durable goal", why: "Fresh agents need context")

    {:ok, view, html} = live(build_conn(), "/agents/offline-goal-owner")
    assert html =~ "Visible durable goal"
    assert html =~ "Fresh agents need context"
    Goals.complete("offline-goal-owner", goal["id"])
    send(view.pid, :refresh)
    assert render(view) =~ "0 open / 1 total"
    refute render(view) =~ "Visible durable goal"
  end

  test "parallel updates
 do not lose goals" do
    results =
      1..20
      |> Task.async_stream(fn n -> Goals.add("agent", "Task #{n}") end, max_concurrency: 20)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert {:ok, goals} = Goals.list("agent")
    assert length(goals) == 20
    assert length(Enum.uniq_by(goals, & &1["id"])) == 20
  end

  test "limits, validation and isolation" do
    assert {:error, :invalid_agent} = Goals.list(123)
    assert {:ok, _} = Goals.add(String.duplicate("x", 200), "Long agent name")
    assert {:error, :invalid_title} = Goals.add("a", " ")
    assert {:error, :invalid_status} = Goals.add("a", "Title", status: :imaginary)
    assert {:error, :parent_not_found} = Goals.add("a", "Title", parent: "missing")
    assert {:ok, g} = Goals.add("a", "Title", why: String.duplicate("x", 100))
    assert {:error, :invalid_fields} = Goals.update("a", g["id"], parent: g["id"])
    assert {:error, :not_found} = Goals.complete("a", "missing")
    assert {:ok, []} = Goals.list("b")
    assert {:ok, r} = Goals.review("a", chars: 30)
    assert String.length(r.text) == 30
    assert r.truncated
    assert {:error, :invalid_limits} = Goals.review("a", limit: -1)
  end

  test "corrupt storage is not silently overwritten and names cannot escape directory", %{
    dir: dir
  } do
    assert {:ok, _} = Goals.add("../../odd", "Safe name")
    assert [file] = File.ls!(dir)
    path = Path.join(dir, file)
    File.write!(path, "invalid")
    assert {:error, :corrupt_storage} = Goals.list("../../odd")
    assert {:error, :corrupt_storage} = Goals.add("../../odd", "Do not overwrite")
    assert File.read!(path) == "invalid"
  end

  test "storage failures are returned", %{dir: dir} do
    File.write!(dir, "not a directory")
    assert {:error, {:storage, _}} = Goals.add("a", "Title")
  end
end

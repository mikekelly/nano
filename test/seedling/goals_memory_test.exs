defmodule Seedling.GoalsMemoryTest do
  use ExUnit.Case, async: true
  alias Seedling.{Goals, Memory, CapabilityStore}

  setup do
    root = Path.join(System.tmp_dir!(), "orion-goals-" <> CapabilityStore.id())
    on_exit(fn -> File.rm_rf(root) end)
    %{opts: [root: root]}
  end

  test "durable tree with why, bounded review, statuses and child completion", %{opts: opts} do
    assert {:ok, parent} = Goals.create("agent", "Ship", "People need this", opts)

    assert {:ok, child} =
             Goals.create("agent", "Test", "Evidence", opts ++ [parent: parent["id"]])

    assert {:error, :unfinished_children} =
             Goals.update("agent", parent["id"], [status: "done"], opts)

    assert {:ok, _} = Goals.update("agent", child["id"], [status: "done"], opts)
    assert {:ok, text} = Goals.review("agent", opts)
    assert text =~ "People need this"
    refute text =~ "Evidence"
    assert {:ok, _} = Goals.update("agent", parent["id"], [status: "done"], opts)
    assert {:ok, "0 open goals\n"} = Goals.review("agent", opts)
    assert {:ok, [_, _]} = Goals.list("agent", opts)

    assert {:error, :invalid_parent} =
             Goals.create("agent", "Bad", "Why", opts ++ [parent: "missing"])

    assert {:error, :invalid_status} =
             Goals.update("agent", parent["id"], [status: "almost"], opts)
  end

  test "serialized concurrent updates and corrupt documents never get erased", %{opts: opts} do
    tasks =
      for i <- 1..20, do: Task.async(fn -> Goals.create("agent", "Step #{i}", "Why", opts) end)

    assert Enum.all?(Task.await_many(tasks), &match?({:ok, _}, &1))
    assert {:ok, goals} = Goals.list("agent", opts)
    assert length(goals) == 20
    [file] = Path.wildcard(Path.join(opts[:root], "*.json"))
    File.write!(file, "invalid JSON")
    assert {:error, _} = Goals.create("agent", "More", "Why", opts)
    assert File.read!(file) == "invalid JSON"
  end

  test "per bot graph links and bounded lexical fallback without pretending Jev ran", %{
    opts: opts
  } do
    assert {:ok, node} =
             Memory.remember(
               "bot",
               "preference",
               "Quiet hotels near trains",
               opts ++ [session: "a"]
             )

    assert {:ok, _} = Memory.remember("bot", "person", "Ada", opts ++ [links: [node["id"]]])

    assert {:error, :invalid_link} =
             Memory.remember("bot", "fact", "Bad", opts ++ [links: ["missing"]])

    assert {:ok, r} =
             Memory.recall("bot", "quiet hotel trains", opts ++ [decision_opts: [key: nil]])

    assert r.method == :lexical_fallback
    assert r.blocked_reason == :missing_typesafe_api_key
    assert r.text =~ "Quiet hotels"
    assert String.length(r.text) <= 1600
    assert {:ok, %{nodes: []}} = Memory.recall("another-bot", "quiet hotel", opts)
    assert {:ok, :ok} = Memory.forget("bot", node["id"], opts)
    assert {:ok, %{"nodes" => [%{"links" => []}]}} = Memory.all("bot", opts)
  end
end

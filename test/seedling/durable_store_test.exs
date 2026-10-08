defmodule Seedling.DurableStoreTest do
  use ExUnit.Case, async: false
  alias Seedling.{DurableStore, Goals, FrontOfMind}

  setup do
    root =
      Path.join(System.tmp_dir!(), "atlas-store-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [root: root]}
  end

  test "server restart loses cache, not durable goals or notes", ctx do
    {:ok, goal} = Goals.create("alice", [title: "Keep going", why: "Durable"], ctx.opts)
    {:ok, note} = FrontOfMind.set("alice", "Do not forget", ctx.opts)
    FrontOfMind.before_call("alice", 1_000, ctx.opts)
    GenServer.stop(DurableStore)
    assert {:ok, ^goal} = Goals.get("alice", goal["id"], ctx.opts)
    assert {:ok, ^note} = FrontOfMind.get("alice", ctx.opts)
    assert {:ok, %{messages: []}} = FrontOfMind.before_call("alice", 1_001, ctx.opts)

    assert {:ok, %{messages: [_]}} =
             FrontOfMind.before_call("alice", 1, ctx.opts ++ [compacted: true])
  end

  test "dashboard returns from cache even while the disk worker is suspended", ctx do
    {:ok, goal} = Goals.create("alice", [title: "Visible", why: "Cheap"], ctx.opts)
    :sys.suspend(DurableStore)

    try do
      task = Task.async(fn -> Goals.dashboard("alice", ctx.opts) end)
      assert {:ok, %{goals: [^goal]}} = Task.await(task, 200)
      cold = Task.async(fn -> Goals.dashboard("cold", ctx.opts) end)
      assert :loading = Task.await(cold, 200)
    after
      :sys.resume(DurableStore)
    end
  end

  test "failed writes do not publish success or change cache", ctx do
    root = ctx.opts[:root]
    assert {:ok, %{}} = DurableStore.read("testing", "alice", %{}, ctx.opts)
    File.write!(root, "not a directory")

    assert {:error, {:write_failed, :enotdir}} =
             DurableStore.update(
               "testing",
               "alice",
               %{},
               fn _ -> {:ok, %{"x" => 1}, :saved} end,
               ctx.opts
             )

    # File.stat below the root fails too, honestly reported.
    assert {:error, {:read_failed, :enotdir}} =
             DurableStore.read("testing", "alice", %{}, ctx.opts ++ [refresh: true])
  end

  test "bad callback cannot kill the shared store", ctx do
    assert {:error, :mutation_failed} =
             DurableStore.update(
               "testing",
               "alice",
               %{},
               fn _ -> raise "bad callback" end,
               ctx.opts
             )

    assert Process.alive?(Process.whereis(DurableStore))
    assert {:ok, %{}} = DurableStore.read("testing", "alice", %{}, ctx.opts)
  end
end

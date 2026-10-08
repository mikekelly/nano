defmodule DelegationTest do
  use ExUnit.Case, async: false

  test "validate before checkout rejects paths and incomplete budgets" do
    opts = [
      revision: "HEAD",
      task: "inspect",
      model: "test",
      reasoning: "low",
      max_turns: 10,
      max_tokens: 0,
      max_context: 100_000
    ]

    assert :ok = Delegation.validate("safe-name", opts, "parent")
    assert {:error, _} = Delegation.validate("../unsafe", opts, "parent")
    assert {:error, _} = Delegation.validate("safe", Keyword.delete(opts, :revision), "parent")

    assert {:error, _} =
             Delegation.validate("safe", Keyword.put(opts, :max_context, 1000), "parent")

    assert {:error, _} = Delegation.validate("safe", opts, nil)
  end

  test "preread has per-file and aggregate bounds without echoing oversized contents" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "delegation-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "file")
    File.write!(path, "hello")
    assert {:ok, text} = Delegation.preread([path])
    assert text =~ "sha256="
    assert text =~ "hello"
    File.write!(path, String.duplicate("a", 24000))
    assert {:error, _} = Delegation.preread(List.duplicate(path, 4))
    File.write!(path, String.duplicate("a", 24001))
    assert {:error, message} = Delegation.preread([path])
    assert byte_size(message) < 1000
    assert {:error, _} = Delegation.preread(List.duplicate(path, 17))
  end

  test "durable monitoring reports deaths and follows a restarted child by name" do
    suffix = System.unique_integer([:positive, :monotonic])
    name = "monitor-child-#{suffix}"
    parent = "monitor-parent-#{suffix}"
    assert :yes = Nano.Names.register_name({:agent, parent}, self())
    child = spawn(fn -> Process.sleep(:infinity) end)
    assert :yes = Nano.Names.register_name({:agent, name}, child)

    on_exit(fn ->
      if pid = :global.whereis_name({Delegation, name}) do
        if is_pid(pid), do: Process.exit(pid, :kill)
      end

      if pid = NanoAgent.whereis(name), do: Process.exit(pid, :kill)
      Nano.Names.unregister_name({:agent, parent})
    end)

    assert :ok = Delegation.monitor(name, parent)
    # Give the watcher time to monitor; restore is idempotent.
    Process.sleep(100)
    assert :ok in Delegation.restore()
    Process.exit(child, :kill)
    assert_receive {:delegation, ^name, :down, :killed}, 2000
    replacement = spawn(fn -> Process.sleep(:infinity) end)
    assert :yes = Nano.Names.register_name({:agent, name}, replacement)
    assert_receive {:delegation, ^name, :restarted, ^replacement}, 2500
    Process.exit(replacement, :kill)
    assert_receive {:delegation, ^name, :down, :killed}, 2000
  end
end

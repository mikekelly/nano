defmodule Nano.StateStoreTest do
  use ExUnit.Case, async: true

  alias Nano.StateStore

  setup do
    name = "store-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> StateStore.delete(name) end)
    %{name: name}
  end

  test "get/put/delete/all, and delete drops the log sequence", %{name: name} do
    assert StateStore.get(name) == nil
    :ok = StateStore.put(name, %{id: name <> "-id", name: name})
    assert StateStore.get(name) == %{id: name <> "-id", name: name}
    assert %{name: name, id: name <> "-id"} in StateStore.all()
    assert {StateStore.next_seq(name <> "-id"), StateStore.next_seq(name <> "-id")} == {1, 2}
    :ok = StateStore.delete(name)
    assert StateStore.get(name) == nil
    assert StateStore.next_seq(name <> "-id") == 1
  end

  test "watch records a watched pid's exit reason for the next init", %{name: name} do
    pid = spawn(fn -> receive do: (:stop -> exit(:boom)) end)
    :ok = StateStore.watch(name, pid)
    send(pid, :stop)

    # The next watch for the same name waits for the earlier :DOWN, so the reason is there.
    :ok = StateStore.watch(name, self())
    assert StateStore.exit_reason(name, pid) == :boom
    assert StateStore.exit_reason(name, self()) == nil
    :ok = StateStore.delete(name)
    assert StateStore.exit_reason(name, pid) == nil
  end

  test "node tokens are summed over the last hour" do
    before = StateStore.node_tokens_last_hour()
    StateStore.add_node_tokens(123)
    assert StateStore.node_tokens_last_hour() >= before + 123
  end
end

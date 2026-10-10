defmodule Nano.StateStoreTest do
  # Not async: its entries are partial, and the dashboard and API, rendered by async tests,
  # read every entry in the node-wide store as an agent's.
  use ExUnit.Case, async: false

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
    StateStore.put(name, %{name: name, pid: pid})
    :ok = StateStore.watch(name, pid)
    await_monitor_attachment(pid)
    send(pid, :stop)

    # The next watch for the same name waits for the earlier :DOWN, so the reason is there.
    :ok = StateStore.watch(name, self())
    assert StateStore.exit_reason(name, pid) == :boom
    assert StateStore.exit_reason(name, self()) == nil
    :ok = StateStore.delete(name)
    assert StateStore.exit_reason(name, pid) == nil
  end

  test "an exit is recorded only for the pid the entry belongs to", %{name: name} do
    owner = spawn(fn -> receive do: (:stop -> exit(:first)) end)
    stand_in = spawn(fn -> receive do: (:stop -> exit(:second)) end)
    StateStore.put(name, %{name: name, pid: owner})
    :ok = StateStore.watch(name, owner)
    await_monitor_attachment(owner)
    send(owner, :stop)
    :ok = StateStore.watch(name, stand_in)
    await_monitor_attachment(stand_in)
    send(stand_in, :stop)
    :ok = StateStore.watch(name, self())
    assert StateStore.exit_reason(name, owner) == :first
    assert StateStore.exit_reason(name, stand_in) == nil
  end

  test "node tokens are summed over the last hour" do
    before = StateStore.node_tokens_last_hour()
    StateStore.add_node_tokens(123)
    assert StateStore.node_tokens_last_hour() >= before + 123
  end

  test "stray messages, casts and calls are ignored, not fatal", %{name: name} do
    store = Process.whereis(StateStore)
    StateStore.put(name, %{name: name})

    ExUnit.CaptureLog.capture_log(fn ->
      send(store, :stray)
      GenServer.cast(store, :stray)
      assert GenServer.call(store, :stray) == {:error, :unknown_call}
    end)

    assert Process.whereis(StateStore) == store
    assert StateStore.get(name) == %{name: name}
  end

  # These tests require the exact named exit, not just a death observation.
  # Establish observable attachment before allowing exit from another sender,
  # instead of depending on registration and cross-sender signal timing.
  defp await_monitor_attachment(pid) do
    store = Process.whereis(StateStore)
    await_monitor_attachment(pid, store, System.monotonic_time(:millisecond) + 10_000)
  end

  defp await_monitor_attachment(pid, store, deadline) do
    case Process.info(pid, :monitored_by) do
      {:monitored_by, monitors} ->
        unless store in monitors do
          if System.monotonic_time(:millisecond) >= deadline,
            do: flunk("StateStore monitor did not attach to #{inspect(pid)} within 10 seconds")

          Process.sleep(10)
          await_monitor_attachment(pid, store, deadline)
        end

      nil ->
        flunk("watched process #{inspect(pid)} exited before stop was sent")
    end
  end
end

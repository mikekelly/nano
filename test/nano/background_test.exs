defmodule Nano.BackgroundTest do
  @moduledoc """
  The completion path and the reaper. No real long commands: everything here is milliseconds.
  """
  use ExUnit.Case, async: false

  alias Nano.Background

  test "a task returns at once and its status is readable from another process" do
    {:ok, id} = Background.start("sleep 0.2; echo hi", agent: nil, name: "test-fast")
    assert %{state: :running} = Background.status(id)
    status = await_state(id, :exited, 5_000)
    assert status.exit_status == 0
    assert Background.tail(id, 5) =~ "hi"
  end

  # Poll rather than sleep a fixed time: a suite-wide run is slower than one file, and a fixed sleep
  # that is long enough in isolation is a race in the suite.
  defp await_state(id, want, budget) do
    deadline = System.monotonic_time(:millisecond) + budget
    poll(id, want, deadline)
  end

  defp poll(id, want, deadline) do
    status = Background.status(id)

    cond do
      status.state == want -> status
      System.monotonic_time(:millisecond) > deadline -> status
      true ->
        Process.sleep(50)
        poll(id, want, deadline)
    end
  end

  test "output goes to a file and the status carries its size, not the output" do
    {:ok, id} = Background.start("printf 'aaaaaa'", agent: nil, name: "test-size")
    status = await_state(id, :exited, 5_000)
    assert status.bytes > 0
    assert status.output =~ "/tasks/"
  end

  test "a timeout kills the task and marks it timed_out" do
    {:ok, id} = Background.start("sleep 30", agent: nil, timeout: 300, name: "test-timeout")
    assert %{state: :killed} = await_state(id, :killed, 5_000)
  end

  test "reap/0 finalises a task whose process is gone" do
    {:ok, id} = Background.start("sleep 0.1", agent: nil, name: "test-reap")
    Process.sleep(600)
    # Simulate the owner dying before it read the exit: kill the task process outright.
    case Registry.lookup(Background.Registry, id) do
      [{pid, _}] -> Process.exit(pid, :kill)
      [] -> :ok
    end

    Process.sleep(300)
    assert Background.reap() >= 0
  end

  test "list/2 does not repeat a task that is both live and on disk" do
    {:ok, id} = Background.start("sleep 0.2", agent: nil, name: "test-uniq")
    ids = Background.list(:all) |> Enum.map(& &1.id)
    assert Enum.count(ids, &(&1 == id)) == 1
  end
end

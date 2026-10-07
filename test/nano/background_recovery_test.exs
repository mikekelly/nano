defmodule Nano.BackgroundRecoveryTest do
  use ExUnit.Case, async: false

  test "manager death re-adopts live workers and completed metadata" do
    {:ok, job} = Nano.Background.start("sleep 0.3; printf recovered", notify: self())
    manager = Process.whereis(Nano.Background)
    ref = Process.monitor(manager)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^ref, :process, ^manager, :killed}
    # Calling status lazily replaces the manager when not supervised.
    assert {:ok, %{pid: worker}} = Nano.Background.status(job.id)
    assert worker == job.pid
    assert Process.whereis(Nano.Background) != manager
    assert_receive {:nano_background, id, %{exit_status: 0, bytes: 9}}, 3000
    assert id == job.id
    assert {:ok, %{state: :finished}} = Nano.Background.status(id)
    next = Process.whereis(Nano.Background)
    ref = Process.monitor(next)
    Process.exit(next, :kill)
    assert_receive {:DOWN, ^ref, :process, ^next, :killed}
    assert {:ok, %{state: :finished, bytes: 9}} = Nano.Background.status(id)
    assert :ok = Nano.Background.prune(id)
  end
end

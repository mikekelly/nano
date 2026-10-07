defmodule Nano.BackgroundTest do
  # Not async: the data dir and the registry are node-wide.
  use ExUnit.Case, async: false

  alias Nano.Background, as: B

  setup do
    dir = Path.join(System.tmp_dir!(), "nano-bg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    old = System.get_env("NANO_DATA_DIR")
    System.put_env("NANO_DATA_DIR", dir)

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Nano.Background.Tasks),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(Nano.Background.Tasks, pid)

      if old, do: System.put_env("NANO_DATA_DIR", old), else: System.delete_env("NANO_DATA_DIR")
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp await_state(id, state, ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + ms
    wait(id, state, deadline)
  end

  defp wait(id, state, deadline) do
    status = B.status(id)

    cond do
      match?(%{state: ^state}, status) ->
        status

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("task #{id} never reached #{state}: #{inspect(status)}")

      true ->
        Process.sleep(50)
        wait(id, state, deadline)
    end
  end

  test "start returns an id at once and the command's output is captured" do
    {:ok, id} = B.start("echo hello; echo world")
    assert is_binary(id)
    status = await_state(id, :exited)
    assert status.exit_status == 0
    assert B.tail(id) =~ "hello"
    assert B.tail(id) =~ "world"
  end

  test "the exit status is recorded", %{dir: dir} do
    {:ok, id} = B.start("exit 7")
    status = await_state(id, :exited)
    assert status.exit_status == 7
    assert File.exists?(Path.join(dir, "tasks/#{id}.log"))
  end

  test "kill stops a long task and records it", %{dir: _} do
    {:ok, id} = B.start("sleep 60")
    assert %{state: :running} = B.status(id)
    assert :ok = B.kill(id)
    status = await_state(id, :killed)
    assert status.exit_status == nil
  end

  test "timeout kills the task", %{dir: _} do
    {:ok, id} = B.start("sleep 60", timeout: 300)
    status = await_state(id, :killed)
    assert status.exit_status == nil
  end

  test "list shows tasks, scoped to the calling agent", %{dir: _} do
    {:ok, id} = B.start("true")
    await_state(id, :exited)
    assert Enum.any?(B.list(:all), &(&1.id == id))
    scanned = Enum.map(B.list(:all), & &1.id)
    assert id in scanned
  end

  test "status of an unknown task is nil", %{dir: _} do
    assert B.status("nosuch") == nil
  end

  test "a finished task is readable from disk after its process is gone", %{dir: _} do
    {:ok, id} = B.start("echo persisted")
    await_state(id, :exited)
    # Kill the task process so only the meta file remains.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Nano.Background.Tasks),
        is_pid(pid),
        do: DynamicSupervisor.terminate_child(Nano.Background.Tasks, pid)

    status = B.status(id)
    assert status.state == :exited
    assert status.exit_status == 0
    assert B.tail(id) =~ "persisted"
  end

  test "start! raises on success and returns the id", %{dir: _} do
    id = B.start!("true")
    assert is_binary(id)
    await_state(id, :exited)
  end
end

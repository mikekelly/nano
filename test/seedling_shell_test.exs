defmodule Seedling.ShellTest do
  use ExUnit.Case, async: true
  alias Seedling.{Shell, Background}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "lyra-shell-" <> Base.url_encode64(:crypto.strong_rand_bytes(12))
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "actual shell merges streams, sets env/cwd, preserves nonzero status", %{dir: dir} do
    assert {:ok, r} =
             Shell.sh("printf '%s:%s' \"$PWD\" \"$SEED_TEST\"; printf err >&2; exit 7",
               cwd: dir,
               dir: dir,
               env: [{"SEED_TEST", "value"}]
             )

    assert r.output == dir <> ":valueerr"
    assert r.exit_code == 7
    assert r.status == :completed
    assert {:ok, saved} = Background.receipt(r.receipt_path)
    assert saved.id == r.id
  end

  test "instant commands remain safe under concurrent port exit", %{dir: dir} do
    results =
      1..100
      |> Task.async_stream(
        fn _ ->
          {:ok, task} = Background.start("true", owner: self(), dir: dir)

          receive do
            {:seedling_background, result} ->
              assert result.id == task.id
              assert result.exit_code == 0
              assert result.status == :completed
          after
            5000 -> flunk("instant command did not complete")
          end
        end, max_concurrency: 20, timeout: 10_000)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, _}, &1))
  end

  test "bounded tail retains full output", %{dir: dir} do
    assert {:ok, r} = Shell.sh("seq 1 10000", dir: dir, max_bytes: 100, max_lines: 3)
    assert r.truncated
    assert byte_size(r.output) <= 100
    assert r.output =~ "10000"
    assert r.total_bytes > 10000
  end

  test "timeout and cancellation kill real OS commands", %{dir: dir} do
    assert {:ok, r} = Shell.sh("printf before; sleep 10; printf after", dir: dir, timeout: 100)
    assert r.status == :timed_out
    assert r.output =~ "before"
    refute r.output =~ "after"
    assert {:ok, task} = Background.start("sleep 10", dir: dir, owner: self())
    assert Nano.Ops.owner(task.pid) == nil
    assert :ok = Background.cancel(task)
    assert_receive {:seedling_background, %{status: :cancelled}}, 2000
  end

  test "worker survives caller death and routes to replacement named owner", %{dir: dir} do
    name = "shell-" <> Base.url_encode64(:crypto.strong_rand_bytes(12))
    parent = self()

    old =
      spawn(fn ->
        :yes = Nano.Names.register_name({:agent, name}, self())
        Process.put(:"$callers", [self()])
        {:ok, task} = Background.start("sleep 0.2; printf survived", dir: dir)
        send(parent, {:task, task})

        receive do
          :die -> :ok
        end
      end)

    assert_receive {:task, task}
    assert Nano.Ops.owner(task.pid) == name
    send(old, :die)
    Process.sleep(350)
    assert Process.alive?(task.pid)
    :yes = Nano.Names.register_name({:agent, name}, self())
    assert_receive {:seedling_background, r}, 2000
    assert r.owner == name
    assert File.read!(r.output_path) == "survived"
    Nano.Names.unregister_name({:agent, name})
  end

  test "operator brutal kill cleans up descendants and sends interrupted event", %{dir: dir} do
    marker = Path.join(dir, "escaped")

    {:ok, task} =
      Background.start("(sleep 0.6; touch '#{marker}') & wait", owner: self(), dir: dir)

    Process.sleep(100)
    Process.exit(task.pid, :kill)
    assert_receive {:seedling_background, %{status: :interrupted} = record}, 2000
    assert record.interruption == {:worker_exit, ":killed"}
    Process.sleep(650)
    refute File.exists?(marker)
    assert {:ok, %{status: :interrupted}} = Background.status(task)
  end

  test "boot scanner marks stale running record interrupted, never reruns command", %{dir: dir} do
    {:ok, task} = Background.start("true", owner: self(), dir: dir)
    assert_receive {:seedling_background, record}, 2000
    fake = %{record | status: :running}
    :ok = Background.persist(fake)
    {:ok, recovery} = Seedling.Background.Recovery.start_link(dir: dir)

    assert_receive {:seedling_background, %{status: :interrupted, interruption: :node_restart}},
                   2000

    GenServer.stop(recovery)
    assert {:ok, %{status: :interrupted}} = Background.receipt(task.receipt_path)
  end

  test "unlinked worker survives initiating eval-like process", %{dir: dir} do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, task} = Background.start("sleep 0.1; echo ok", owner: parent, dir: dir)
        send(parent, {:started, task})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, task}
    Process.exit(pid, :kill)
    assert Process.alive?(task.pid)
    assert_receive {:seedling_background, %{exit_code: 0}}, 2000
  end
end

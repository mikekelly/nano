defmodule Seedling.BackgroundTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "orion-bg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "waits for all output and records result", %{root: root} do
    {:ok, pid, id} =
      Seedling.Background.start("echo first; sleep 0.15; echo last",
        owner: "test-background",
        root: root
      )

    Process.sleep(30)
    assert Seedling.Background.info(pid).status == :running
    Process.sleep(300)
    info = Seedling.Background.info(pid)
    assert info.status == 0
    assert {:ok, "first\nlast\n"} = Seedling.Background.tail(info.output)
    assert File.exists?(Path.join([root, "test-background", id, "result.json"]))
    GenServer.stop(pid)
  end

  test "timeout kills shell session", %{root: root} do
    {:ok, pid, _} =
      Seedling.Background.start("echo begin; sleep 10; echo bad",
        owner: "test-background",
        root: root,
        timeout: 100
      )

    Process.sleep(350)
    info = Seedling.Background.info(pid)
    assert info.reason == :timeout
    assert is_integer(info.status) and info.status != 0
    assert {:ok, text} = Seedling.Background.tail(info.output)
    assert text =~ "begin\n"
    refute text =~ "bad"
    GenServer.stop(pid)
  end

  test "unlinked job survives caller death and cancellation", %{root: root} do
    parent = self()

    caller =
      spawn(fn ->
        result = Seedling.Background.start("sleep 20", owner: "test-background", root: root)
        send(parent, result)
      end)

    ref = Process.monitor(caller)
    assert_receive {:ok, pid, _}
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
    assert Process.alive?(pid)
    Process.sleep(100)
    Seedling.Background.cancel(pid)
    Process.sleep(250)
    assert Seedling.Background.info(pid).reason == :cancelled
    assert Seedling.Background.info(pid).status != :running
    GenServer.stop(pid)
  end

  test "completion reaches restored agent and is attributed on dashboard", %{root: root} do
    alias Nano.FakeOpenRouter, as: Fake
    Fake.start()
    model = Fake.model()
    Fake.listen(model)
    name = "bg-owner-#{System.unique_integer([:positive])}"
    {:ok, agent} = NanoAgent.start([name: name] ++ Fake.opts(model))

    on_exit(fn ->
      if pid = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      Nano.StateStore.delete(name)
    end)

    {:ok, job, id} =
      Seedling.Background.start("sleep 0.5; echo survived", owner: name, root: root)

    assert Nano.Ops.process(job).kind == {:spawned_by, name}
    Process.exit(agent, :operator_restart)

    wait = fn wait, n ->
      case NanoAgent.whereis(name) do
        pid when is_pid(pid) and pid != agent ->
          pid

        _ when n > 0 ->
          Process.sleep(10)
          wait.(wait, n - 1)

        _ ->
          flunk("agent did not restart")
      end
    end

    restored = wait.(wait, 100)
    assert restored != agent
    assert Process.alive?(job)
    Fake.push(model, calls: [idle: nil])
    assert_receive {:openrouter_request, ^model, _restart_note}, 3000
    Fake.push(model, calls: [idle: nil])
    assert_receive {:openrouter_request, ^model, body}, 3000
    assert inspect(body) =~ id
    assert inspect(body) =~ "background"
    assert inspect(body) =~ "survived" == false
    assert File.read!(Path.join([root, name, id, "output.log"])) == "survived\n"
  end
end

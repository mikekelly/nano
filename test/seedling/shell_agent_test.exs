defmodule Seedling.ShellAgentTest do
  # A genuine supervised agent, with a scripted provider. Never spends or changes
  # the live node; Fake.start changes settings in this isolated test VM.
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake
  alias Seedling.Shell

  test "a command launched from eval survives NanoAgent restart and wakes the new pid" do
    saved_url = Nano.Settings.get(:openrouter_base_url)
    Fake.start()
    model = Fake.model()
    name = "shell-real-restart-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    dir =
      Path.join(
        System.tmp_dir!(),
        "atlas-shell-agent-" <> Base.encode16(:crypto.strong_rand_bytes(10))
      )

    File.mkdir_p!(dir)

    on_exit(fn ->
      if pid = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(name)
      Nano.Settings.put(:openrouter_base_url, saved_url)
      File.rm_rf(dir)
    end)

    receiver = ":erlang.list_to_pid(#{inspect(:erlang.pid_to_list(self()))})"

    code =
      "{:ok, task} = Seedling.Shell.background(\"sleep 2; echo finished\", spool_dir: #{inspect(dir)}); send(#{receiver}, {:launched, task})"

    Fake.push(model, calls: [eval: code])
    Fake.push(model, calls: [idle: nil])
    Fake.push(model, calls: [idle: nil])
    Fake.push(model, text: "completion received")
    {:ok, old} = NanoAgent.start([name: name] ++ Fake.opts(model, start_idle: true))
    send(old, :begin_command)
    assert_receive {:openrouter_request, ^model, _}, 2_000
    assert_receive {:launched, task}, 2_000
    on_exit(fn -> Shell.cancel(task) end)
    assert_receive {:openrouter_request, ^model, _}, 2_000
    wait_for(fn -> NanoAgent.info(name).status == :idle end)
    assert Nano.Ops.process(task.pid).kind == {:spawned_by, name}

    :sys.get_state(old)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}, 2_000
    wait_for(fn -> is_pid(NanoAgent.whereis(name)) and NanoAgent.whereis(name) != old end)
    new = NanoAgent.whereis(name)
    assert Process.alive?(task.pid)
    assert {:ok, %{status: :running}} = Shell.status(task)
    wait_for(fn -> Nano.Ops.process(task.pid).kind == {:spawned_by, name} end)

    # Restart itself produces a harness event and a scripted idle response.
    assert_receive {:openrouter_request, ^model, _restart_body}, 2_000
    assert_receive {:openrouter_request, ^model, body}, 5_000

    delivered =
      body["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last() |> Jason.encode!()

    assert delivered =~ "seedling_task"
    assert delivered =~ task.id
    assert delivered =~ task.output_path
    refute delivered =~ "finished\\n"
    assert NanoAgent.whereis(name) == new
    assert {:ok, %{status: :exited, exit_code: 0}} = Shell.status(task)
    assert {:ok, %{output: "finished\n"}} = Shell.tail(task)
  end

  defp wait_for(fun, tries \\ 200)

  defp wait_for(fun, tries) when tries > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_for(fun, tries - 1)
        )
  end

  defp wait_for(_fun, 0), do: flunk("agent did not reach the expected state")
end

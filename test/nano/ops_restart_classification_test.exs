defmodule Nano.OpsRestartClassificationTest do
  use ExUnit.Case, async: false

  test "restarted infrastructure stays hidden while agent user and eval attribution survives" do
    old = Process.whereis(Nano.StateStore)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, _}, 2000

    eventually(fn ->
      is_pid(Process.whereis(Nano.StateStore)) and Process.whereis(Nano.StateStore) != old
    end)

    store = Process.whereis(Nano.StateStore)
    refute MapSet.member?(Nano.Application.boot_set(), store)
    refute Enum.any?(Nano.Ops.processes(), &(&1.pid == store))
    assert Nano.Ops.process(store).kind == :standard
    Nano.FakeOpenRouter.start()
    model = Nano.FakeOpenRouter.model()
    name = "ops-restart-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, agent} = Nano.Ops.start_agent(name, Nano.FakeOpenRouter.opts(model))
    user_name = name <> "-user"
    user = Nano.User.start(user_name)

    on_exit(fn ->
      Nano.Ops.stop_agent(name)
      DynamicSupervisor.terminate_child(Nano.UserSupervisor, user)
    end)

    assert Nano.Ops.process(agent).kind == :agent
    assert Nano.Ops.process(user).kind == :user
    Nano.FakeOpenRouter.listen(model)
    source = ":erlang.list_to_pid(" <> inspect(:erlang.pid_to_list(self())) <> ")"

    Nano.FakeOpenRouter.push(model,
      calls: [eval: "send(" <> source <> ", {:eval_alive,self()}); Process.sleep(:infinity)"]
    )

    NanoAgent.notify(agent, :go)
    assert_receive {:eval_alive, eval}, 2000
    assert Nano.Ops.process(eval).kind == {:spawned_by, name}
  end

  defp eventually(fun, n \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, n - 1)
        )
  end
end

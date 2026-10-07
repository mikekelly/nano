defmodule Nano.NamesTest do
  # Async: killing or flooding Nano.Names is meant to be harmless to everything else running.
  use ExUnit.Case, async: true

  alias Nano.Names

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  # A real agent, started idle, so it makes no model call unless sent a message.
  defp start_agent do
    Nano.FakeOpenRouter.start()
    name = unique("agent")
    model = Nano.FakeOpenRouter.model()
    {:ok, pid} = Nano.Ops.start_agent(name, Nano.FakeOpenRouter.opts(model))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    {name, pid}
  end

  defp start_user do
    name = unique("u")
    pid = Nano.User.start(name)
    on_exit(fn -> DynamicSupervisor.terminate_child(Nano.UserSupervisor, pid) end)
    {name, pid}
  end

  # A process holding a name until killed.
  defp named(key) do
    test = self()

    pid =
      spawn(fn -> send(test, Names.register_name(key, self())) && Process.sleep(:infinity) end)

    assert_receive :yes
    pid
  end

  defp row(key), do: :ets.lookup(Names, key)

  defp kill_names do
    old = Process.whereis(Names)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    wait_for(fn -> (pid = Process.whereis(Names)) && pid != old end)
  end

  defp wait_for(fun, tries \\ 200) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(10) && wait_for(fun, tries - 1)

      result ->
        assert(result) && result
    end
  end

  test "via tuples: calls and casts reach the process, and a taken name is refused" do
    via = {:via, Names, {:test, unique("n")}}
    {:ok, pid} = Agent.start(fn -> 1 end, name: via)
    assert Agent.get(via, & &1) == 1
    Agent.cast(via, &(&1 + 1))
    assert Agent.get(via, & &1) == 2
    assert GenServer.whereis(via) == pid
    assert Agent.start(fn -> 0 end, name: via) == {:error, {:already_started, pid}}
    assert Names.register_name(elem(via, 2), self()) == :no
    Agent.stop(via)
    assert Names.whereis_name(elem(via, 2)) == :undefined
  end

  test "a process's name goes when it dies, and is free again" do
    key = {:test, unique("n")}
    pid = named(key)
    Process.exit(pid, :kill)
    wait_for(fn -> row(key) == [] end)
    assert Names.register_name(key, self()) == :yes
    assert Names.whereis_name(key) == self()
  end

  test "stray messages leave Nano.Names, agents and users as they were" do
    {agent, agent_pid} = start_agent()
    {user, user_pid} = start_user()
    names = Process.whereis(Names)

    # Linked to their supervisors and nothing else.
    assert Process.info(agent_pid, :links) == {:links, [Process.whereis(Nano.AgentSupervisor)]}
    assert Process.info(user_pid, :links) == {:links, [Process.whereis(Nano.UserSupervisor)]}

    send(names, :junk)
    send(names, {:DOWN, make_ref(), :process, agent_pid, :forged})
    GenServer.cast(names, :junk)
    GenServer.cast(names, {:monitor, :not_a_pid})
    assert GenServer.call(names, {:junk, self()}) == {:error, :unknown_call}

    assert Process.whereis(Names) == names
    assert Process.alive?(agent_pid) and Process.alive?(user_pid)
    assert NanoAgent.whereis(agent) == agent_pid
    assert Nano.User.pid(user) == user_pid
    assert Nano.Ops.agent(agent).restart_count == 0
  end

  test "killing Nano.Names leaves agents and users running, named and listed" do
    {agent, agent_pid} = start_agent()
    {user, user_pid} = start_user()
    kill_names()

    assert Process.alive?(agent_pid) and Process.alive?(user_pid)
    assert NanoAgent.whereis(agent) == agent_pid
    assert Nano.User.pid(user) == user_pid
    assert user in Nano.User.list()
    assert %{kind: :agent, name: ^agent} = Enum.find(Nano.Ops.processes(), &(&1.pid == agent_pid))
    assert Nano.Ops.agent(agent).restart_count == 0

    # The restarted server watches them again: their names still go when they die.
    Nano.Ops.stop_agent(agent)
    wait_for(fn -> row({:agent, agent}) == [] end)
  end

  test "a name whose process died while Nano.Names was down is removed when it is back" do
    key = {:test, unique("n")}
    pid = named(key)

    # Suspended, it cannot handle the DOWN; killed, it loses it.
    :sys.suspend(Names)
    Process.exit(pid, :kill)
    refute Process.alive?(pid)
    assert row(key) == [{key, pid}]
    assert Names.whereis_name(key) == :undefined
    refute {key, pid} in Names.all()
    kill_names()

    wait_for(fn -> row(key) == [] end)
  end
end

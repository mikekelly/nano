defmodule Nano.OpsTest do
  # Not async: one test changes :eval_timeout_ms.
  use ExUnit.Case

  alias Nano.Ops

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp start_user do
    name = unique("u")
    pid = Nano.User.start(name)
    on_exit(fn -> DynamicSupervisor.terminate_child(Nano.UserSupervisor, pid) end)
    {name, pid}
  end

  # A real agent, started idle, so it makes no model call unless sent a message.
  defp start_agent do
    name = unique("agent")
    {:ok, pid} = Ops.start_agent(name)
    on_exit(fn -> Ops.stop_agent(name) end)
    {name, pid}
  end

  # A process registered as an agent that runs functions the way NanoAgent runs evals: in a
  # task under Nano.EvalSupervisor. Lets the listing be tested without a model.
  defp fake_agent do
    test = self()
    name = unique("fake")

    pid =
      spawn_link(fn ->
        Registry.register(Nano.Registry, {:agent, name}, nil)
        send(test, :registered)
        fake_agent_loop()
      end)

    assert_receive :registered
    {name, pid}
  end

  defp fake_agent_loop do
    receive do
      {:eval, fun} -> Task.Supervisor.async_nolink(Nano.EvalSupervisor, fun)
      _task_reply_or_down -> :ok
    end

    fake_agent_loop()
  end

  defp sleeper, do: fn -> Process.sleep(:infinity) end

  defp kinds, do: Map.new(Ops.processes(), &{&1.pid, &1.kind})

  defp wait_dead(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
  end

  describe "resolve/1" do
    test "pids, names and pid strings" do
      {user, user_pid} = start_user()
      {agent, agent_pid} = fake_agent()
      store = Process.whereis(Nano.StateStore)

      assert Ops.resolve(self()) == self()
      assert Ops.resolve(user) == user_pid
      assert Ops.resolve(agent) == agent_pid
      assert Ops.resolve(Nano.StateStore) == store
      assert Ops.resolve("Nano.StateStore") == store
      assert Ops.resolve("Elixir.Nano.StateStore") == store
      assert Ops.resolve(":code_server") == Process.whereis(:code_server)
      assert Ops.resolve("code_server") == Process.whereis(:code_server)
      assert Ops.resolve(inspect(store)) == store
      assert Ops.resolve(String.trim_leading(inspect(store), "#PID")) == store
    end

    test "unknown targets and dead pids are nil" do
      dead = spawn(fn -> :ok end)
      wait_dead(dead)

      assert Ops.resolve(dead) == nil
      assert Ops.resolve(inspect(dead)) == nil
      assert Ops.resolve("no_such_thing_#{System.unique_integer()}") == nil
      assert Ops.resolve("#PID<1.2.3>") == nil
      assert Ops.resolve("#PID<0.x.3>") == nil
      assert Ops.resolve(:no_such_registered_name) == nil
      assert Ops.resolve(42) == nil
    end
  end

  describe "eval/1 and term/1" do
    test "returns the inspected result and captured output" do
      assert Ops.eval("1 + 1") == {:ok, "2", ""}
      assert Ops.eval(~s|IO.puts("hi"); %{a: 1}|) == {:ok, "%{a: 1}", "hi\n"}
      assert {:ok, list, _} = Ops.eval("Enum.to_list(1..100)")
      refute list =~ "..."
    end

    test "parse and eval failures return the exception message" do
      assert {:error, "** (RuntimeError) boom", "before\n"} =
               Ops.eval(~s|IO.puts("before"); raise "boom"|)

      assert {:error, "** (SyntaxError)" <> _, ""} = Ops.eval("1 +* 2")
      assert {:error, "** (exit) :bye", ""} = Ops.eval("exit(:bye)")
      assert {:error, "** (throw) 1", ""} = Ops.eval("throw(1)")
      assert {:error, "** (exit) killed", ""} = Ops.eval("Process.exit(self(), :kill)")
    end

    test "is killed after EVAL_TIMEOUT_MS" do
      old = Application.get_env(:nano, :eval_timeout_ms)
      Application.put_env(:nano, :eval_timeout_ms, 100)
      on_exit(fn -> Application.put_env(:nano, :eval_timeout_ms, old) end)

      assert Ops.eval("Process.sleep(:infinity)") == {:error, "timed out after 100 ms", ""}
    end

    test "processes spawned by the code can still print after the eval ends" do
      {:ok, inspected, ""} = Ops.eval("spawn(fn -> receive do :go -> IO.puts(:ok) end end)")
      pid = Ops.resolve(inspected)
      {:group_leader, gl} = Process.info(pid, :group_leader)
      assert Process.alive?(gl)
    end

    test "term/1 gives the evaluated term itself" do
      assert Ops.term("{:ping, 42}") == {:ok, {:ping, 42}}
      assert Ops.term(~s|%{note: "hi"}|) == {:ok, %{note: "hi"}}
      assert {:error, "** (TokenMissingError)" <> _} = Ops.term("{")
    end
  end

  describe "processes/0" do
    test "lists agents first, then users and other new processes, without boot-time ones" do
      {agent, agent_pid} = fake_agent()
      {user, user_pid} = start_user()
      %Task{pid: other} = Task.Supervisor.async_nolink(Nano.EvalSupervisor, sleeper())

      processes = Ops.processes()
      by_pid = Map.new(processes, &{&1.pid, &1})

      assert %{kind: :agent, name: ^agent} = by_pid[agent_pid]
      assert %{kind: :user, name: ^user} = by_pid[user_pid]
      assert %{kind: :other, name: nil} = by_pid[other]
      refute Map.has_key?(by_pid, Process.whereis(Nano.StateStore))
      refute Map.has_key?(by_pid, Process.whereis(:code_server))

      {agents, rest} = Enum.split_while(processes, &(&1.kind == :agent))
      assert agent_pid in Enum.map(agents, & &1.pid)
      refute Enum.any?(rest, &(&1.kind == :agent))

      row = by_pid[user_pid]
      assert {:gen_server, :loop, _} = row.current_function

      assert is_integer(row.message_queue_len) and is_integer(row.memory) and
               is_integer(row.reductions)

      assert row.agent == nil
    end

    test "a real agent carries its info" do
      {name, pid} = start_agent()

      assert %{kind: :agent, name: ^name, agent: %{name: ^name, status: :idle}} =
               Enum.find(Ops.processes(), &(&1.pid == pid))
    end

    test "processes started during an agent's eval are tagged with the agent" do
      {agent, agent_pid} = fake_agent()
      test = self()

      send(
        agent_pid,
        {:eval,
         fn ->
           plain = spawn(sleeper())
           {:ok, server} = Agent.start(fn -> :state end)
           {:ok, task} = Task.start(sleeper())
           send(test, {:spawned, self(), plain, server, task})
           receive do: (:finish -> :ok)
         end}
      )

      assert_receive {:spawned, eval_task, plain, server, task}
      kinds = kinds()
      for pid <- [eval_task, plain, server, task], do: assert(kinds[pid] == {:spawned_by, agent})

      # Once the eval task has exited, only the `$callers` chain of a Task still leads to the
      # agent; a plain spawn or a GenServer started in the eval is then just "other".
      send(eval_task, :finish)
      wait_dead(eval_task)
      kinds = kinds()
      assert kinds[task] == {:spawned_by, agent}
      assert kinds[plain] == :other
      assert kinds[server] == :other
    end

    test "a real agent's eval: what it starts is tagged with the agent" do
      Nano.FakeOpenRouter.start()
      model = Nano.FakeOpenRouter.model()
      name = unique("agent")

      code = """
      test = :erlang.list_to_pid(#{inspect(~c"#{:erlang.pid_to_list(self())}")})
      {:ok, task} = Task.start(fn -> Process.sleep(:infinity) end)
      plain = spawn(fn -> Process.sleep(:infinity) end)
      send(test, {:spawned, self(), task, plain})
      receive do: (:finish -> :ok)
      """

      Nano.FakeOpenRouter.push(model, calls: [eval: code])
      Nano.FakeOpenRouter.push(model, calls: [idle: nil])
      {:ok, _} = Ops.start_agent(name, model: model)
      on_exit(fn -> Ops.stop_agent(name) end)
      NanoAgent.notify(name, :go)

      assert_receive {:spawned, eval_task, task, plain}, 5_000
      kinds = kinds()
      for pid <- [eval_task, task, plain], do: assert(kinds[pid] == {:spawned_by, name})

      send(eval_task, :finish)
      wait_dead(eval_task)
      kinds = kinds()
      assert kinds[task] == {:spawned_by, name}
      assert kinds[plain] == :other
    end

    test "processes of other OTP applications and under the endpoint are standard" do
      # Req starts a Finch pool on first use of a host, after boot.
      Req.get("http://127.0.0.1:1/", retry: false)
      boot = Nano.Application.boot_set()

      finch =
        for pid <- Process.list(),
            pid not in boot,
            :application.get_application(pid) == {:ok, :req},
            do: pid

      assert finch != []

      under_endpoint =
        spawn(fn ->
          Process.put(:"$ancestors", [self(), NanoWeb.Endpoint, Nano.Supervisor])
          Process.sleep(:infinity)
        end)

      listed = kinds()
      for pid <- finch, do: refute(Map.has_key?(listed, pid))
      refute Map.has_key?(listed, under_endpoint)
    end
  end

  describe "process/1" do
    test "Process.info detail with pid and kind" do
      {user, user_pid} = start_user()

      assert %{
               pid: ^user_pid,
               kind: :user,
               current_function: {:gen_server, :loop, _},
               dictionary: _
             } =
               Ops.process(user)

      assert %{kind: :standard, registered_name: Nano.StateStore} = Ops.process("Nano.StateStore")
      assert Ops.process(inspect(user_pid)).pid == user_pid
      assert Ops.process("nobody_#{System.unique_integer()}") == nil
    end
  end

  describe "agents" do
    test "start, list, info and log" do
      {name, pid} = start_agent()

      assert Ops.whereis(name) == pid
      assert %{name: ^name, pid: ^pid, status: :idle} = Ops.agent(name)
      assert name in Enum.map(Ops.agents(), & &1.name)
      assert [%{"type" => "agent_started", "seq" => seq} | _] = Ops.log(name, 0)
      assert Ops.log(name, seq) |> Enum.all?(&(&1["seq"] > seq))
      assert {:error, {:already_started, ^pid}} = Ops.start_agent(name)
    end

    test "restart kills the process and the supervisor brings it back under the same name" do
      {name, pid} = start_agent()
      ref = Process.monitor(pid)
      assert Ops.restart_agent(name) == :ok
      assert_receive {:DOWN, ^ref, _, _, :operator_restart}
      wait_for(fn -> Ops.whereis(name) not in [nil, pid] end)
    end

    test "resume a suspended agent" do
      {name, pid} = start_agent()
      :sys.suspend(pid)
      assert Ops.agent(name).suspended
      assert Ops.resume(name) == :ok
      refute Ops.agent(name).suspended
    end

    test "unhalt is a cast to the agent" do
      {name, _} = start_agent()
      assert Ops.unhalt(name) == :ok
    end

    test "stop terminates the agent and deletes its state" do
      {name, pid} = start_agent()
      assert Ops.stop_agent(name) == :ok
      refute Process.alive?(pid)
      assert Ops.agent(name) == nil
      # The Registry drops a dead process asynchronously.
      wait_for(fn -> Ops.whereis(name) == nil end)
      refute name in NanoAgent.list()
    end

    test "unknown agents" do
      name = unique("nobody")

      for verb <- [:stop_agent, :restart_agent, :resume, :unhalt, :log, :tail] do
        assert apply(Ops, verb, [name]) == {:error, :not_found}
      end

      assert Ops.agent(name) == nil
    end

    test "tail prints the last entries, then new ones, to the caller's group leader" do
      {name, _} = start_agent()
      %{id: id} = Ops.agent(name)
      {:ok, io} = StringIO.open("")
      gl = Process.group_leader()
      Process.group_leader(self(), io)
      {:ok, tailer} = Ops.tail(name)
      Process.group_leader(self(), gl)

      wait_for(fn -> StringIO.contents(io) |> elem(1) =~ "agent_started" end)
      Nano.Log.write(%{id: id, name: name}, :note, %{text: "tailed"})
      wait_for(fn -> StringIO.contents(io) |> elem(1) =~ ~s(note %{"text" => "tailed"}) end)

      Process.exit(tailer, :kill)
    end

    test "tail stops when the shell that started it exits" do
      {name, _} = start_agent()
      test = self()
      {:ok, io} = StringIO.open("")

      shell =
        spawn(fn ->
          Process.group_leader(self(), io)
          send(test, Ops.tail(name))
        end)

      assert_receive {:ok, tailer}
      wait_dead(shell)
      wait_dead(tailer)
    end
  end

  defp wait_for(fun, tries \\ 100) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(10) && wait_for(fun, tries - 1)

      result ->
        assert(result) && result
    end
  end
end

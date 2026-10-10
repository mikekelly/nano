Code.require_file("fixtures.ex", __DIR__)

defmodule Nano.Flywheel.U05.RecoveryTest do
  use ExUnit.Case, async: false
  alias Nano.StateStore, as: Store
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()

    on_exit(fn ->
      Application.delete_env(:nano, :state_store_fault)
      if Process.whereis(Store) == nil, do: Supervisor.restart_child(Nano.Supervisor, Store)
    end)

    %{prefix: "u05-" <> Integer.to_string(System.unique_integer([:positive]))}
  end

  defp agent(c, suffix) do
    name = c.prefix <> suffix
    model = Fake.model()
    Fake.listen(model)
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model))

    on_exit(fn ->
      if p = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)
        NanoAgent.kill_tasks(p)
      end

      Store.delete(name)
    end)

    %{name: name, model: model, pid: pid}
  end

  defp eval(a, code) do
    Fake.push(a.model, calls: [eval: code])
    Fake.push(a.model, text: "done")
    send(a.pid, :go)
    model = a.model
    assert_receive {:openrouter_request, ^model, _}, 5000
    assert_receive {:openrouter_request, ^model, _}, 5000
    eventually(fn -> :sys.get_state(a.pid).status == :idle end)
  end

  defp eventually(fun, remaining \\ 500) do
    if fun.() do
      :ok
    else
      if remaining == 0, do: flunk("production recovery condition did not become true")
      Process.sleep(10)
      eventually(fun, remaining - 1)
    end
  end

  defp restart_store do
    old = Store.recovery_generation()
    Process.exit(Process.whereis(Store), :kill)

    eventually(fn ->
      Store.availability() == :ok and Store.recovery_generation() not in [old, :unavailable]
    end)
  end

  test "A1 multiple actual agents resave coherent bindings after store kill then agent kill", c do
    agents = for suffix <- ["a", "b"], do: agent(c, suffix)
    for {a, value} <- Enum.with_index(agents, 51), do: eval(a, "retained = #{value}")
    stale = for a <- agents, do: :sys.get_state(a.pid).store_token
    restart_store()

    for {a, value} <- Enum.with_index(agents, 51) do
      eventually(fn ->
        match?({:ok, _, _}, Store.binding_status(a.name)) and
          Store.registered?(:sys.get_state(a.pid).store_token)
      end)

      assert Store.bindings(a.name) |> elem(0) |> Keyword.fetch!(:retained) == value
      state = :sys.get_state(a.pid)

      assert {:error, :stale} =
               Store.checkpoint(
                 Enum.find(stale, &(&1.name == a.name)),
                 state.state_revision + 100,
                 Map.delete(state, :bindings),
                 retained: -1
               )

      Process.exit(a.pid, :kill)

      eventually(fn ->
        is_pid(NanoAgent.whereis(a.name)) and NanoAgent.whereis(a.name) != a.pid
      end)

      new = NanoAgent.whereis(a.name)
      assert :sys.get_state(new).bindings[:retained] == value
      assert Store.get(a.name).id == state.id

      assert :sys.get_state(new).store_token.lifecycle_generation ==
               state.store_token.lifecycle_generation
    end
  end

  test "A2 explicit empty commit, old incarnation and delete/recreate tombstone fencing", c do
    a = agent(c, "empty")
    eval(a, "retained = 99")
    before = :sys.get_state(a.pid)
    :sys.replace_state(a.pid, fn s -> Map.put(%{s | bindings: []}, :bindings_dirty, true) end)
    GenServer.cast(a.pid, :resave)
    :sys.get_state(a.pid)
    assert {[], []} = Store.bindings(a.name)
    assert :ok = Nano.Ops.stop_agent(a.name)

    assert {:error, :stale} =
             Store.checkpoint(
               before.store_token,
               before.state_revision + 100,
               Map.delete(before, :bindings),
               before.bindings
             )

    restart_store()
    assert Store.get(a.name) == nil
    assert Store.bindings(a.name) == :unavailable
    assert {:error, :deleted} = Store.register(a.name, before.id, self())
    {:ok, new} = NanoAgent.start([name: a.name] ++ Fake.opts(a.model))
    state = :sys.get_state(new)
    assert state.id != before.id
    assert state.store_token.lifecycle_generation > before.store_token.lifecycle_generation
    assert state.bindings == []

    assert {:error, :stale} =
             Store.register(a.name, state.id, new, before.store_token.store_generation)

    assert {:error, :stale} =
             Store.checkpoint(
               before.store_token,
               before.state_revision + 200,
               Map.delete(before, :bindings),
               before.bindings
             )
  end

  test "A2 eval completion during store absence preserves evidence and holds next launch", c do
    a = agent(c, "completion")
    test_pid = self() |> :erlang.pid_to_list() |> List.to_string()

    code =
      "send(:erlang.list_to_pid(~c\"#{test_pid}\"), :u05_eval_started); completed = receive do :finish -> 731 end"

    Fake.push(a.model, calls: [eval: code])
    Fake.push(a.model, text: "completed")
    send(a.pid, :go)
    model = a.model
    assert_receive {:openrouter_request, ^model, _}, 5000
    assert_receive :u05_eval_started, 5000
    state = :sys.get_state(a.pid)
    :ok = Supervisor.terminate_child(Nano.Supervisor, Store)
    send(state.task.task.pid, :finish)
    eventually(fn -> :sys.get_state(a.pid).bindings[:completed] == 731 end)
    assert :sys.get_state(a.pid).durability.status == :recovering
    refute_receive {:openrouter_request, ^model, _}, 100
    {:ok, _} = Supervisor.restart_child(Nano.Supervisor, Store)
    assert_receive {:openrouter_request, ^model, body}, 5000

    assert Enum.any?(
             body["messages"],
             &(&1["role"] == "tool" and String.contains?(inspect(&1["content"]), "731"))
           )

    eventually(fn -> Store.bindings(a.name) != :unavailable end)
    assert Store.bindings(a.name) |> elem(0) |> Keyword.fetch!(:completed) == 731
  end

  test "A2 a suspended live agent remains visibly unavailable until asynchronous resave", c do
    a = agent(c, "suspended")
    eval(a, "retained = 444")
    :sys.suspend(a.pid)
    on_exit(fn -> if Process.alive?(a.pid), do: :sys.resume(a.pid) end)
    restart_store()
    assert Store.get(a.name) == nil
    assert Store.binding_status(a.name) == :unavailable
    assert %{status: :recovering} = Nano.Ops.durability().agents[a.name]
    :sys.resume(a.pid)
    eventually(fn -> match?({:ok, _, _}, Store.binding_status(a.name)) end)
    assert Store.bindings(a.name) |> elem(0) |> Keyword.fetch!(:retained) == 444
  end

  test "A3 commit-before-reply crash restores only coherent committed pair and fences old token",
       c do
    name = c.prefix <> "ack"

    on_exit(fn ->
      Application.delete_env(:nano, :state_store_fault)
      Store.delete(name)
    end)

    {:ok, token} = Store.register(name, name, self())
    metadata = %{name: name, id: name, pid: self(), pending: [:completed_evidence]}
    assert {:ok, _} = Store.checkpoint(token, 1, metadata, value: 1)

    Application.put_env(:nano, :state_store_fault, fn stage, path ->
      if stage == :after_commit and String.ends_with?(path, ".envelope-v1") do
        Application.delete_env(:nano, :state_store_fault)
        exit(:u05_commit_before_reply)
      else
        :ok
      end
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :unavailable} =
                 Store.checkpoint(token, 2, metadata,
                   value: 2,
                   private_secret: "u05-redaction-sentinel"
                 )
      end)

    refute log =~ "u05-redaction-sentinel"

    eventually(fn ->
      Store.availability() == :ok and
        Store.recovery_generation() not in [token.store_generation, :unavailable]
    end)

    assert Store.get(name) == metadata
    assert Store.bindings(name) == {[private_secret: "u05-redaction-sentinel", value: 2], []}
    assert %{durable_revision: 2} = Store.durability(name)
    assert {:error, :stale} = Store.checkpoint(token, 3, metadata, value: 3)
    Store.delete(name)
  end

  test "A3 each blob/envelope publication fault acknowledges memory_only, not durable", c do
    name = c.prefix <> "fault"
    {:ok, token} = Store.register(name, name <> "-id", self())
    metadata = %{name: name, id: token.id, pid: self(), evidence: "baseline"}

    assert {:ok, %{status: :durable, durable_revision: 1}} =
             Store.checkpoint(token, 1, metadata, value: 1)

    on_exit(fn ->
      Application.delete_env(:nano, :state_store_fault)
      Store.delete(name)
    end)

    for {{suffix, stage}, revision} <-
          Enum.with_index(
            for(
              suffix <- [".bindings-v1", ".envelope-v1"],
              stage <- [
                :before_write,
                :before_fsync,
                :before_rename,
                :before_directory_sync,
                :after_commit
              ],
              do: {suffix, stage}
            ),
            2
          ) do
      Application.put_env(:nano, :state_store_fault, fn point, path ->
        if point == stage and String.ends_with?(path, suffix), do: {:error, :injected}, else: :ok
      end)

      assert {:ok,
              %{
                status: :memory_only,
                accepted_revision: ^revision,
                durable_revision: 1,
                warning: warning
              }} = Store.checkpoint(token, revision, metadata, value: revision)

      assert warning =~ "simultaneous"
      assert Store.bindings(name) == {[value: revision], []}
    end

    Application.delete_env(:nano, :state_store_fault)

    assert {:ok, %{status: :durable, durable_revision: 20}} =
             Store.checkpoint(token, 20, metadata, :unchanged)

    assert Store.bindings(name) == {[value: 11], []}
  end

  test "A3 critical tombstone persistence failure fails closed and retains active state", c do
    name = c.prefix <> "delete"
    {:ok, token} = Store.register(name, name, self())
    metadata = %{name: name, id: name, pid: self()}
    assert {:ok, _} = Store.checkpoint(token, 1, metadata, [])

    Application.put_env(:nano, :state_store_fault, fn point, path ->
      if point == :before_write and String.ends_with?(path, "lifecycle-v1.term"),
        do: {:error, :injected},
        else: :ok
    end)

    assert {:error, :injected} = Store.delete(name)
    assert Store.get(name) == metadata
    assert {:error, :degraded} = Store.register(c.prefix <> "blocked", "blocked", self())
    Application.delete_env(:nano, :state_store_fault)
    restart_store()
    assert Store.get(name) == metadata
    assert Store.bindings(name) == {[], []}
    Store.delete(name)
  end

  test "new eval does not run while registration is unavailable at task-spawn boundary" do
    Fake.start()
    model = Fake.model()
    Fake.listen(model)
    name = "u05-review-launch-race"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model))

    on_exit(fn ->
      if Process.alive?(Process.whereis(Nano.EvalSupervisor)),
        do: :sys.resume(Nano.EvalSupervisor)

      if p = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)

      if Process.whereis(Nano.StateStore) == nil,
        do: Supervisor.restart_child(Nano.Supervisor, Nano.StateStore)

      Nano.StateStore.delete(name)
    end)

    send(pid, :go)
    assert_receive {:openrouter_request, ^model, _}, 5000
    :ok = :sys.suspend(Nano.EvalSupervisor)
    target = self() |> :erlang.pid_to_list() |> List.to_string()

    Fake.push(model,
      calls: [
        eval:
          "send(:erlang.list_to_pid(~c\"#{target}\"), {:eval_effect, Nano.StateStore.availability()})"
      ]
    )

    eventually(fn ->
      {:messages, messages} = Process.info(Process.whereis(Nano.EvalSupervisor), :messages)
      Enum.any?(messages, fn msg -> match?({:"$gen_call", _, _}, msg) end)
    end)

    :ok = Supervisor.terminate_child(Nano.Supervisor, Nano.StateStore)
    assert Nano.StateStore.availability() == {:error, :unavailable}
    :ok = :sys.resume(Nano.EvalSupervisor)
    refute_receive {:eval_effect, _}, 200
    {:ok, _} = Supervisor.restart_child(Nano.Supervisor, Nano.StateStore)
    assert_receive {:eval_effect, :ok}, 5000
  end

  test "store recovery memory_only acknowledgment retains exact last durable revision" do
    Fake.start()
    model = Fake.model()
    name = "u05-review-last-durable"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model))
    :ok = :sys.suspend(pid)
    # Suspension is the observation barrier: startup resave may commit another revision.
    before = Nano.StateStore.durability(name).durable_revision
    assert before > 0

    on_exit(fn ->
      Application.delete_env(:nano, :state_store_fault)

      if p = NanoAgent.whereis(name) do
        :sys.resume(p)
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)
      end

      Nano.StateStore.delete(name)
    end)

    :ok = Supervisor.terminate_child(Nano.Supervisor, Nano.StateStore)
    {:ok, _} = Supervisor.restart_child(Nano.Supervisor, Nano.StateStore)
    assert %{status: :recovering} = Nano.StateStore.durability(name)

    Application.put_env(:nano, :state_store_fault, fn stage, path ->
      if stage == :before_write and String.ends_with?(path, ".envelope-v1"),
        do: {:error, :injected},
        else: :ok
    end)

    :ok = :sys.resume(pid)
    eventually(fn -> match?(%{status: :memory_only}, Nano.StateStore.durability(name)) end)
    ack = Nano.StateStore.durability(name)
    assert ack.durable_revision == before
  end

  test "dead live-resave actor recovers last coherent durable pair" do
    Fake.start()
    model = Fake.model()
    name = "r2-death-during-recovery"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model))

    :sys.replace_state(pid, fn s ->
      Map.put(%{s | bindings: [retained: 321]}, :bindings_dirty, true)
    end)

    GenServer.cast(pid, :resave)
    state = :sys.get_state(pid)
    assert Store.bindings(name) == {[retained: 321], []}
    assert Store.durability(name).status == :durable
    old_token = :sys.get_state(pid).id

    on_exit(fn ->
      if p = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)

      Store.delete(name)
    end)

    :ok = :sys.suspend(pid)
    :ok = Supervisor.terminate_child(Nano.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(Nano.Supervisor, Store)
    assert Store.get(name) == nil
    assert Store.durability(name).status == :recovering
    Process.exit(pid, :kill)

    eventually(fn ->
      p = NanoAgent.whereis(name)
      is_pid(p) and p != pid
    end)

    observed = NanoAgent.whereis(name)

    IO.puts(
      "R2_DEAD_RESAVER " <>
        inspect(%{
          pid: observed,
          store: Store.durability(name),
          coherent_envelope:
            File.exists?(
              Path.join(Application.fetch_env!(:nano, :state_dir), name <> ".envelope-v1")
            )
        })
    )

    assert :ok == NanoAgent.revive(Nano.AgentSupervisor)
    assert NanoAgent.whereis(name) == observed
    :ok = Supervisor.terminate_child(Nano.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(Nano.Supervisor, Store)
    eventually(fn -> Store.bindings(name) == {[retained: 321], []} end)
    :ok = NanoAgent.revive(Nano.AgentSupervisor)
    recovered = NanoAgent.whereis(name)
    assert is_pid(recovered)
    assert :sys.get_state(recovered).id == state.id
    assert :sys.get_state(recovered).bindings[:retained] == 321
    IO.puts("R2_SECOND_STORE_RESTART_RESTORES_ORIGINAL_ID_AND_BINDINGS")
    assert is_pid(observed)
    assert :sys.get_state(observed).id == old_token
    assert :sys.get_state(observed).id == state.id
    assert :sys.get_state(observed).bindings[:retained] == 321
  end

  test "recovery registration cannot steal a still-live current incarnation" do
    Fake.start()
    name = "r3-live-registration"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(Fake.model()))
    state = :sys.get_state(pid)
    :ok = :sys.suspend(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: :sys.resume(pid)

      if p = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)

      Store.delete(name)
    end)

    :ok = Supervisor.terminate_child(Nano.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(Nano.Supervisor, Store)
    assert Store.get(name) == nil
    assert Store.durability(name).status == :recovering
    assert {:error, :incarnation_active} = Store.watch(name, self())

    assert {:error, :incarnation_active} =
             Store.register(name, state.id <> "-foreign", self(), Store.recovery_generation())

    result = Store.register(name, state.id, self(), Store.recovery_generation())
    IO.puts("R3_LIVE_INCARCATION_STEAL " <> inspect(result))

    if match?({:ok, _}, result) do
      {:ok, token} = result

      ack =
        Store.checkpoint(
          token,
          state.state_revision + 100,
          %{name: name, id: state.id, pid: self(), pending: [:foreign_incarnation]},
          retained: -1
        )

      IO.puts("R3_FOREIGN_CHECKPOINT " <> inspect(ack))
    end

    assert {:error, :incarnation_active} == result
    :ok = :sys.resume(pid)
    eventually(fn -> Store.get(name) != nil and Store.pid_registered?(pid) end)
    assert :sys.get_state(pid).id == state.id
  end

  test "R3 F2 supervisor-loss revive scan reconciles dead resavers before DOWN delivery" do
    name = "r3-supervisor-death"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(Fake.model()))

    on_exit(fn ->
      if p = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)

      Store.delete(name)
    end)

    :sys.replace_state(pid, fn s ->
      Map.put(%{s | bindings: [retained: 654]}, :bindings_dirty, true)
    end)

    GenServer.cast(pid, :resave)
    state = :sys.get_state(pid)
    :ok = :sys.suspend(pid)
    :ok = Supervisor.terminate_child(Nano.Supervisor, Store)
    {:ok, store} = Supervisor.restart_child(Nano.Supervisor, Store)
    assert Store.get(name) == nil
    assert Store.durability(name).status == :recovering
    # Block Store callback delivery, not its monitor signals; revival scan must be
    # safe regardless of whether queued DOWN or scan request is handled first.
    :ok = :sys.suspend(store)
    :ok = Supervisor.terminate_child(Nano.Supervisor, Nano.AgentSupervisor)
    {:ok, _} = Supervisor.restart_child(Nano.Supervisor, Nano.AgentSupervisor)
    assert NanoAgent.whereis(name) == nil
    :ok = :sys.resume(store)
    :ok = NanoAgent.revive(Nano.AgentSupervisor)
    recovered = NanoAgent.whereis(name)
    assert is_pid(recovered)
    assert :sys.get_state(recovered).id == state.id
    assert :sys.get_state(recovered).bindings[:retained] == 654
  end

  test "recovery death never reloads tombstoned or corrupt pair", c do
    for mode <- [:deleted, :corrupt] do
      a = agent(c, Atom.to_string(mode))
      state = :sys.get_state(a.pid)
      :ok = :sys.suspend(a.pid)
      :ok = Supervisor.terminate_child(Nano.Supervisor, Store)
      {:ok, _} = Supervisor.restart_child(Nano.Supervisor, Store)
      assert Store.get(a.name) == nil

      if mode == :deleted do
        assert :ok = Store.delete(a.name)
      else
        File.write!(
          Path.join(Application.fetch_env!(:nano, :state_dir), a.name <> ".envelope-v1"),
          "corrupt"
        )
      end

      Process.exit(a.pid, :kill)
      eventually(fn -> not Process.alive?(a.pid) end)
      rows = Store.all()
      refute Enum.any?(rows, &(&1.name == a.name))
      eventually(fn -> NanoAgent.whereis(a.name) == nil end)
      assert Store.binding_status(a.name) == :unavailable

      if mode == :deleted do
        assert {:error, :deleted} = Store.register(a.name, state.id, self())
      else
        assert {:error, :recovery_unavailable} = Store.register(a.name, state.id, self())
      end
    end
  end

  test "named replacement at pre-init scheduling boundary is not mistaken for an established resaver" do
    Fake.start()
    name = "r3-replacement-inventory"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(Fake.model()))

    :sys.replace_state(pid, fn s ->
      Map.put(%{s | bindings: [retained: 987]}, :bindings_dirty, true)
    end)

    GenServer.cast(pid, :resave)
    state = :sys.get_state(pid)
    :ok = DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
    observer = self()

    task =
      Task.async(fn ->
        DynamicSupervisor.start_child(
          Nano.AgentSupervisor,
          {Nano.Flywheel.U05.BarrierAgent, {[name: name, id: state.id], observer}}
        )
      end)

    assert_receive {:name_registered, replacement}, 5000
    assert NanoAgent.whereis(name) == replacement
    :ok = Supervisor.terminate_child(Nano.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(Nano.Supervisor, Store)
    assert Store.get(name) == nil
    send(replacement, :release_init)
    result = Task.await(task, 5000)
    Process.sleep(100)

    IO.puts(
      "R3_REPLACEMENT_INIT_RESULT " <>
        inspect(%{start: result, pid: NanoAgent.whereis(name), ack: Store.durability(name)})
    )

    # Barrier is only scheduling instrumentation. Production NanoAgent.init/1 ran above.
    assert {:ok, recovered} = result
    assert :sys.get_state(recovered).id == state.id
    assert :sys.get_state(recovered).bindings[:retained] == 987
    DynamicSupervisor.terminate_child(Nano.AgentSupervisor, recovered)
    Store.delete(name)
  end
end

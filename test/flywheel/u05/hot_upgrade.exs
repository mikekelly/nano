# Standalone disposable VM only; never run this driver on the harness node.
root = Application.fetch_env!(:nano, :test_dir)

unless String.starts_with?(root, System.fetch_env!("U05_TMP_ROOT") <> "/"),
  do: raise("unsafe root")

paths =
  Map.new(
    [:test_dir, :state_dir, :log_dir, :spill_dir, :image_dir, :web_cache_dir, :safety_dir],
    fn key ->
      path = Application.fetch_env!(:nano, key)

      unless path == root or String.starts_with?(path, root <> "/"),
        do: raise("unsafe mutable path")

      {key, path}
    end
  )

unless Nano.Safety.root() == paths.safety_dir, do: raise("unsafe effective safety root")
endpoint = Application.fetch_env!(:nano, NanoWeb.Endpoint)
unless endpoint[:http][:port] == 0 and endpoint[:server] == false, do: raise("unsafe endpoint")
IO.puts("U05_HOT_UPGRADE_PATH_AUDIT " <> Jason.encode!(paths))
old = System.fetch_env!("U05_OLD_SOURCE_ROOT")
Code.compiler_options(ignore_module_conflict: true)
Code.compile_file(Path.join(old, "pre-u05-state_store.ex"))
Code.compile_file(Path.join(old, "pre-u05-nano_agent.ex"))
{:ok, _} = Application.ensure_all_started(:nano)
:ok = Nano.Settings.put(:openrouter_api_key, "test-key")
ExUnit.start(seed: 17)

defmodule Nano.Flywheel.U05.HotUpgrade do
  use ExUnit.Case
  alias Nano.StateStore, as: Store
  alias Nano.FakeOpenRouter, as: Fake

  defp eventually(fun, n \\ 500) do
    if not fun.() do
      if n == 0, do: flunk("hot upgrade boundary timed out")
      Process.sleep(10)
      eventually(fun, n - 1)
    end
  end

  defp seed(a, value) do
    Fake.push(a.model, calls: [eval: "retained = #{value}"])
    Fake.push(a.model, text: "done")
    send(a.pid, :seed)
    model = a.model
    assert_receive {:openrouter_request, ^model, _}, 5000
    assert_receive {:openrouter_request, ^model, _}, 5000
    eventually(fn -> :sys.get_state(a.pid).status == :idle end)
  end

  test "old running watched-map store and live agents upgrade without restart, including completed eval evidence" do
    Fake.start()

    agents =
      for suffix <- ["a", "b"] do
        name = "u05-hot-" <> suffix
        model = Fake.model()
        Fake.listen(model)
        {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model))
        %{name: name, model: model, pid: pid}
      end

    [a, b] = agents
    seed(a, 21)
    seed(b, 22)
    original_store = Process.whereis(Store)
    # Baseline production failure: old store recreation resaves metadata, not bindings.
    Process.exit(original_store, :kill)

    eventually(fn ->
      is_pid(Process.whereis(Store)) and Process.whereis(Store) != original_store and
        Store.get(a.name) != nil and Store.get(b.name) != nil
    end)

    assert Store.bindings(a.name) == {[], []}
    assert :sys.get_state(a.pid).bindings[:retained] == 21
    store_pid = Process.whereis(Store)
    watched = :sys.get_state(store_pid)
    refute Map.has_key?(watched, :authority)
    ids = Map.new(agents, fn actor -> {actor.name, Store.get(actor.name).id} end)
    test_pid = self() |> :erlang.pid_to_list() |> List.to_string()

    code =
      "send(:erlang.list_to_pid(~c\"#{test_pid}\"), :upgrade_eval_started); completed = receive do :finish -> 731 end"

    Fake.push(b.model, calls: [eval: code])
    Fake.push(b.model, calls: [idle: nil])
    send(b.pid, :work)
    busy_model = b.model
    assert_receive {:openrouter_request, ^busy_model, _}, 5000
    assert_receive :upgrade_eval_started, 5000
    task = :sys.get_state(b.pid).task.task.pid
    send(a.pid, :model_in_flight)
    idle_model = a.model
    assert_receive {:openrouter_request, ^idle_model, _}, 5000
    model_task = :sys.get_state(a.pid).task.task.pid
    for actor <- agents, do: :ok = :sys.suspend(actor.pid, 5000)
    :ok = :sys.suspend(store_pid, 5000)
    Code.compile_file("lib/nano/state_store.ex")
    Code.compile_file("lib/nano_agent.ex")
    :ok = :sys.resume(a.pid)

    assert {:error, {:error, :live_agents_not_quiescent}} =
             :sys.change_code(store_pid, Store, :pre_u05, {:u05_upgrade, 10})

    :ok = :sys.suspend(a.pid, 5000)

    assert {:error, {:error, :model_tasks_not_quiescent}} =
             :sys.change_code(store_pid, Store, :pre_u05, {:u05_upgrade, 10})

    assert :erlang.suspend_process(model_task)
    Fake.push(a.model, status: 503)
    Fake.push(a.model, text: "retried_after_registration")
    refute_receive {:openrouter_request, ^idle_model, _}, 100
    # The old eval completes while callbacks are quiescent; result stays queued.
    send(task, :finish)
    send(a.pid, :queued_during_upgrade)
    send(b.pid, :queued_during_upgrade)
    # Bounded seam rejects without publishing authority or changing process state.
    assert {:error, {:error, :upgrade_bound_exceeded}} =
             :sys.change_code(store_pid, Store, :pre_u05, {:u05_upgrade, 1})

    refute File.exists?(Path.join(Application.fetch_env!(:nano, :state_dir), "lifecycle-v1.term"))

    Application.put_env(:nano, :state_store_fault, fn stage, path ->
      if stage == :after_commit and String.ends_with?(path, "lifecycle-v1.term"),
        do: {:error, :upgrade_ack_unknown},
        else: :ok
    end)

    assert {:error, {:error, :upgrade_ack_unknown}} =
             :sys.change_code(store_pid, Store, :pre_u05, {:u05_upgrade, 10})

    assert :sys.get_state(store_pid) == watched
    authority_path = Path.join(Application.fetch_env!(:nano, :state_dir), "lifecycle-v1.term")
    preserved_authority = File.read!(authority_path)
    Application.delete_env(:nano, :state_store_fault)
    queued = Task.async(fn -> Store.register("u05-queued-caller", "queued-id", self()) end)
    assert :ok = :sys.change_code(store_pid, Store, :pre_u05, {:u05_upgrade, 10})
    assert File.read!(authority_path) == preserved_authority
    assert Process.whereis(Store) == store_pid
    :ok = :sys.resume(store_pid)
    assert {:ok, _} = Task.await(queued, 5000)
    assert Store.binding_status(a.name) == :unavailable
    assert Store.binding_status(b.name) == :unavailable
    for actor <- agents, do: :ok = :sys.resume(actor.pid)

    eventually(fn ->
      :sys.get_state(b.pid).bindings[:completed] == 731 and
        Store.binding_status(a.name) != :unavailable and
        Store.binding_status(b.name) != :unavailable
    end)

    assert :erlang.resume_process(model_task)
    assert_receive {:openrouter_request, ^idle_model, _}, 5000

    for actor <- agents do
      state = :sys.get_state(actor.pid)
      assert state.pid == actor.pid
      assert state.id == ids[actor.name]
      assert state.restart_count == 0
      assert state.store_token.lifecycle_generation == 1

      assert Enum.any?(
               Nano.Log.read(state.id),
               &String.contains?(inspect(&1), "queued_during_upgrade")
             )
    end

    assert Store.bindings(a.name) |> elem(0) |> Keyword.fetch!(:retained) == 21
    assert Store.bindings(b.name) |> elem(0) |> Keyword.fetch!(:completed) == 731
    assert Store.get(b.name).responses >= 3
    generation = Store.recovery_generation()
    Process.exit(store_pid, :kill)

    eventually(fn ->
      Store.availability() == :ok and
        Store.recovery_generation() not in [generation, :unavailable]
    end)

    eventually(fn -> Store.binding_status(b.name) != :unavailable end)
    assert Store.bindings(b.name) |> elem(0) |> Keyword.fetch!(:completed) == 731
    old = b.pid
    Process.exit(old, :kill)
    eventually(fn -> is_pid(NanoAgent.whereis(b.name)) and NanoAgent.whereis(b.name) != old end)
    assert :sys.get_state(NanoAgent.whereis(b.name)).bindings[:completed] == 731
    assert :sys.get_state(NanoAgent.whereis(b.name)).id == ids[b.name]
    for actor <- agents, do: Nano.Ops.stop_agent(actor.name)
    Store.delete("u05-queued-caller")
  end
end

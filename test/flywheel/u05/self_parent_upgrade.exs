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

defmodule R3.Coordinator do
  def convert(parent) do
    store = Process.whereis(Nano.StateStore)
    :ok = :sys.suspend(parent, 5000)
    :ok = :sys.suspend(store, 5000)
    Code.compile_file("lib/nano/state_store.ex")
    Code.compile_file("lib/nano_agent.ex")

    Application.put_env(:nano, :state_store_fault, fn stage, path ->
      if stage == :after_commit and String.ends_with?(path, "lifecycle-v1.term"),
        do: {:error, :ack_unknown},
        else: :ok
    end)

    {:error, {:error, :ack_unknown}} =
      :sys.change_code(store, Nano.StateStore, :pre_u05, {:u05_upgrade, 10}, 15000)

    {:current_function, {:sys, :suspend_loop, _}} = Process.info(parent, :current_function)

    authority =
      File.read!(Path.join(Application.fetch_env!(:nano, :state_dir), "lifecycle-v1.term"))

    Application.delete_env(:nano, :state_store_fault)
    :ok = :sys.change_code(store, Nano.StateStore, :pre_u05, {:u05_upgrade, 10}, 15000)

    ^authority =
      File.read!(Path.join(Application.fetch_env!(:nano, :state_dir), "lifecycle-v1.term"))

    :ok = :sys.resume(store, 5000)
    :ok = :sys.resume(parent, 5000)
    :self_parent_conversion_retried
  end
end

defmodule R3.SelfParentTest do
  use ExUnit.Case
  alias Nano.FakeOpenRouter, as: Fake

  test "actual coordinating eval suspends own parent, retries compatible conversion, resumes before returning" do
    Fake.start()
    model = Fake.model()
    Fake.listen(model)
    {:ok, pid} = NanoAgent.start([name: "r3-self-parent"] ++ Fake.opts(model))
    id = :sys.get_state(pid).id
    store = Process.whereis(Nano.StateStore)
    Fake.push(model, calls: [eval: "retained = 42; R3.Coordinator.convert(me)"])
    Fake.push(model, calls: [idle: nil])
    send(pid, :go)
    assert_receive {:openrouter_request, ^model, _}, 5000
    assert_receive {:openrouter_request, ^model, body}, 5000

    assert Enum.any?(body["messages"], fn m ->
             m["role"] == "tool" and
               String.contains?(inspect(m["content"]), "self_parent_conversion_retried")
           end)

    state = :sys.get_state(pid)
    assert state.pid == pid
    assert state.id == id
    assert Process.whereis(Nano.StateStore) == store
    assert state.bindings[:retained] == 42
    assert Nano.StateStore.registered?(state.store_token)
    assert Nano.StateStore.durability(state.name).status == :durable
    IO.puts("R3_SELF_PARENT_RETRY_RESUME_EVIDENCE_COMMITTED")
  end
end

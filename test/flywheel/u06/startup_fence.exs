# Deterministic source-instrumented scheduling pause in a DISPOSABLE VM only.
# Pause after the real readiness publication, without changing recovery logic/reads.
[mode] = System.argv()
Mix.Task.run("app.config")

paths =
  Map.new(
    [:test_dir, :state_dir, :log_dir, :spill_dir, :image_dir, :web_cache_dir, :safety_dir],
    fn key ->
      path = Application.fetch_env!(:nano, key)
      unless String.starts_with?(path, "/tmp/altair-pull-ef1b6e8d-"), do: raise("unsafe root")
      {key, path}
    end
  )

IO.inspect(paths, label: "STARTUP_FENCE_PATH_AUDIT")
{:ok, _} = Application.ensure_all_started(:nano)
Nano.Settings.put(:openrouter_api_key, "test-key")
Nano.FakeOpenRouter.start()

actors =
  for {suffix, value} <- [{"live", 71}, {"cold", 72}] do
    model = Nano.FakeOpenRouter.model()

    {:ok, pid} =
      NanoAgent.start([name: "u06-fence-" <> suffix] ++ Nano.FakeOpenRouter.opts(model))

    :sys.replace_state(pid, &Map.put(%{&1 | bindings: [retained: value]}, :bindings_dirty, true))
    GenServer.cast(pid, :resave)
    state = :sys.get_state(pid)
    %{status: :durable} = Nano.StateStore.durability(state.name)
    %{pid: pid, name: state.name, id: state.id, value: value, token: state.store_token}
  end

[live, cold] = actors
:ok = DynamicSupervisor.terminate_child(Nano.AgentSupervisor, cold.pid)
false = Process.alive?(cold.pid)
:ok = :sys.suspend(live.pid)
:ok = Supervisor.terminate_child(Nano.Supervisor, Nano.StateStore)

source =
  if mode == "baseline",
    do: "/data/altair-flywheel/runs/pull-ef1b6e8d/runtime/base_state_store.ex",
    else: "lib/nano/state_store.ex"

code = File.read!(source)
anchor = "    :ets.insert(@table, {:availability, if(s.degraded, do: :degraded, else: :ready)})"
1 = length(String.split(code, anchor)) - 1
pid_text = self() |> :erlang.pid_to_list() |> List.to_string()

hook =
  "\n    send(:erlang.list_to_pid(~c\"#{pid_text}\"), {:u06_ready_window, self()})\n    receive do :u06_resume_init -> :ok after 5000 -> raise(\"pause timeout\") end"

Code.compiler_options(ignore_module_conflict: true)
Code.compile_string(String.replace(code, anchor, anchor <> hook), source)
restart = Task.async(fn -> Supervisor.restart_child(Nano.Supervisor, Nano.StateStore) end)

store =
  receive do
    {:u06_ready_window, store} -> store
  after
    5000 -> raise("did not reach deterministic readiness window")
  end

:ok = Nano.StateStore.availability()

if mode == "baseline" do
  %{id: id} = Nano.StateStore.get(live.name)
  true = id == live.id
  {:ok, [retained: 71], []} = Nano.StateStore.binding_status(live.name)
  %{status: :durable} = Nano.StateStore.durability(live.name)

  IO.puts(
    "BASELINE_DEFECT: publicly ready stale live-owner row/bindings before resave continuation"
  )
else
  nil = Nano.StateStore.get(live.name)
  :unavailable = Nano.StateStore.binding_status(live.name)
  %{status: :recovering} = Nano.StateStore.durability(live.name)
  false = Nano.StateStore.registered?(live.token)

  IO.puts(
    "FIXED_FENCE: live-owner metadata/bindings unavailable before readiness returns; old token rejected"
  )
end

# Cold/dead owner still has its coherent pair; startup fencing does not erase it.
%{id: cold_id} = Nano.StateStore.get(cold.name)
true = cold_id == cold.id
{:ok, [retained: 72], []} = Nano.StateStore.binding_status(cold.name)
%{status: :durable} = Nano.StateStore.durability(cold.name)
send(store, :u06_resume_init)
{:ok, ^store} = Task.await(restart, 5000)
:ok = :sys.resume(live.pid)

wait = fn wait, n ->
  if Nano.StateStore.durability(live.name).status != :durable do
    if n == 0, do: raise("live resave timeout")
    Process.sleep(10)
    wait.(wait, n - 1)
  end
end

wait.(wait, 500)
%{id: live_id} = Nano.StateStore.get(live.name)
true = live_id == live.id
{:ok, [retained: 71], []} = Nano.StateStore.binding_status(live.name)

IO.puts(
  "STARTUP_FENCE #{mode} passed: cold coherent recovery retained, live original identity/bindings resaved forward"
)

Application.stop(:nano)

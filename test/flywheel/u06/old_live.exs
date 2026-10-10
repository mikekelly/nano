# Serial disposable VM only. Actual exact dispatch-base callbacks seed the live state.
Mix.Task.run("app.config")

for k <- [:state_dir, :log_dir, :spill_dir, :image_dir, :web_cache_dir, :safety_dir] do
  path = Application.fetch_env!(:nano, k)
  unless String.starts_with?(path, "/tmp/altair-pull-ef1b6e8d-"), do: raise("unsafe mutable path")
  IO.puts("PATH #{k}=#{path}")
end

Code.compiler_options(ignore_module_conflict: true)
Code.compile_file("/data/altair-flywheel/runs/pull-ef1b6e8d/runtime/old_nano_agent.ex")
{:ok, _} = Application.ensure_all_started(:nano)
Nano.Settings.put(:openrouter_api_key, "test-key")
Nano.FakeOpenRouter.start()
model = Nano.FakeOpenRouter.model()
Nano.FakeOpenRouter.listen(model)

{:ok, pid} =
  NanoAgent.start(
    [name: "old-live-text"] ++
      Nano.FakeOpenRouter.opts(model, max_context: 20_000, system_prompt: "brief")
  )

:sys.replace_state(pid, &Map.put(&1, :halted, :compaction_failed))
for n <- 1..40, do: send(pid, {n, String.duplicate("x", 1000)})
old = :sys.get_state(pid)
false = Map.has_key?(old, :image_deliveries)
40 = length(old.pending)
# Seed a second old live process with completed actual tool pairs/bindings, then a
# legacy flat image bundle and a separately oversized old pending text item.
image_model =
  Nano.FakeOpenRouter.model(%{"architecture" => %{"input_modalities" => ["text", "image"]}})

Nano.FakeOpenRouter.listen(image_model)

{:ok, image_pid} =
  NanoAgent.start(
    [name: "old-live-images"] ++
      Nano.FakeOpenRouter.opts(image_model, max_context: 20_000, system_prompt: "brief")
  )

Nano.FakeOpenRouter.push(image_model, calls: [eval: "retained = 731"])
Nano.FakeOpenRouter.push(image_model, text: "done")
send(image_pid, :seed_pair)

for _ <- 1..2 do
  receive do
    {:openrouter_request, ^image_model, _} -> :ok
  after
    5000 -> raise("old tool pair seed failed")
  end
end

wait = fn wait, n ->
  if :sys.get_state(image_pid).status != :idle do
    if n == 0, do: raise("seed idle timeout")
    Process.sleep(10)
    wait.(wait, n - 1)
  end
end

wait.(wait, 500)
:sys.replace_state(image_pid, &Map.put(&1, :halted, :compaction_failed))

gif =
  <<"GIF89a", 1::little-16, 1::little-16, 0, 0, 0, 44, 0::little-16, 0::little-16, 1::little-16,
    1::little-16, 0, 2, 2, 68, 1, 0, 59>>

image_path = Path.join(Application.fetch_env!(:nano, :test_dir), "legacy.gif")
File.write!(image_path, gif)
{:ok, image_ref} = Nano.Images.import_file(image_path)
send(image_pid, %{text: "legacy image", images: [image_ref]})
send(image_pid, String.duplicate("é", 3000))
image_old = :sys.get_state(image_pid)
false = Map.has_key?(image_old, :image_deliveries)
true = image_old.bindings[:retained] == 731

large_model =
  Nano.FakeOpenRouter.model(%{"architecture" => %{"input_modalities" => ["text", "image"]}})

Nano.FakeOpenRouter.listen(large_model)

{:ok, large_pid} =
  NanoAgent.start(
    [name: "old-live-large-bundle"] ++
      Nano.FakeOpenRouter.opts(large_model, max_context: 20_000, system_prompt: "brief")
  )

:sys.replace_state(large_pid, &Map.put(&1, :halted, :compaction_failed))
send(large_pid, %{text: "atomic original image", images: [image_ref]})
for n <- 1..300, do: send(large_pid, {:legacy_bundle, n})
large_old = :sys.get_state(large_pid)
301 = length(large_old.pending)
Code.compile_file("lib/nano_agent.ex")

NanoAgent.unhalt(pid)

receive do
  {:openrouter_request, ^model, _} -> :ok
after
  5000 -> raise("old live queue could not resume")
end

state = :sys.get_state(pid)
true = state.halted == nil
true = state.id == old.id
true = state.pid == pid
true = state.event_seq == old.event_seq
true = length(state.pending) < length(old.pending)
# Old strings were not discarded: the admitted prefix plus tail retains every event ID.
content = Jason.encode!([state.transcript, state.pending])
for n <- 1..40, do: true = String.contains?(content, "seq=\\\"#{n}\\\"")

IO.puts(
  "OLD_LIVE_TEXT passed: same live process/id, ordered original wrappers retained; actual provider boundary reached"
)

NanoAgent.unhalt(image_pid)

image_body =
  receive do
    {:openrouter_request, ^image_model, body} -> body
  after
    5000 -> raise("old live image bundle could not resume")
  end

image_state = :sys.get_state(image_pid)
true = image_state.halted == nil
true = image_state.id == image_old.id
true = image_state.bindings[:retained] == 731
true = image_state.event_seq == image_old.event_seq
false = Map.has_key?(image_state, :image_deliveries)
true = map_size(image_state.admission_evidence) == 1
true = image_state.pending == []
# Production provider expansion has pixels exactly once, and existing tool IDs pair.
parts =
  Enum.flat_map(image_body["messages"], fn m ->
    if is_list(m["content"]), do: m["content"], else: []
  end)

1 = Enum.count(parts, &(&1["type"] == "image_url"))
calls = for m <- image_state.transcript, c <- m["tool_calls"] || [], do: c["id"]
results = for %{"role" => "tool", "tool_call_id" => id} <- image_state.transcript, do: id
true = calls == results
true = calls != []

IO.puts(
  "OLD_LIVE_IMAGES_TOOL_PAIRS passed: same process/id/bindings; atomic refs once, staged old text position0, original tool pairs retained"
)

NanoAgent.unhalt(large_pid)

large_body =
  receive do
    {:openrouter_request, ^large_model, body} -> body
  after
    5000 -> raise("large old image bundle could not resume atomically")
  end

large = :sys.get_state(large_pid)
true = large.halted == nil
true = large.id == large_old.id
true = large.pending == []
[handle] = Map.values(large.admission_evidence)
true = handle.position == 0
exact = File.read!(handle.path)
true = String.starts_with?(exact, Enum.join(large_old.pending, "\n"))
for n <- 1..301, do: true = String.contains?(exact, "<event seq=\"#{n}\"")

parts =
  Enum.flat_map(large_body["messages"], fn m ->
    if is_list(m["content"]), do: m["content"], else: []
  end)

1 = Enum.count(parts, &(&1["type"] == "image_url"))

IO.puts(
  "OLD_LIVE_LARGE_BUNDLE passed:301 original pending IDs/one image atomic, bounded RAM exact handle not read/answered"
)

Application.stop(:nano)

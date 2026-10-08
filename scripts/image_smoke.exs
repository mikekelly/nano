# Explicit opt-in vision acceptance in an isolated MIX_ENV=test VM.
# COMPACTION_SMOKE_DIR has a fresh access-only credential snapshot, mode 0600.
# This never reads /data and refuses token refresh; no shared VM modules are loaded.
root = System.fetch_env!("COMPACTION_SMOKE_DIR") |> Path.expand()
state_dir = Path.join(root, "state")
File.mkdir_p!(state_dir)
File.chmod!(root, 0o700)
File.chmod!(state_dir, 0o700)
source = Path.join(root, "chatgpt_auth.json")
creds = source |> File.read!() |> Jason.decode!()
true = creds["expires_at"] > System.system_time(:second) + 600
true = creds["refresh_token"] == "REFRESH_DISABLED_FOR_ISOLATED_SMOKE"
path = Path.join(state_dir, "chatgpt_auth.json")
File.write!(path, "")
File.chmod!(path, 0o600)
File.write!(path, Jason.encode!(creds))
File.rm!(source)

for {key, suffix} <- [state_dir: "state", log_dir: "logs", spill_dir: "spill"] do
  Application.put_env(:nano, key, Path.join(root, suffix))
end

{:ok, _} = Application.ensure_all_started(:nano)
:ok = Nano.Settings.put(:chatgpt_auth_url, "http://127.0.0.1:1/no-refresh")
:ok = Nano.Settings.put(:model_call_max_ms, 120_000)
Process.register(self(), :vision_smoke_observer)
name = "vision-real-" <> Integer.to_string(System.unique_integer([:positive]))
model = "openai-codex/gpt-6.1-sol"
{:ok, entry} = Nano.Model.lookup(model)
# Provider-listed capabilities must enable this, not a test's state patch.
true = "image" in entry.input_modalities
{:ok, ref} = Seedling.Images.store(Seedling.ImageFixture.png(64, 64))

prompt = """
You are an isolated image acceptance-test agent. Inspect only the actual attached image.
Do not infer color from filenames, dimensions, text, the brief or reference metadata.
Return one eval call that sends your predominant-color answer as a string:
send(Process.whereis(:vision_smoke_observer), {:observed_color, me, "YOUR_COLOR"})
Then call idle. If you cannot see the image, answer "cannot see"; do not guess.
"""

{:ok, pid} =
  NanoAgent.start(
    name: name,
    model: model,
    reasoning: "low",
    max_turns: 4,
    max_tokens: 100_000,
    max_context: 20000,
    system_prompt: prompt,
    start_idle: true
  )

id = NanoAgent.info(name).id
send(pid, %{message: "What is the predominant color in the attached image?", image: ref})

result =
  receive do
    {:observed_color, ^pid, answer} -> {:ok, answer}
  after
    120_000 -> {:error, :deadline}
  end

wait_idle = fn wait_idle, remaining ->
  state = :sys.get_state(pid)

  if state.status == :idle or not is_nil(state.halted) or remaining <= 0 do
    :ok
  else
    Process.sleep(100)
    wait_idle.(wait_idle, remaining - 100)
  end
end

wait_idle.(wait_idle, 10000)
state = :sys.get_state(pid)
responses = Nano.Log.read(id) |> Enum.filter(&(&1["type"] == "model_response"))

evidence = %{
  result: inspect(result),
  same_pid: NanoAgent.whereis(name) == pid,
  agent: name,
  id: id,
  input_modalities: entry.input_modalities,
  immutable_ref: ref,
  inline_bytes_persisted: :erlang.term_to_binary(state) =~ "base64",
  context_used: state.context_used,
  tokens_used: state.tokens_used,
  halted: state.halted,
  responses:
    Enum.map(
      responses,
      &Map.take(&1, ["request_id", "prompt_tokens", "completion_tokens", "cached_tokens"])
    ),
  full_record: Path.join(root, "logs/#{id}.jsonl")
}

File.write!(Path.join(root, "evidence.json"), Jason.encode!(evidence, pretty: true))
IO.puts(Jason.encode!(evidence, pretty: true))
DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
NanoAgent.kill_tasks(pid)
File.rm(path)

case result do
  {:ok, answer} -> if not String.contains?(String.downcase(answer), "red"), do: System.halt(1)
  _ -> System.halt(1)
end

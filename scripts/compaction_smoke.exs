# Explicit opt-in real-provider acceptance smoke, never used by mix test.
# Run with MIX_ENV=test mix run --no-start scripts/compaction_smoke.exs.
# COMPACTION_SMOKE_DIR must be a fresh task-private directory containing an
# access-only chatgpt_auth.json snapshot (mode 0600), without a usable refresh token.
# This script never reads /data or mutates the running node. It refuses refresh by
# pointing auth at an unreachable local endpoint. Do not commit credentials.
root = System.fetch_env!("COMPACTION_SMOKE_DIR") |> Path.expand()
File.mkdir_p!(root)
File.chmod!(root, 0o700)
state_dir = Path.join(root, "state")
File.mkdir_p!(state_dir)
File.chmod!(state_dir, 0o700)
source = Path.join(root, "chatgpt_auth.json")
creds = source |> File.read!() |> Jason.decode!()
true = creds["expires_at"] > System.system_time(:second) + 900
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
:ok = Nano.Settings.put(:model_call_max_ms, 180_000)
Process.register(self(), :compaction_smoke_observer)
name = "compaction-real-" <> Integer.to_string(System.unique_integer([:positive]))

prompt = """
You are a narrowly scoped acceptance-test agent in an isolated VM. Your sole job is to
exercise actual automatic compaction with real model responses. The harness eval tool
is executable Elixir, and `me` is your unchanged agent pid. Follow these steps precisely.

Before any checkpoint: on your first eval bind counter = 0. Then on every subsequent
ordinary model response call eval with this exact code (no idle, no prose):
counter = counter + 1; IO.puts(String.duplicate("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda.\\n", 200)); counter
Keep doing that, one eval per response, until the harness appends its automatic compaction
instruction. The repeated data intentionally fills the conversation; do not optimize or
skip it, and do not voluntarily compact. If counter reaches 30 before a checkpoint, call
send(Process.whereis(:compaction_smoke_observer), {:failed, :no_compaction, counter}) and idle.

When the harness asks for automatic compaction, follow that note exactly: return one eval
call containing only Seedling.Compaction.provide_summary("literal structured checkpoint").
Actually summarize the conversation and this brief, including the bound counter, unchanged
pid/bindings, completed work and the next step below. Do not run any other code in that reply.

AFTER a compaction preamble is present and the automatic note is no longer at the tip:
call eval with send(Process.whereis(:compaction_smoke_observer), {:continued, me, counter})
then call idle. Do not reset counter or produce more padding after a checkpoint.
"""

{:ok, pid} =
  NanoAgent.start(
    name: name,
    model: "openai-codex/gpt-6.1-sol",
    reasoning: "low",
    max_turns: 40,
    max_tokens: 2_000_000,
    max_context: 65536,
    system_prompt: prompt,
    start_idle: true
  )

id = NanoAgent.info(name).id
Nano.Log.subscribe(id)

send(pid, %{
  brief:
    "Exercise automatic checkpoint then report same-pid continuation. Do not voluntarily compact."
})

result =
  receive do
    {:continued, ^pid, counter} when counter > 0 -> {:ok, counter}
    {:failed, reason, counter} -> {:error, {reason, counter}}
  after
    540_000 -> {:error, :deadline}
  end

# Allow the ordinary tool lifecycle to finish; keep cleanup bounded if the model
# does not immediately idle. The explicit continuation message is the acceptance proof.
wait_idle = fn wait_idle, remaining ->
  state = :sys.get_state(pid)

  if state.status == :idle or state.halted or remaining <= 0 do
    :ok
  else
    Process.sleep(100)
    wait_idle.(wait_idle, remaining - 100)
  end
end

wait_idle.(wait_idle, 15000)

state = :sys.get_state(pid)
entries = Nano.Log.read(id)
started = Enum.filter(entries, &(&1["type"] == "compaction_started"))
completed = Enum.filter(entries, &(&1["type"] == "compaction_completed"))
responses = Enum.filter(entries, &(&1["type"] == "model_response"))

evidence = %{
  result: inspect(result),
  same_pid: NanoAgent.whereis(name) == pid,
  agent: name,
  id: id,
  max_context: 65536,
  compaction_started: started,
  compaction_completed: Enum.map(completed, &Map.drop(&1, ["summary"])),
  last_context_used: state.context_used,
  turns_used: state.turns_used,
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
IO.puts(Jason.encode!(Map.drop(evidence, [:responses]), pretty: true))
DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
NanoAgent.kill_tasks(pid)
File.rm(path)

if not match?({:ok, _}, result) or completed == [] or started == [] do
  System.halt(1)
end

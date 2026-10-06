defmodule NanoAgentTest do
  # Not async: tests change node-wide app env (eval timeout, truncation limit, hourly cap).
  use ExUnit.Case, async: false

  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()

    keys = [
      :eval_timeout_ms,
      :result_max_bytes,
      :node_max_tokens_per_hour,
      :openrouter_backoff_ms
    ]

    saved = for k <- keys, do: {k, Application.get_env(:nano, k)}
    Application.put_env(:nano, :openrouter_backoff_ms, 1)
    on_exit(fn -> for {k, v} <- saved, do: Application.put_env(:nano, k, v) end)
    %{model: Fake.model(), name: "t#{System.unique_integer([:positive])}"}
  end

  defp start!(ctx, opts \\ []) do
    Fake.listen(ctx.model)
    {:ok, pid} = NanoAgent.start([name: ctx.name, model: ctx.model] ++ opts)

    on_exit(fn ->
      if pid = NanoAgent.whereis(ctx.name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      Nano.StateStore.delete(ctx.name)
    end)

    id = NanoAgent.info(ctx.name).id
    Nano.Log.subscribe(id)
    {pid, id}
  end

  defp request!(model) do
    assert_receive {:openrouter_request, ^model, body}, 2_000
    body
  end

  # The first logged entry of a type (string keys) matching fun, from the file or once it is broadcast.
  defp await(id, type, fun \\ fn _ -> true end) do
    type = to_string(type)

    case Enum.find(Nano.Log.read(id), &(&1["type"] == type and fun.(&1))) do
      nil ->
        receive do
          {:nano_log, %{agent_id: ^id}} -> await(id, type, fun)
        after
          2_000 -> flunk("no #{type} entry")
        end

      entry ->
        entry
    end
  end

  defp await_nth(id, type, n), do: await(id, type, fn _ -> length(entries(id, type)) >= n end)

  defp entries(id, type), do: for(e <- Nano.Log.read(id), e["type"] == to_string(type), do: e)

  defp text(%{"content" => [%{"text" => text}]}), do: text
  defp text(%{"content" => text}), do: text

  defp tool_texts(body), do: for(%{"role" => "tool"} = m <- body["messages"], do: text(m))

  # Kills the agent and waits for its supervisor to bring it back; returns the new pid.
  defp kill(ctx, id, reason \\ :kill) do
    pid = NanoAgent.whereis(ctx.name)
    count = NanoAgent.info(ctx.name).restart_count
    Process.exit(pid, reason)
    await(id, :agent_started, &(&1["restart_count"] == count + 1))
    new = NanoAgent.whereis(ctx.name)
    assert new != pid
    # init has logged; wait until it has also saved.
    :sys.get_state(new)
    new
  end

  test "an event starts a turn, tool results loop back, and a reply without tool calls ends it",
       ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: "1 + 1"])
    Fake.push(ctx.model, text: "done")
    send(pid, {:hello, self(), "are you there?"})

    body = request!(ctx.model)
    assert body["model"] == ctx.model
    assert body["usage"] == %{"include" => true}

    assert [%{"function" => %{"name" => "eval"}}, %{"function" => %{"name" => "idle"}}] =
             body["tools"]

    assert [system, user] = body["messages"]
    assert [%{"text" => prompt, "cache_control" => %{"type" => "ephemeral"}}] = system["content"]
    assert prompt =~ ~s(You are process #{inspect(pid)}, named "#{ctx.name}")
    assert [%{"text" => event, "cache_control" => %{"type" => "ephemeral"}}] = user["content"]
    me = inspect(self())

    assert event =~
             ~r/^<event seq="1" at="\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ">\{:hello, #{Regex.escape(me)}, "are you there\?"\}<\/event>$/

    body = request!(ctx.model)
    assert [_, _, %{"role" => "assistant", "tool_calls" => [call]}, tool] = body["messages"]
    assert %{"role" => "tool", "tool_call_id" => call_id} = tool
    assert call_id == call["id"]
    assert text(tool) == "2"
    assert await(id, :turn_ended)["reason"] == "no_tool_call"

    :sys.get_state(pid)

    assert %{
             status: :idle,
             halted: nil,
             suspended: false,
             budget: %{turns_used: 2, tokens_used: 220}
           } = NanoAgent.info(ctx.name)

    # The next event is seq 2 and goes on the end of the same transcript.
    Fake.push(ctx.model, text: "bye")
    NanoAgent.notify(ctx.name, :again)
    body = request!(ctx.model)
    assert length(body["messages"]) == 6
    assert text(List.last(body["messages"])) =~ ~s(<event seq="2")
  end

  test "events received while busy are delivered together in the next turn", ctx do
    {pid, id} = start!(ctx)
    send(pid, :first)
    request!(ctx.model)

    send(pid, :second)
    NanoAgent.notify(ctx.name, :third)
    GenServer.cast(pid, :fourth)
    assert await(id, :event_received, &(&1["event_seq"] == 3))["queue_length"] == 2
    :sys.get_state(pid)
    assert NanoAgent.info(ctx.name).status == :thinking

    Fake.push(ctx.model, text: "ok")
    body = request!(ctx.model)
    assert [_system, _first, %{"role" => "assistant"}, last] = body["messages"]
    assert [second, third, fourth] = String.split(text(last), "\n")
    assert second =~ ~r/^<event seq="2" .*>:second<\/event>$/
    assert third =~ ~r/^<event seq="3" .*>:third<\/event>$/
    assert fourth =~ ~r/^<event seq="4" .*>\{:"\$gen_cast", :fourth\}<\/event>$/
  end

  test "a GenServer.call to an agent is relayed as an event, not answered", ctx do
    {pid, _id} = start!(ctx)
    catch_exit(GenServer.call(pid, :status, 50))
    body = request!(ctx.model)
    assert text(List.last(body["messages"])) =~ ~r/\{:"\$gen_call", \{#PID<.*>, .*\}, :status\}/
  end

  test "idle ends the turn with an empty tool result; evals before it run first", ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: "x = 5", idle: nil])
    send(pid, :go)
    request!(ctx.model)
    assert await(id, :turn_ended)["reason"] == "idle"
    refute_receive {:openrouter_request, _, _}, 100

    send(pid, :again)
    body = request!(ctx.model)
    assert tool_texts(body) == ["5", ""]
    assert [_, %{"name" => "idle", "result" => "", "ok" => true}] = entries(id, :tool_result)
  end

  test "idle with wakeup_after wakes the agent with a harness note", ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [idle: 20])
    send(pid, :go)
    request!(ctx.model)
    body = request!(ctx.model)
    note = "<harness>No message arrived within 20 ms, so I am waking you as you asked.</harness>"
    assert text(List.last(body["messages"])) == note
    assert await(id, :harness_note)["text"] =~ "No message arrived within 20 ms"
  end

  test "an event that arrives first cancels the wakeup", ctx do
    {pid, _id} = start!(ctx)
    Fake.push(ctx.model, calls: [idle: 100])
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    send(pid, :poke)
    assert text(List.last(request!(ctx.model)["messages"])) =~ ~s(<event seq="2")
    refute_receive {:openrouter_request, _, _}, 250
  end

  test "start_idle: false begins the first turn with a harness note", ctx do
    start!(ctx, start_idle: false)
    body = request!(ctx.model)
    note = "<harness>Your process has just started. No message has arrived yet.</harness>"
    assert text(List.last(body["messages"])) == note
  end

  test "eval captures IO, keeps bindings between calls, and binds me", ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: ~s|IO.puts("hello"); x = 41|])
    Fake.push(ctx.model, calls: [eval: "{x + 1, me, self() == me}"])
    Fake.push(ctx.model, text: "done")
    send(pid, :go)
    request!(ctx.model)
    assert tool_texts(request!(ctx.model)) == ["41\n\nCaptured IO:\nhello\n"]
    assert List.last(tool_texts(request!(ctx.model))) == "{42, #{inspect(pid)}, false}"
    assert [first, _] = entries(id, :tool_result)
    assert %{"ok" => true, "result" => "41", "io" => "hello\n", "truncated" => false} = first
  end

  test "eval failures and bad tool calls come back as tool results", ctx do
    {pid, id} = start!(ctx)

    calls = [
      {:eval, ~s|raise "boom"|},
      {:eval, "exit(:bye)"},
      {:eval, "throw(:ball)"},
      {:eval, "Process.exit(self(), :kill)"},
      {:eval, "pid(0, 1, 0)"},
      {:nope, %{}},
      {"eval", "{not json"},
      {:idle, "soon"}
    ]

    Fake.push(ctx.model, calls: calls)
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)

    [raised, exited, thrown, killed, compile, unknown, bad_json, bad_idle] =
      tool_texts(request!(ctx.model))

    assert raised =~ "** (RuntimeError) boom"
    assert raised =~ "NanoAgent.run_eval/2"
    assert exited =~ "** (exit) :bye"
    assert thrown =~ "** (throw) :ball"
    assert killed == "{:exit, :killed}"
    assert compile =~ "** (CompileError)"
    assert compile =~ "Captured IO:\nerror: undefined function pid/3"
    assert unknown =~ ~s(Error: cannot call "nope")
    assert bad_json =~ ~s(Error: cannot call "eval" with arguments "{not json")
    assert bad_idle =~ "wakeup_after must be a non-negative integer"
    assert Enum.map(entries(id, :tool_result), & &1["ok"]) == List.duplicate(false, 8)
    assert Process.alive?(pid)
  end

  test "an eval that runs past the timeout is killed and reported", ctx do
    Application.put_env(:nano, :eval_timeout_ms, 50)
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: "Process.sleep(:infinity)"])
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    assert tool_texts(request!(ctx.model)) == ["Timeout: the eval was killed after 50 ms."]
    assert %{"ok" => false, "duration_ms" => ms} = await(id, :tool_result)
    assert ms >= 50
  end

  test "an agent killed mid-eval is restarted with its history, a harness note and a valid transcript",
       ctx do
    {pid, id} = start!(ctx)
    code = "x = 7; Process.exit(me, :kill); Process.sleep(:infinity)"
    Fake.push(ctx.model, calls: [eval: "x = 7"])
    Fake.push(ctx.model, calls: [eval: code, eval: ":never_run"])
    Fake.push(ctx.model, calls: [eval: "{me, x}"])
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    request!(ctx.model)

    body = request!(ctx.model)
    new = NanoAgent.whereis(ctx.name)
    assert new != pid

    assert [_system, _event, _a1, _r1, %{"tool_calls" => [c1, c2]}, r2, r3, note] =
             body["messages"]

    exited = "No result: your process exited before this call completed."
    assert {r2["tool_call_id"], text(r2)} == {c1["id"], exited}
    assert {r3["tool_call_id"], text(r3)} == {c2["id"], exited}

    assert text(note) ==
             "<harness>Your process exited with reason :killed during eval call 2 and was restarted. " <>
               "Your pid is now #{inspect(new)}; your registered name is unchanged.</harness>"

    # Bindings survived and me was rebound.
    assert List.last(tool_texts(request!(ctx.model))) == "{#{inspect(new)}, 7}"

    assert %{
             "restarted" => true,
             "exit_reason" => ":killed",
             "restart_count" => 1,
             "pid" => pid_s
           } =
             await(id, :agent_started, & &1["restarted"])

    assert pid_s == inspect(new)
    assert %{restart_count: 1, halted: nil, pid: ^new} = NanoAgent.info(ctx.name)
    seqs = Enum.map(Nano.Log.read(id), & &1["seq"])
    assert seqs == Enum.to_list(1..length(seqs))
  end

  test "an agent killed while waiting for the model is told so", ctx do
    {pid, id} = start!(ctx)
    send(pid, :go)
    request!(ctx.model)
    kill(ctx, id)
    body = request!(ctx.model)
    assert [_system, _event, note] = body["messages"]
    assert text(note) =~ "exited with reason :killed while waiting for a model response"
  end

  test "three restarts within 60 s bring the agent back halted; it keeps logging until un-halted",
       ctx do
    sup = Process.whereis(Nano.AgentSupervisor)
    {_pid, id} = start!(ctx)

    for n <- 1..2 do
      Fake.push(ctx.model, text: "ok")
      kill(ctx, id)
      request!(ctx.model)
      await_nth(id, :turn_ended, n)
    end

    pid = kill(ctx, id)
    assert %{halted: :restart_brake, restart_count: 3} = NanoAgent.info(ctx.name)
    assert await(id, :agent_started, &(&1["restart_count"] == 3))["halted"] == "restart_brake"

    send(pid, :still_there?)
    assert await(id, :event_received, &(&1["message"] == ":still_there?"))["queue_length"] == 2
    refute_receive {:openrouter_request, _, _}, 100

    NanoAgent.unhalt(ctx.name)
    body = request!(ctx.model)
    assert [unhalt, restart, event] = String.split(text(List.last(body["messages"])), "\n")

    assert unhalt =~
             "<harness>An operator un-halted you. I had stopped calling the model because your process was restarted 3 times"

    assert restart =~ "<harness>Your process exited with reason :killed"
    assert event =~ ":still_there?"
    :sys.get_state(pid)
    assert NanoAgent.info(ctx.name).halted == nil
    assert Process.whereis(Nano.AgentSupervisor) == sup
  end

  test "operator restarts do not count toward the restart brake", ctx do
    {_pid, id} = start!(ctx)

    for n <- 1..3 do
      Fake.push(ctx.model, text: "ok")
      kill(ctx, id, :operator_restart)

      assert text(List.last(request!(ctx.model)["messages"])) =~
               "exited with reason :operator_restart while"

      await_nth(id, :turn_ended, n)
    end

    assert %{halted: nil, restart_count: 3} = NanoAgent.info(ctx.name)
  end

  test "a suspended agent shows as suspended and carries on when resumed", ctx do
    {pid, _id} = start!(ctx)
    :sys.suspend(pid)
    assert NanoAgent.info(ctx.name).suspended
    send(pid, :hello)
    refute_receive {:openrouter_request, _, _}, 100
    :sys.resume(pid)
    request!(ctx.model)
    refute NanoAgent.info(ctx.name).suspended
  end

  test "an eval can suspend its own agent; the result waits until it is resumed", ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: ":sys.suspend(me); :done"])
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    await(id, :tool_call)
    refute_receive {:openrouter_request, _, _}, 100
    assert NanoAgent.info(ctx.name).suspended
    :sys.resume(pid)
    assert tool_texts(request!(ctx.model)) == [":done"]
  end

  test "the turn budget halts the agent; events still log; unhalt resets the counters", ctx do
    {pid, id} = start!(ctx, max_turns: 2)
    Fake.push(ctx.model, calls: [eval: "1"])
    Fake.push(ctx.model, calls: [eval: "2"])
    send(pid, :go)
    request!(ctx.model)
    request!(ctx.model)

    assert %{"scope" => "agent", "turns_used" => 2, "max_turns" => 2, "tokens_used" => 220} =
             await(id, :budget_exhausted)

    assert await(id, :turn_ended, &(&1["reason"] == "budget"))
    refute_receive {:openrouter_request, _, _}, 50
    :sys.get_state(pid)
    assert NanoAgent.info(ctx.name).halted == :budget

    send(pid, :more)
    await(id, :event_received, &(&1["message"] == ":more"))
    refute_receive {:openrouter_request, _, _}, 50

    NanoAgent.unhalt(ctx.name)
    body = request!(ctx.model)
    assert [note, more] = String.split(text(List.last(body["messages"])), "\n")
    assert note =~ "because your budget ran out. Your turn and token counters are now reset."
    assert more =~ ":more"
    :sys.get_state(pid)
    assert %{halted: nil, budget: %{turns_used: 1, tokens_used: 0}} = NanoAgent.info(ctx.name)
  end

  test "the token budget halts the agent", ctx do
    {pid, id} = start!(ctx, max_tokens: 150)
    Fake.push(ctx.model, calls: [eval: "1"])
    Fake.push(ctx.model, calls: [eval: "2"])
    send(pid, :go)
    request!(ctx.model)
    request!(ctx.model)

    assert %{"scope" => "agent", "tokens_used" => 220, "max_tokens" => 150} =
             await(id, :budget_exhausted)

    refute_receive {:openrouter_request, _, _}, 50
  end

  test "the node-wide hourly token cap halts the agent", ctx do
    Application.put_env(
      :nano,
      :node_max_tokens_per_hour,
      Nano.StateStore.node_tokens_last_hour() + 50
    )

    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: "1"])
    send(pid, :go)
    request!(ctx.model)
    assert %{"scope" => "node", "turns_used" => 1} = await(id, :budget_exhausted)
    :sys.get_state(pid)
    assert NanoAgent.info(ctx.name).halted == :budget
  end

  test "transient HTTP errors are retried up to 3 attempts, each failure logged", ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, status: 500)
    Fake.push(ctx.model, status: 429)
    Fake.push(ctx.model, text: "ok")
    send(pid, :one)
    for _ <- 1..3, do: request!(ctx.model)
    assert await(id, :turn_ended)["reason"] == "no_tool_call"

    assert [
             %{"status" => 500, "attempt" => 1, "retry" => true},
             %{"status" => 429, "attempt" => 2, "retry" => true}
           ] =
             entries(id, :model_error)

    for _ <- 1..3, do: Fake.push(ctx.model, status: 503)
    send(pid, :two)
    for _ <- 1..3, do: request!(ctx.model)
    assert await(id, :turn_ended, &(&1["reason"] == "error"))

    assert %{"attempt" => 3, "retry" => false, "request_id" => 2} =
             List.last(entries(id, :model_error))

    Fake.push(ctx.model, status: 400, body: %{"error" => %{"code" => 400, "message" => "bad"}})
    send(pid, :three)
    request!(ctx.model)

    assert %{"status" => 400, "retry" => false, "body" => %{"error" => %{"message" => "bad"}}} =
             await(id, :model_error, &(&1["request_id"] == 3))

    refute_receive {:openrouter_request, _, _}, 50
  end

  test "every log entry type is written with its fields", ctx do
    {pid, id} = start!(ctx, start_idle: false, max_turns: 2)
    Fake.push(ctx.model, status: 502)

    Fake.push(ctx.model,
      calls: [eval: "IO.write(:x); 1"],
      usage: {100, 10, 60},
      cost: 0.5,
      provider: "P"
    )

    Fake.push(ctx.model, calls: [idle: nil])
    await(id, :turn_ended)
    send(pid, :x)
    await(id, :budget_exhausted)

    fields = %{
      "agent_started" => ~w(id name pid model system_prompt restarted),
      "harness_note" => ~w(text),
      "event_received" => ~w(event_seq message queue_length truncated),
      "model_request" => ~w(request_id model message_count approx_input_tokens),
      "model_response" =>
        ~w(request_id latency_ms finish_reason text tool_calls provider prompt_tokens completion_tokens cached_tokens cost),
      "model_error" => ~w(request_id status body attempt retry),
      "tool_call" => ~w(call_id call_seq name arguments started_at),
      "tool_result" => ~w(call_id name duration_ms ok result io truncated),
      "turn_ended" => ~w(reason),
      "budget_exhausted" => ~w(scope turns_used tokens_used max_turns max_tokens)
    }

    log = Nano.Log.read(id)

    assert log |> Enum.map(& &1["type"]) |> Enum.uniq() |> Enum.sort() ==
             fields |> Map.keys() |> Enum.sort()

    for entry <- log do
      for key <- ~w(seq at agent_id agent type) ++ fields[entry["type"]],
          do: assert(Map.has_key?(entry, key), "#{entry["type"]} lacks #{key}")
    end

    assert %{
             "cached_tokens" => 60,
             "cost" => 0.5,
             "provider" => "P",
             "finish_reason" => "tool_calls"
           } =
             hd(entries(id, :model_response))

    assert %{"name" => "eval", "arguments" => %{"code" => "IO.write(:x); 1"}} =
             hd(entries(id, :tool_call))

    assert %{"result" => "1", "io" => "x"} = hd(entries(id, :tool_result))
    assert %{"agent_id" => ^id, "agent" => name} = hd(log)
    assert name == ctx.name
    assert %{cost: cost, cache_hit_rate: 0.5} = NanoAgent.info(ctx.name)
    assert_in_delta cost, 0.501, 1.0e-9
  end

  test "tool results and events are truncated at RESULT_MAX_BYTES", ctx do
    Application.put_env(:nano, :result_max_bytes, 100)
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: ~s|String.duplicate("é", 300)|])
    Fake.push(ctx.model, text: "ok")
    send(pid, String.duplicate("b", 300))
    assert %{"truncated" => true, "message" => message} = await(id, :event_received)
    assert message =~ ~r/^"b+\n\[truncated: \d+ bytes, limit 100\]$/u
    request!(ctx.model)
    [result] = tool_texts(request!(ctx.model))
    assert String.valid?(result)
    assert result =~ ~r/^"é+\n\[truncated: \d+ bytes, limit 100\]$/u
    assert %{"truncated" => true} = await(id, :tool_result)
  end

  test "Nano.Log.read/2 returns the entries after a sequence number", ctx do
    {pid, id} = start!(ctx)
    send(pid, :a)
    request!(ctx.model)
    all = Nano.Log.read(id)
    assert [%{"seq" => 1, "type" => "agent_started"} | _] = all
    assert Nano.Log.read(id, 1) == tl(all)
    assert Nano.Log.read(id, length(all)) == []
  end

  test "start/1 validates its options; info/1 and list/0 read the store", ctx do
    assert NanoAgent.start(name: "bad name", model: ctx.model) == {:error, :invalid_name}
    assert NanoAgent.start(model: ctx.model) == {:error, :invalid_name}

    {pid, _} =
      start!(ctx, max_turns: 7, system_prompt: "{{name}} on {{node}}, {{max_turns}} turns")

    assert {:error, {:already_started, ^pid}} = NanoAgent.start(name: ctx.name, model: ctx.model)
    assert NanoAgent.whereis(ctx.name) == pid
    assert ctx.name in NanoAgent.list()

    assert %{
             id: "t" <> _,
             name: name,
             pid: ^pid,
             model: model,
             status: :idle,
             halted: nil,
             suspended: false,
             system_prompt: prompt,
             restart_count: 0,
             cost: 0,
             cache_hit_rate: nil,
             budget: %{max_turns: 7, max_tokens: 500_000, turns_used: 0, tokens_used: 0}
           } = NanoAgent.info(ctx.name)

    assert {name, model} == {ctx.name, ctx.model}
    assert prompt == "#{ctx.name} on #{node()}, 7 turns"
    assert NanoAgent.info("nobody") == nil
  end

  test "the default system prompt is the spec's template filled from the live environment", ctx do
    {pid, id} = start!(ctx)
    prompt = NanoAgent.info(ctx.name).system_prompt
    refute prompt =~ "{{"
    assert prompt =~ "I am the GenServer you are running in: deterministic code, not a person"
    assert prompt =~ "(OTP #{System.otp_release()}, Elixir #{System.version()})"
    assert prompt =~ "Network access: openrouter-only."
    assert prompt =~ "You have a budget of\n50 turns and 500000 tokens"
    assert prompt =~ inspect(pid)
    assert await(id, :agent_started)["system_prompt"] == prompt
  end

  test "an agent keeps working after NanoAgent is reloaded twice (old code purged)", ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: "y = 1"])
    Fake.push(ctx.model, text: "ok")
    send(pid, :before)
    request!(ctx.model)
    request!(ctx.model)
    await(id, :turn_ended)

    {mod, bin, file} = :code.get_object_code(NanoAgent)
    for _ <- 1..2, do: {:module, NanoAgent} = :code.load_binary(mod, file, bin)

    Fake.push(ctx.model, calls: [eval: "y + 1"])
    send(pid, :after)
    request!(ctx.model)
    assert List.last(tool_texts(request!(ctx.model))) == "2"
    assert NanoAgent.whereis(ctx.name) == pid
  end
end

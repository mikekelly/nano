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
      if pid = NanoAgent.whereis(ctx.name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

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
    # Let the agent finish its current callback (and save), so it dies at rest.
    :sys.get_state(pid)
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

  test "an event that arrives while idle cancels the wakeup; the stale timer is ignored", ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [idle: 100])
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    await(id, :turn_ended, &(&1["reason"] == "idle"))
    send(pid, :poke)
    assert text(List.last(request!(ctx.model)["messages"])) =~ ~s(<event seq="2")
    await(id, :turn_ended, &(&1["reason"] == "no_tool_call"))

    # The wakeup's timer still fires at 100 ms; it must neither wake the agent nor become an event.
    refute_receive {:openrouter_request, _, _}, 250
    assert entries(id, :event_received) |> length() == 2
  end

  test "a stale eval timeout is ignored", ctx do
    Application.put_env(:nano, :eval_timeout_ms, 50)
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: "1"])
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    assert tool_texts(request!(ctx.model)) == ["1"]
    refute_receive {:openrouter_request, _, _}, 150
    assert entries(id, :event_received) |> length() == 1
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
    assert raised =~ "nofile:1: (file)"
    refute raised =~ "NanoAgent.run_eval"
    assert exited =~ "** (exit) :bye"
    assert thrown =~ "** (throw) :ball"
    assert killed == "{:exit, :killed}"

    assert compile =~
             ~r/^\*\* \(CompileError\) cannot compile code\nerror: undefined function pid\/3.* \(line 1\)\n/

    assert unknown =~ ~s(Error: cannot call "nope")
    assert bad_json =~ ~s(Error: cannot call "eval" with arguments "{not json")
    assert bad_idle =~ "wakeup_after must be an integer from 0 to 4294967295"
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
             "<harness>Your process exited with reason :killed during eval (tool call 2) and was restarted. " <>
               "Your pid is now #{inspect(new)}; your registered name is unchanged.</harness>"

    # Bindings survived and me was rebound.
    assert List.last(tool_texts(request!(ctx.model))) == "{#{inspect(new)}, 7}"
    # The system prompt was re-rendered with the new pid.
    assert text(hd(body["messages"])) =~ "You are process #{inspect(new)}"

    assert %{
             "restarted" => true,
             "exit_reason" => ":killed",
             "restart_count" => 1,
             "pid" => pid_s
           } =
             await(id, :agent_started, & &1["restarted"])

    assert pid_s == inspect(new)
    assert await(id, :agent_started, & &1["restarted"])["system_prompt"] =~ inspect(new)
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
    assert await(id, :event_received, &(&1["message"] == ":still_there?"))["queue_length"] == 1
    refute_receive {:openrouter_request, _, _}, 100

    # Halted survives a further restart.
    pid = kill(ctx, id)
    assert NanoAgent.info(ctx.name).halted == :restart_brake
    refute_receive {:openrouter_request, _, _}, 50

    NanoAgent.unhalt(ctx.name)
    body = request!(ctx.model)
    # Notes and events arrive in the order they happened.
    assert [restart3, brake, event, restart4, unhalt] =
             String.split(text(List.last(body["messages"])), "\n")

    assert restart3 =~ "<harness>Your process exited with reason :killed while idle"

    assert brake =~
             "<harness>Your process has restarted 3 times within 60 seconds, so I have halted you"

    assert event =~ ":still_there?"
    assert restart4 =~ "<harness>Your process exited with reason :killed"
    assert unhalt == "<harness>An operator un-halted you.</harness>"
    :sys.get_state(pid)
    assert NanoAgent.info(ctx.name).halted == nil
    assert Process.whereis(Nano.AgentSupervisor) == sup

    # Un-halting reset the restart window: one more restart does not halt.
    Fake.push(ctx.model, text: "ok")
    kill(ctx, id)
    assert NanoAgent.info(ctx.name).halted == nil
  end

  test "restarts older than 60 s do not count toward the brake", ctx do
    {_pid, id} = start!(ctx)

    for n <- 1..2 do
      Fake.push(ctx.model, text: "ok")
      kill(ctx, id)
      request!(ctx.model)
      await_nth(id, :turn_ended, n)
    end

    pid = NanoAgent.whereis(ctx.name)
    :sys.get_state(pid)
    entry = Nano.StateStore.get(ctx.name)
    Nano.StateStore.put(ctx.name, %{entry | restarts: Enum.map(entry.restarts, &(&1 - 61_000))})
    Fake.push(ctx.model, text: "ok")
    kill(ctx, id)
    assert %{halted: nil, restart_count: 3} = NanoAgent.info(ctx.name)
  end

  test "operator restarts count toward the brake and are named in the note", ctx do
    {_pid, id} = start!(ctx)

    for n <- 1..2 do
      Fake.push(ctx.model, text: "ok")
      kill(ctx, id, :operator_restart)

      assert text(List.last(request!(ctx.model)["messages"])) =~
               "exited with reason :operator_restart while"

      await_nth(id, :turn_ended, n)
    end

    kill(ctx, id, :operator_restart)
    assert %{halted: :restart_brake, restart_count: 3} = NanoAgent.info(ctx.name)
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

    assert %{"scope" => "agent", "turns_used" => 2, "tokens_used" => 220} =
             await(id, :budget_exhausted)

    assert await(id, :turn_ended, &(&1["reason"] == "budget"))
    # Halted as soon as the limit was reached; the eval that response asked for still ran.
    assert Enum.map(entries(id, :tool_result), & &1["result"]) == ["1", "2"]
    refute_receive {:openrouter_request, _, _}, 50
    :sys.get_state(pid)
    assert NanoAgent.info(ctx.name).halted == :budget

    send(pid, :more)
    await(id, :event_received, &(&1["message"] == ":more"))
    refute_receive {:openrouter_request, _, _}, 50

    NanoAgent.unhalt(ctx.name)
    body = request!(ctx.model)
    assert [halt, more, unhalt] = String.split(text(List.last(body["messages"])), "\n")
    assert halt =~ "You have used 2 of 2 turns and 220 of 500000 tokens, so I have halted you"
    assert more =~ ":more"

    assert unhalt ==
             "<harness>An operator un-halted you. Your turn and token counters are reset to zero.</harness>"

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

    assert %{"scope" => "agent", "tokens_used" => 220} = await(id, :budget_exhausted)
    refute_receive {:openrouter_request, _, _}, 50
    :sys.get_state(pid)
    assert NanoAgent.info(ctx.name).halted == :budget
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
    assert NanoAgent.info(ctx.name).halted == :node_budget

    # Un-halting does not pretend the agent's own counters were exhausted or reset.
    Application.put_env(:nano, :node_max_tokens_per_hour, 1_000_000_000_000)
    NanoAgent.unhalt(ctx.name)
    body = request!(ctx.model)
    assert [halt, unhalt] = String.split(text(List.last(body["messages"])), "\n")

    assert halt =~
             ~r/This node has used \d+ tokens in the last hour, reaching its cap of \d+, so I have halted you/

    assert unhalt == "<harness>An operator un-halted you.</harness>"
    :sys.get_state(pid)
    assert %{halted: nil, budget: %{turns_used: 2, tokens_used: 110}} = NanoAgent.info(ctx.name)
  end

  test "transient HTTP errors are retried up to 3 attempts, each failure logged", ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, status: 500)
    Fake.push(ctx.model, status: 429)
    Fake.push(ctx.model, text: "ok")
    send(pid, :one)
    for _ <- 1..3, do: request!(ctx.model)
    assert await(id, :turn_ended)["reason"] == "no_tool_call"

    # All written by the agent process, so in seq order with the request and response.
    assert for(e <- Nano.Log.read(id), e["type"] =~ "model_", do: e["type"]) ==
             ~w(model_request model_error model_error model_response)

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
    await(id, :event_received)

    fields = %{
      "agent_started" => ~w(id name pid model system_prompt restarted),
      "harness_note" => ~w(text),
      "event_received" => ~w(event_seq message queue_length truncated),
      "model_request" => ~w(request_id model message_count approx_input_tokens),
      "model_response" =>
        ~w(request_id latency_ms finish_reason text reasoning tool_calls provider prompt_tokens completion_tokens cached_tokens cost),
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

    for bad <- [[max_turns: "1"], [max_tokens: 1.5], [start_idle: "false"], [system_prompt: :x]],
        do:
          assert(
            NanoAgent.start([name: ctx.name, model: ctx.model] ++ bad) ==
              {:error, :invalid_option}
          )

    for {key, error} <- [
          default_model: :missing_model,
          openrouter_api_key: :missing_openrouter_api_key
        ] do
      saved = Application.get_env(:nano, key)
      Application.put_env(:nano, key, nil)
      model = if key == :default_model, do: nil, else: ctx.model
      assert NanoAgent.start(name: ctx.name, model: model) == {:error, error}
      Application.put_env(:nano, key, saved)
    end

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

  defp tasks_of(pid) do
    for t <- Task.Supervisor.children(Nano.EvalSupervisor),
        {:dictionary, d} <- [Process.info(t, :dictionary)],
        {_, [^pid | _]} <- [List.keyfind(d, :"$callers", 0)],
        do: t
  end

  test "a crash while restoring brings the agent back halted instead of looping the supervisor",
       ctx do
    sup = Process.whereis(Nano.AgentSupervisor)
    {bystander, _} = start!(%{ctx | name: ctx.name <> "b", model: Fake.model()})
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, text: "hi")
    send(pid, :before)
    request!(ctx.model)
    await(id, :turn_ended)
    :sys.get_state(pid)

    # A saved entry restore cannot handle (as a broken edit or a bad value would).
    Nano.StateStore.put(ctx.name, Map.delete(Nano.StateStore.get(ctx.name), :restarts))
    Process.exit(pid, :kill)
    started = await(id, :agent_started, &(&1["error"] != nil))
    assert started["error"] =~ "KeyError"
    assert started["halted"] == "restart_brake"
    new = NanoAgent.whereis(ctx.name)
    :sys.get_state(new)
    assert %{halted: :restart_brake} = NanoAgent.info(ctx.name)
    assert Process.whereis(Nano.AgentSupervisor) == sup
    assert Process.alive?(bystander)

    # It still receives and logs, and makes no model calls.
    send(new, :after)
    assert await(id, :event_received, &(&1["message"] == ":after"))["queue_length"] == 1
    refute_receive {:openrouter_request, _, _}, 50

    # Un-halted, it carries on from its saved history.
    NanoAgent.unhalt(ctx.name)
    body = request!(ctx.model)

    assert [_system, _before, %{"role" => "assistant", "content" => "hi"}, last] =
             body["messages"]

    assert text(last) =~
             ~r/^<harness>I failed while starting your process \(\*\* \(KeyError\).*so I have halted you.*<\/harness>\n<event seq="2".*:after<\/event>\n<harness>An operator un-halted you.<\/harness>$/s
  end

  test "a reply with neither content nor tool calls goes back as empty text", ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, [])
    send(pid, :one)
    request!(ctx.model)
    await(id, :turn_ended)
    Fake.push(ctx.model, text: "ok")
    send(pid, :two)
    body = request!(ctx.model)
    assert Enum.at(body["messages"], 2) == %{"role" => "assistant", "content" => ""}
  end

  test "an out-of-range or null wakeup_after does not crash the agent", ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [idle: 10_000_000_000_000_000_000])
    Fake.push(ctx.model, calls: [{:idle, {:raw, ~s({"wakeup_after": null})}}])
    send(pid, :go)
    request!(ctx.model)

    assert tool_texts(request!(ctx.model)) == [
             "Error: wakeup_after must be an integer from 0 to 4294967295 (ms)."
           ]

    assert await(id, :turn_ended)["reason"] == "idle"
    assert %{"ok" => true, "result" => ""} = List.last(entries(id, :tool_result))
    assert NanoAgent.whereis(ctx.name) == pid
    assert NanoAgent.info(ctx.name).restart_count == 0
  end

  test "a long exit reason is shortened in the restart note", ctx do
    {_pid, id} = start!(ctx)
    kill(ctx, id, {:big, String.duplicate("x", 5000)})
    note = text(List.last(request!(ctx.model)["messages"]))
    assert note =~ "Your process exited with reason {:big, \"xxx"
    assert note =~ "…"
    assert byte_size(note) < 700
  end

  test "calls after idle in the same response are not run", ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [idle: nil, eval: "send(me, :should_not_run)"])
    send(pid, :go)
    request!(ctx.model)
    assert await(id, :turn_ended)["reason"] == "idle"
    send(pid, :again)
    body = request!(ctx.model)

    assert tool_texts(body) == [
             "",
             "Not run: an earlier idle call in this response ended your turn."
           ]

    assert length(entries(id, :event_received)) == 2
  end

  test "tool arguments sent as an object instead of a JSON string are accepted", ctx do
    {pid, _id} = start!(ctx)
    Fake.push(ctx.model, calls: [{"eval", {:raw, %{"code" => "1 + 2"}}}])
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    assert tool_texts(request!(ctx.model)) == ["3"]
  end

  test "reasoning is logged and reasoning_details go back in the transcript", ctx do
    {pid, id} = start!(ctx)
    details = [%{"type" => "reasoning.text", "text" => "hmm"}]
    Fake.push(ctx.model, calls: [eval: "1"], reasoning: "thinking", reasoning_details: details)
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    assert %{"reasoning_details" => ^details} = Enum.at(request!(ctx.model)["messages"], 2)
    assert await(id, :model_response)["reasoning"] == "thinking"
  end

  test "tasks of a dead agent are killed when it restarts; kill_tasks/1 kills them on demand",
       ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: "Process.sleep(:infinity)"])
    send(pid, :go)
    request!(ctx.model)
    await(id, :tool_call)
    :sys.get_state(pid)
    [eval_task] = tasks_of(pid)
    new = kill(ctx, id)
    refute Process.alive?(eval_task)

    # The restart note started a model request, parked on the fake.
    request!(ctx.model)
    :sys.get_state(new)
    [model_task] = tasks_of(new)
    :ok = NanoAgent.kill_tasks(new)
    refute Process.alive?(model_task)
    assert await(id, :model_error)["body"] =~ "model request task exited: :killed"
    assert await(id, :turn_ended)["reason"] == "error"
  end

  test "processes an eval spawns are recorded, keep working after it, and survive a restart",
       ctx do
    {pid, id} = start!(ctx)
    code = ~s|spawn(fn -> receive do {:write, to} -> send(to, {:written, IO.write("")}) end end)|
    Fake.push(ctx.model, calls: [eval: code])
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    request!(ctx.model)
    await(id, :turn_ended)
    :sys.get_state(pid)
    assert [child] = Nano.StateStore.get(ctx.name).spawned

    new = kill(ctx, id)
    assert Nano.StateStore.get(ctx.name).spawned == [child]

    # Its group leader no longer points at the eval's closed capture device.
    send(child, {:write, self()})
    assert_receive {:written, :ok}
    ref = Process.monitor(child)
    assert_receive {:DOWN, ^ref, _, _, _}

    # Dead ones are pruned at the next save.
    NanoAgent.unhalt(ctx.name)
    :sys.get_state(new)
    assert Nano.StateStore.get(ctx.name).spawned == []
  end

  test "the log seq carries on from the file if the counter is lost", ctx do
    {pid, id} = start!(ctx)
    send(pid, :a)
    request!(ctx.model)
    :sys.get_state(pid)
    last = List.last(Nano.Log.read(id))["seq"]
    :ets.delete(Nano.StateStore, {:seq, id})
    NanoAgent.notify(ctx.name, :b)
    assert await(id, :event_received, &(&1["message"] == ":b"))["seq"] == last + 1
  end

  test "a refused connection is retried, every attempt logged", ctx do
    saved = Application.get_env(:nano, :openrouter_base_url)
    Application.put_env(:nano, :openrouter_base_url, "http://127.0.0.1:1")
    on_exit(fn -> Application.put_env(:nano, :openrouter_base_url, saved) end)
    {pid, id} = start!(ctx)
    send(pid, :go)
    assert await(id, :turn_ended)["reason"] == "error"

    assert [
             %{"status" => nil, "attempt" => 1, "retry" => true},
             %{"status" => nil, "attempt" => 2, "retry" => true},
             %{"status" => nil, "attempt" => 3, "retry" => false}
           ] = entries(id, :model_error)
  end

  test "reloading NanoAgent twice during an eval surfaces as an eval error", ctx do
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: "Process.sleep(1_000); :done"])
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    await(id, :tool_call)
    :sys.get_state(pid)
    {mod, bin, file} = :code.get_object_code(NanoAgent)
    for _ <- 1..2, do: {:module, NanoAgent} = :code.load_binary(mod, file, bin)
    assert tool_texts(request!(ctx.model)) == ["{:exit, :killed}"]
    assert NanoAgent.whereis(ctx.name) == pid
  end

  test "an agent whose log cannot be written still starts and works", ctx do
    saved = Application.get_env(:nano, :log_dir)
    Application.put_env(:nano, :log_dir, "/dev/null/logs")
    on_exit(fn -> Application.put_env(:nano, :log_dir, saved) end)
    Fake.listen(ctx.model)

    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, pid} = NanoAgent.start(name: ctx.name, model: ctx.model)

      on_exit(fn ->
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        Nano.StateStore.delete(ctx.name)
      end)

      send(pid, :hi)
      request!(ctx.model)
      assert %{status: :thinking, restart_count: 0} = NanoAgent.info(ctx.name)
    end)
  end

  test "eval errors read as IEx shows them: blamed, pruned, diagnostics first", ctx do
    {pid, _id} = start!(ctx)
    module = "EvalErrors#{System.unique_integer([:positive])}"

    code = """
    defmodule #{module} do
      def f(x) when is_integer(x), do: raise("in f")
    end
    #{module}.f(1)
    """

    Fake.push(ctx.model,
      calls: [eval: "y = 1\nsender_pid", eval: code, eval: "String.split(1, 2)"]
    )

    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    [compile, raised, clause] = tool_texts(request!(ctx.model))

    assert compile ==
             "** (CompileError) cannot compile code\nerror: undefined variable \"sender_pid\" (line 2)\n"

    assert raised =~ ~r/^\*\* \(RuntimeError\) in f\n.*#{module}\.f\/1/s
    assert raised =~ "nofile:4: (file)"

    for internal <-
          ~w(NanoAgent Task.Supervised elixir_expand erl_eval Code.validated_eval_string),
        text <- [compile, raised, clause],
        do: refute(text =~ internal, "#{internal} frame in:\n#{text}")

    assert clause =~ "** (FunctionClauseError) no function clause matching in String.split/3"
    assert clause =~ "The following arguments were given to String.split/3"
  end
end

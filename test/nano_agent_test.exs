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

  # A delivered user message without its closing budget line, checking there is exactly one.
  defp delivery(message) do
    {lines, [budget]} = message |> text() |> String.split("\n") |> Enum.split(-1)

    part = fn unit -> "\\d+ (of \\d+ )?#{unit}( \\(no limit\\))?" end

    assert budget =~
             Regex.compile!(
               "^<harness>Used so far: #{part.("turns")}, #{part.("tokens")}, " <>
                 "context #{part.("tokens")}\\.</harness>$"
             )

    refute Enum.any?(lines, &(&1 =~ "Used so far"))
    Enum.join(lines, "\n")
  end

  defp budget_line(message), do: message |> text() |> String.split("\n") |> List.last()

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

    assert [%{"text" => event}] = user["content"]

    assert delivery(%{"content" => event}) =~
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
    assert delivery(List.last(body["messages"])) =~ ~s(<event seq="2")
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
    assert [second, third, fourth] = String.split(delivery(last), "\n")
    assert second =~ ~r/^<event seq="2" .*>:second<\/event>$/
    assert third =~ ~r/^<event seq="3" .*>:third<\/event>$/
    assert fourth =~ ~r/^<event seq="4" .*>\{:"\$gen_cast", :fourth\}<\/event>$/
  end

  test "a GenServer.call to an agent is relayed as an event, not answered", ctx do
    {pid, _id} = start!(ctx)
    catch_exit(GenServer.call(pid, :status, 50))
    body = request!(ctx.model)

    assert delivery(List.last(body["messages"])) =~
             ~r/\{:"\$gen_call", \{#PID<.*>, .*\}, :status\}/
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
    assert delivery(List.last(body["messages"])) == note
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
    assert delivery(List.last(request!(ctx.model)["messages"])) =~ ~s(<event seq="2")
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
    assert delivery(List.last(body["messages"])) == note
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

    assert delivery(note) ==
             "<harness>Your process exited with reason :killed during or just after eval (tool call 2) and was restarted. " <>
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

    # The stub results the model was given are logged like any other.
    assert [%{"call_id" => id1, "ok" => false, "result" => ^exited}, %{"call_id" => id2}] =
             entries(id, :tool_result) |> Enum.filter(&(&1["result"] == exited))

    assert {id1, id2} == {c1["id"], c2["id"]}
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
    assert delivery(note) =~ "exited with reason :killed while waiting for a model response"
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
             String.split(delivery(List.last(body["messages"])), "\n")

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

      assert delivery(List.last(request!(ctx.model)["messages"])) =~
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
    assert [halt, more, unhalt] = String.split(delivery(List.last(body["messages"])), "\n")
    max = Application.get_env(:nano, :agent_max_tokens)
    assert halt =~ "You have used 2 of 2 turns and 220 of #{max} tokens, so I have halted you"
    assert more =~ ":more"

    assert unhalt ==
             "<harness>An operator un-halted you. Your turn and token counters are reset to zero.</harness>"

    # The budget line shows the counters as reset.
    ctx_max = Application.get_env(:nano, :agent_max_context)

    assert budget_line(List.last(body["messages"])) ==
             "<harness>Used so far: 0 of 2 turns, 0 of #{max} tokens, context 110 of #{ctx_max} tokens.</harness>"

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

    cap = Application.get_env(:nano, :node_max_tokens_per_hour)

    assert %{"scope" => "node", "turns_used" => 1, "node_max_tokens_per_hour" => ^cap} =
             entry = await(id, :budget_exhausted)

    assert entry["node_tokens_last_hour"] >= cap
    :sys.get_state(pid)
    assert NanoAgent.info(ctx.name).halted == :node_budget

    # Un-halting does not pretend the agent's own counters were exhausted or reset.
    Application.put_env(:nano, :node_max_tokens_per_hour, 1_000_000_000_000)
    NanoAgent.unhalt(ctx.name)
    body = request!(ctx.model)
    assert [halt, unhalt] = String.split(delivery(List.last(body["messages"])), "\n")

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
    assert message =~ ~r/^"b+\n\[truncated at 100 bytes\]$/u
    request!(ctx.model)
    [result] = tool_texts(request!(ctx.model))
    assert String.valid?(result)
    assert result =~ ~r/^"é+\n\[truncated at 100 bytes\]$/u
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

    for bad <- [
          [max_turns: "1"],
          [max_turns: -1],
          [max_tokens: -1],
          [max_context: -1],
          [max_context: "1"],
          [max_tokens: 1.5],
          [start_idle: "false"],
          [system_prompt: :x],
          [reasoning: "on"],
          [reasoning: true],
          [reasoning: false]
        ],
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
             reasoning: "off",
             budget: %{max_turns: 7, max_tokens: max_tokens, turns_used: 0, tokens_used: 0}
           } = NanoAgent.info(ctx.name)

    assert {name, model, max_tokens} ==
             {ctx.name, ctx.model, Application.get_env(:nano, :agent_max_tokens)}

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
    max = Application.get_env(:nano, :agent_max_tokens)
    ctx_max = Application.get_env(:nano, :agent_max_context)

    assert prompt =~
             "Your limits: 50\nturns, #{max} tokens in total, and a context of #{ctx_max}\ntokens."

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
    note = delivery(List.last(request!(ctx.model)["messages"]))
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

  ## Start failures (items 1 and 5 of fix round 2)

  test "a failed first start returns an error instead of a halted agent", ctx do
    saved = Application.get_env(:nano, :network_policy)
    Application.delete_env(:nano, :network_policy)
    on_exit(fn -> Application.put_env(:nano, :network_policy, saved) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert NanoAgent.start(name: ctx.name, model: ctx.model) == {:error, :start_failed}
      end)

    assert log =~ "network_policy"

    assert NanoAgent.whereis(ctx.name) == nil
    assert NanoAgent.info(ctx.name) == nil
  end

  test "a failed restore comes up as a :start_failed stand-in; un-halting retries the real restore",
       ctx do
    sup = Process.whereis(Nano.AgentSupervisor)
    {bystander, _} = start!(%{ctx | name: ctx.name <> "b", model: Fake.model()})
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: "Process.sleep(:infinity)"])
    send(pid, :go)
    request!(ctx.model)
    await(id, :tool_call)
    :sys.get_state(pid)
    good = Nano.StateStore.get(ctx.name)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # An entry restore cannot handle, as a broken edit or a bad value would.
        Nano.StateStore.put(ctx.name, %{good | transcript: :garbage})
        Process.exit(pid, :kill)

        assert await(id, :agent_started, &(&1["halted"] == "start_failed"))["error"] =~
                 "Enumerable"

        stand_in = NanoAgent.whereis(ctx.name)
        :sys.get_state(stand_in)
        assert %{halted: :start_failed, restart_count: 0} = NanoAgent.info(ctx.name)
        assert Process.whereis(Nano.AgentSupervisor) == sup
        assert Process.alive?(bystander)

        # It queues and logs events and makes no model calls.
        send(stand_in, :while_down)
        assert await(id, :event_received, &(&1["message"] == ":while_down"))["queue_length"] == 1
        refute_receive {:openrouter_request, _, _}, 50

        # Un-halting while restore still fails: a fresh stand-in, still halted.
        NanoAgent.unhalt(ctx.name)

        stand_ins = fn ->
          Enum.count(entries(id, :agent_started), &(&1["halted"] == "start_failed"))
        end

        await(id, :agent_started, fn _ -> stand_ins.() >= 2 end)
        :sys.get_state(NanoAgent.whereis(ctx.name))
        assert %{halted: :start_failed, restart_count: 0} = NanoAgent.info(ctx.name)

        # Fixed, then un-halted: the real restore runs.
        # A stand-in saves its own copy of the entry, so the fix goes into its state (as a
        # code reload would fix the code rather than the entry).
        :sys.replace_state(NanoAgent.whereis(ctx.name), &%{&1 | transcript: good.transcript})
        NanoAgent.unhalt(ctx.name)
        body = request!(ctx.model)
        new = NanoAgent.whereis(ctx.name)
        assert text(hd(body["messages"])) =~ "You are process #{inspect(new)}"
        assert [_, _, %{"tool_calls" => [call]}, tool, last] = body["messages"]

        assert {tool["tool_call_id"], text(tool)} ==
                 {call["id"], "No result: your process exited before this call completed."}

        # The exit it reports is the agent's own, not the stand-ins'.
        assert delivery(last) =~
                 ~r/<event seq="2".*:while_down<\/event>\n<harness>Your process exited with reason :killed during or just after eval \(tool call 1\) and was restarted. Your pid is now #{Regex.escape(inspect(new))};/s

        :sys.get_state(new)
        assert %{halted: nil, restart_count: 1} = NanoAgent.info(ctx.name)
      end)

    assert log =~ "start failed"
  end

  test "if even the fallback fails, the agent is dropped and the supervisor survives", ctx do
    sup = Process.whereis(Nano.AgentSupervisor)
    {bystander, _} = start!(%{ctx | name: ctx.name <> "b", model: Fake.model()})
    {pid, _id} = start!(ctx)
    :sys.get_state(pid)
    # save/1 cannot handle this, in restore and in the :start_failed fallback alike.
    Nano.StateStore.put(ctx.name, %{Nano.StateStore.get(ctx.name) | spawned: :bad})
    ref = Process.monitor(sup)

    ExUnit.CaptureLog.capture_log(fn ->
      Process.exit(pid, :kill)
      refute_receive {:DOWN, ^ref, _, _, _}, 200
    end)

    assert NanoAgent.whereis(ctx.name) == nil
    assert DynamicSupervisor.which_children(sup) |> Enum.all?(fn {_, p, _, _} -> p != pid end)
    assert Process.alive?(bystander)
  end

  ## The log as the durable record (item 2)

  test "no model call is made when its log entry cannot be written; the agent halts :log_failed",
       ctx do
    {pid, id} = start!(ctx)
    path = Path.join(Application.get_env(:nano, :log_dir), id <> ".jsonl")
    File.rm!(path)
    File.mkdir_p!(path)

    ExUnit.CaptureLog.capture_log(fn ->
      send(pid, :hello)
      # Entries are still broadcast, flagged.
      assert_receive {:nano_log, %{type: :event_received, log_error: _}}, 1_000
      assert_receive {:nano_log, %{type: :model_request, log_error: _}}, 1_000
      refute_receive {:openrouter_request, _, _}, 100
      :sys.get_state(pid)
      assert NanoAgent.info(ctx.name).halted == :log_failed
    end)

    File.rmdir!(path)
    Fake.push(ctx.model, text: "ok")
    NanoAgent.unhalt(ctx.name)
    body = request!(ctx.model)

    assert delivery(List.last(body["messages"])) =~
             ~r/<harness>I could not write the harness log, the durable record of what you do, so I have halted you.*<\/harness>\n<harness>An operator un-halted you.<\/harness>$/s
  end

  test "no tool runs when its log entry cannot be written", ctx do
    {pid, id} = start!(ctx)
    send(pid, :go)
    request!(ctx.model)
    path = Path.join(Application.get_env(:nano, :log_dir), id <> ".jsonl")
    File.rm!(path)
    File.mkdir_p!(path)
    marker = Path.join(System.tmp_dir!(), "nano-should-not-exist-#{id}")

    ExUnit.CaptureLog.capture_log(fn ->
      Fake.push(ctx.model, calls: [eval: ~s|File.write!(#{inspect(marker)}, "x")|, eval: "1"])
      assert_receive {:nano_log, %{type: :turn_ended, reason: "error"}}, 1_000
    end)

    refute File.exists?(marker)
    refute_receive {:openrouter_request, _, _}, 50
    assert %{halted: :log_failed} = NanoAgent.info(ctx.name)

    assert Nano.StateStore.get(ctx.name).transcript
           |> Enum.filter(&(&1["role"] == "tool"))
           |> Enum.map(& &1["content"]) ==
             List.duplicate("Not run: the harness log could not be written.", 2)

    File.rmdir!(path)
  end

  ## Eval error formatting (item 6)

  test "eval errors keep the model's frames and name the file of a compile error", ctx do
    {pid, _id} = start!(ctx)
    n = System.unique_integer([:positive])
    file = Path.join(System.tmp_dir!(), "nano_bad_#{n}.exs")
    File.write!(file, "x = 1\nIO.puts(y)\n")
    on_exit(fn -> File.rm(file) end)

    nested = """
    defmodule Outer#{n} do
      def wrap(code), do: code |> Code.eval_string() |> elem(0)
    end
    Outer#{n}.wrap("raise \\"inner\\"")
    """

    compiled =
      ~s|Code.compile_string("defmodule Nested#{n} do\\n def f, do: undefined_thing\\nend")|

    Fake.push(ctx.model,
      calls: [
        eval: nested,
        eval: "Code.compile_file(#{inspect(file)})",
        eval: "1 +",
        eval: compiled
      ]
    )

    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    [nested, from_file, syntax, compiled] = tool_texts(request!(ctx.model))

    # (i) a model function that calls Code.eval_string keeps its frame
    assert nested =~ "** (RuntimeError) inner"
    assert nested =~ "Outer#{n}.wrap/1"

    # (ii) a compile error in a file names the file
    assert from_file =~ "** (CompileError) #{file}"
    assert from_file =~ ~s|error: undefined variable "y" (#{Path.relative_to_cwd(file)}:2)|

    # (iii) syntax errors show no harness frames
    assert syntax =~ "** (TokenMissingError)"
    refute syntax =~ "Code."

    # (iv) nested compilation shows no compiler internals
    assert compiled =~ "** (CompileError)"
    assert compiled =~ ~s|error: undefined variable "undefined_thing" (line 2)|

    for text <- [nested, from_file, syntax, compiled],
        internal <-
          ~w(NanoAgent Task.Supervised elixir_expand elixir_module elixir_compiler erl_eval),
        do: refute(text =~ internal, "#{internal} in:\n#{text}")
  end

  ## Evals that do not return (item 7)

  test "a timed-out eval reports what it printed and the processes it started", ctx do
    Application.put_env(:nano, :eval_timeout_ms, 100)
    {pid, id} = start!(ctx)

    code =
      ~s|spawn(fn -> receive do {:w, to} -> send(to, {:w, IO.write("")}) end end); IO.puts("partial"); Process.sleep(:infinity)|

    Fake.push(ctx.model, calls: [eval: code])
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)

    assert tool_texts(request!(ctx.model)) == [
             "Timeout: the eval was killed after 100 ms.\n\nCaptured IO:\npartial\n"
           ]

    assert %{"io" => "partial\n"} = await(id, :tool_result)
    :sys.get_state(pid)
    assert [child] = Nano.StateStore.get(ctx.name).spawned
    send(child, {:w, self()})
    assert_receive {:w, :ok}
  end

  ## Mutation gaps (item 10)

  test "a failed request that uses the last turn halts the agent", ctx do
    {pid, id} = start!(ctx, max_turns: 1)
    Fake.push(ctx.model, status: 400)
    send(pid, :go)
    request!(ctx.model)
    assert await(id, :turn_ended)["reason"] == "error"
    assert %{"scope" => "agent", "turns_used" => 1} = await(id, :budget_exhausted)
    :sys.get_state(pid)
    assert NanoAgent.info(ctx.name).halted == :budget
  end

  test "processes started by an eval that raises are tracked", ctx do
    {pid, id} = start!(ctx)

    Fake.push(ctx.model,
      calls: [eval: ~s|spawn(fn -> Process.sleep(:infinity) end); raise "after spawning"|]
    )

    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    request!(ctx.model)
    await(id, :turn_ended)
    :sys.get_state(pid)
    assert [child] = Nano.StateStore.get(ctx.name).spawned
    Process.exit(child, :kill)
  end

  test "a model response is saved before its tool calls are handled", ctx do
    {pid, _id} = start!(ctx)
    send(pid, :go)
    request!(ctx.model)
    # Watch the agent's saves while it handles the response.
    :erlang.trace_pattern({Nano.StateStore, :put, 2}, true, [:global])
    :erlang.trace(pid, true, [:call])

    on_exit(fn -> :erlang.trace_pattern({Nano.StateStore, :put, 2}, false, [:global]) end)

    Fake.push(ctx.model, calls: [idle: nil])
    await(NanoAgent.info(ctx.name).id, :turn_ended)
    :erlang.trace(pid, false, [:call])

    saves = for {:trace, ^pid, :call, {_, :put, [_, state]}} <- flush(), do: state
    # One save has the response appended and accounted, before its idle call was handled.
    assert Enum.any?(saves, &match?(%{status: :running_tool, calls: [_], tokens_used: 110}, &1))
  end

  defp flush do
    receive do
      msg -> [msg | flush()]
    after
      0 -> []
    end
  end

  ## Reasoning level

  test "the reasoning level is sent on every request and survives a restart", ctx do
    assert NanoAgent.reasoning_levels() == ~w(off minimal low medium high xhigh max)

    for {opts, sent} <- [
          {[reasoning: "off"], %{"enabled" => false}},
          {[reasoning: "high"], %{"effort" => "high"}},
          {[], %{"enabled" => false}}
        ] do
      level = opts[:reasoning] || "off"
      ctx = %{ctx | name: "#{ctx.name}r#{level}#{length(opts)}", model: Fake.model()}
      {pid, id} = start!(ctx, opts)
      send(pid, :go)
      assert request!(ctx.model)["reasoning"] == sent
      assert NanoAgent.info(ctx.name).reasoning == level
      assert await(id, :agent_started)["reasoning"] == level

      if level == "high" do
        kill(ctx, id)
        assert request!(ctx.model)["reasoning"] == %{"effort" => "high"}
      end
    end
  end

  test "an invalid REASONING default is rejected when an agent is started with it", ctx do
    saved = Application.get_env(:nano, :reasoning)
    Application.put_env(:nano, :reasoning, "loud")
    on_exit(fn -> Application.put_env(:nano, :reasoning, saved) end)
    assert NanoAgent.start(name: ctx.name, model: ctx.model) == {:error, :invalid_option}
    Application.put_env(:nano, :reasoning, "low")
    {pid, _id} = start!(ctx)
    send(pid, :go)
    assert request!(ctx.model)["reasoning"] == %{"effort" => "low"}
  end

  test "eval errors from matches, module bodies and arithmetic show only the model's frames",
       ctx do
    {pid, _id} = start!(ctx)
    module = "BadBody#{System.unique_integer([:positive])}"

    Fake.push(ctx.model,
      calls: [
        eval: "{:a} = {:b}",
        eval: "defmodule #{module} do\n  raise \"in body\"\nend",
        eval: "x = 0\n1 / x"
      ]
    )

    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    [match, body, arith] = tool_texts(request!(ctx.model))

    assert match ==
             "** (MatchError) no match of right hand side value:\n\n    {:b}\n\n    nofile:1: (file)\n"

    assert body == "** (RuntimeError) in body\n    nofile:1: (file)\n"

    assert arith ==
             "** (ArithmeticError) bad argument in arithmetic expression: 1 / 0\n    :erlang./(1, 0)\n    nofile:2: (file)\n"
  end

  test "a killed state store comes back, and live agents save their entries again", ctx do
    {pid, _id} = start!(ctx)
    store = Process.whereis(Nano.StateStore)
    ref = Process.monitor(store)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    wait_until(fn -> NanoAgent.info(ctx.name) != nil end)
    assert Process.whereis(Nano.StateStore) != store
    assert %{pid: ^pid, halted: nil} = NanoAgent.info(ctx.name)

    # It watches the agent again: a kill after the store restart is restored, not started fresh.
    Fake.push(ctx.model, text: "ok")
    kill(ctx, NanoAgent.info(ctx.name).id)

    assert delivery(List.last(request!(ctx.model)["messages"])) =~
             "Your process exited with reason :killed"
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  ## Fix round 3 addendum (R1-R4)

  test "a restart that fails with no saved entry drops the agent instead of looping", ctx do
    sup = Process.whereis(Nano.AgentSupervisor)
    {bystander, _} = start!(%{ctx | name: ctx.name <> "b", model: Fake.model()})
    {pid, _id} = start!(ctx)
    :sys.get_state(pid)
    # As after a state store restart, before the agent saved again; and fresh/1 now fails.
    Nano.StateStore.delete(ctx.name)
    saved = Application.get_env(:nano, :network_policy)
    Application.delete_env(:nano, :network_policy)
    on_exit(fn -> Application.put_env(:nano, :network_policy, saved) end)
    ref = Process.monitor(sup)

    ExUnit.CaptureLog.capture_log(fn ->
      Process.exit(pid, :kill)
      refute_receive {:DOWN, ^ref, _, _, _}, 200
    end)

    assert NanoAgent.whereis(ctx.name) == nil
    assert Process.alive?(bystander)
  end

  test "processes from an eval in flight when the agent died are adopted on restart", ctx do
    {pid, id} = start!(ctx)

    Process.register(self(), :nano_adopt_test)

    code =
      ~s|spawn(fn -> receive do {:w, to} -> send(to, {:w, IO.write("")}) end end); | <>
        ~s|send(:nano_adopt_test, :spawned); Process.sleep(:infinity)|

    Fake.push(ctx.model, calls: [eval: code])
    send(pid, :go)
    request!(ctx.model)
    assert_receive :spawned, 2_000
    kill(ctx, id)
    assert [child] = Nano.StateStore.get(ctx.name).spawned
    send(child, {:w, self()})
    assert_receive {:w, :ok}
  end

  test "an eval that closes its own capture device does not crash the agent", ctx do
    {pid, _id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: "StringIO.close(Process.group_leader())"])
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)
    request!(ctx.model)
    assert tool_texts(request!(ctx.model)) == [~s|{:ok, {"", ""}}|]
    assert NanoAgent.whereis(ctx.name) == pid
    assert NanoAgent.info(ctx.name).restart_count == 0
  end

  test "a stand-in kills the dead process's tasks and keeps an earlier halt", ctx do
    {pid, id} = start!(ctx, max_turns: 1)
    Fake.push(ctx.model, calls: [eval: "Process.sleep(:infinity)"])
    send(pid, :go)
    request!(ctx.model)
    await(id, :tool_call)
    :sys.get_state(pid)
    assert NanoAgent.info(ctx.name).halted == :budget
    [eval_task] = tasks_of(pid)
    # restore fails before it would kill the task itself.
    Nano.StateStore.put(ctx.name, Map.delete(Nano.StateStore.get(ctx.name), :name))

    ExUnit.CaptureLog.capture_log(fn ->
      Process.exit(pid, :kill)
      await(id, :agent_started, &(&1["halted"] == "start_failed"))
    end)

    refute Process.alive?(eval_task)
    :sys.get_state(NanoAgent.whereis(ctx.name))
    assert NanoAgent.info(ctx.name).halted == :start_failed

    # Un-halting retries the restore (the stand-in filled in :name), which brings back the
    # budget halt rather than clearing it.
    NanoAgent.unhalt(ctx.name)
    await(id, :agent_started, &Map.has_key?(&1, "exit_reason"))
    :sys.get_state(NanoAgent.whereis(ctx.name))
    assert %{halted: :budget, restart_count: 1} = NanoAgent.info(ctx.name)
    refute_receive {:openrouter_request, _, _}, 100
  end

  ## Budget line on each delivery

  test "each delivery ends with one line of budget used so far; tool results never carry it",
       ctx do
    max = Application.get_env(:nano, :agent_max_tokens)
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: "1"])
    Fake.push(ctx.model, text: "done")
    send(pid, :first)
    body = request!(ctx.model)

    # Counts before the call the delivery starts.
    ctx_max = Application.get_env(:nano, :agent_max_context)

    line =
      "<harness>Used so far: 0 of 50 turns, 0 of #{max} tokens, context 0 of #{ctx_max} tokens.</harness>"

    assert budget_line(List.last(body["messages"])) == line
    assert delivery(List.last(body["messages"])) =~ ":first"
    assert %{"budget_note" => ^line} = await(id, :model_request)

    # A mid-turn call carries only the tool result and has no line.
    body = request!(ctx.model)
    assert tool_texts(body) == ["1"]
    refute Enum.any?(body["messages"], &(&1["role"] == "tool" and text(&1) =~ "Budget"))
    refute Map.has_key?(await(id, :model_request, &(&1["request_id"] == 2)), "budget_note")
    await(id, :turn_ended)

    # A batched delivery has one line, after all its events.
    Fake.push(ctx.model, text: "ok")
    send(pid, :second)
    request!(ctx.model)
    send(pid, :third)
    send(pid, :fourth)
    body = request!(ctx.model)
    last = List.last(body["messages"])
    assert [_, _] = String.split(delivery(last), "\n")

    assert budget_line(last) ==
             "<harness>Used so far: 3 of 50 turns, 330 of #{max} tokens, context 110 of #{ctx_max} tokens.</harness>"
  end

  test "a delivery of harness notes alone also ends with the budget line", ctx do
    {pid, _id} = start!(ctx)
    Fake.push(ctx.model, calls: [idle: 20])
    send(pid, :go)
    request!(ctx.model)
    last = List.last(request!(ctx.model)["messages"])
    assert delivery(last) =~ ~r/^<harness>No message arrived within 20 ms/
    assert budget_line(last) =~ "Used so far: 1 of 50 turns, 110 of"
  end

  test "the template in the code is the one in SPEC.md", ctx do
    start!(ctx)
    [_, spec] = Regex.run(~r/## System prompt.*?```\n(.*?)```/s, File.read!("SPEC.md"))
    pattern = spec |> Regex.escape() |> String.replace(~r/\\\{\\\{\w+\\\}\\\}/, ".+?")
    assert NanoAgent.info(ctx.name).system_prompt =~ Regex.compile!("^" <> pattern <> "$", "s")

    assert NanoAgent.info(ctx.name).system_prompt =~
             "Whenever I\ndeliver events or a note of my own, I tell you"
  end

  ## Unlimited limits and the context limit

  test "unlimited turns, tokens and context never halt, and say so", ctx do
    {pid, id} = start!(ctx, max_turns: 0, max_tokens: 0, max_context: 0)
    prompt = NanoAgent.info(ctx.name).system_prompt

    assert prompt =~
             "Your limits: unlimited\nturns, unlimited tokens in total, and a context of unlimited\ntokens."

    # More turns, tokens and context than the default limits allow.
    for _ <- 1..54, do: Fake.push(ctx.model, calls: [eval: "1"], usage: {60_000, 10, 0})
    Fake.push(ctx.model, calls: [eval: "1"], usage: {2_000_000, 10, 0})
    Fake.push(ctx.model, text: "done")
    send(pid, :go)

    body = request!(ctx.model)

    assert budget_line(List.last(body["messages"])) ==
             "<harness>Used so far: 0 turns (no limit), 0 tokens (no limit), context 0 tokens (no limit).</harness>"

    for _ <- 1..55, do: request!(ctx.model)
    assert await(id, :turn_ended)["reason"] == "no_tool_call"
    assert entries(id, :budget_exhausted) == []
    :sys.get_state(pid)

    assert %{
             halted: nil,
             budget: %{
               turns_used: 56,
               max_turns: 0,
               max_tokens: 0,
               max_context: 0,
               context_used: 110
             }
           } = NanoAgent.info(ctx.name)

    assert NanoAgent.info(ctx.name).budget.tokens_used > 5_000_000
  end

  test "the context limit halts with :context; un-halting does not shrink it", ctx do
    {pid, id} = start!(ctx, max_context: 150)
    Fake.push(ctx.model, calls: [eval: "1"], usage: {100, 10, 0})
    Fake.push(ctx.model, calls: [eval: "2"], usage: {140, 20, 0})
    send(pid, :go)
    request!(ctx.model)
    request!(ctx.model)

    assert %{"scope" => "context", "context_used" => 160, "max_context" => 150} =
             await(id, :budget_exhausted)

    assert await(id, :turn_ended, &(&1["reason"] == "budget"))
    :sys.get_state(pid)

    assert %{halted: :context, budget: %{context_used: 160, max_context: 150}} =
             NanoAgent.info(ctx.name)

    Fake.push(ctx.model, text: "still here", usage: {170, 5, 0})
    NanoAgent.unhalt(ctx.name)
    last = List.last(request!(ctx.model)["messages"])
    max = Application.get_env(:nano, :agent_max_tokens)

    assert delivery(last) ==
             "<harness>This conversation's context has reached 160 of 150 tokens, so I have halted you: " <>
               "I will not call the model until an operator un-halts you.</harness>\n" <>
               "<harness>An operator un-halted you. This conversation does not shrink: its context is " <>
               "still 160 of 150 tokens, so I will halt you again after my next call to the model.</harness>"

    assert budget_line(last) ==
             "<harness>Used so far: 2 of 50 turns, 270 of #{max} tokens, context 160 of 150 tokens.</harness>"

    # As it said: halted again after that call.
    await_nth(id, :budget_exhausted, 2)
    :sys.get_state(pid)
    assert %{halted: :context, budget: %{context_used: 175}} = NanoAgent.info(ctx.name)
  end

  test "a node-wide hourly cap of 0 is no cap", ctx do
    Application.put_env(:nano, :node_max_tokens_per_hour, 0)
    {pid, id} = start!(ctx)
    Fake.push(ctx.model, calls: [eval: "1"])
    Fake.push(ctx.model, text: "done")
    send(pid, :go)
    request!(ctx.model)
    request!(ctx.model)
    assert await(id, :turn_ended)["reason"] == "no_tool_call"
    assert entries(id, :budget_exhausted) == []
  end

  test "state saved by the previous version (no context fields) keeps working", ctx do
    {pid, id} = start!(ctx)
    old = fn s -> Map.drop(s, [:max_context, :context_used]) end
    :sys.replace_state(pid, old)
    Nano.StateStore.put(ctx.name, old.(Nano.StateStore.get(ctx.name)))
    {mod, bin, file} = :code.get_object_code(NanoAgent)
    for _ <- 1..2, do: {:module, NanoAgent} = :code.load_binary(mod, file, bin)

    ctx_max = Application.get_env(:nano, :agent_max_context)
    assert %{budget: %{context_used: 0, max_context: ^ctx_max}} = NanoAgent.info(ctx.name)
    Fake.push(ctx.model, text: "ok")
    send(pid, :go)

    assert budget_line(List.last(request!(ctx.model)["messages"])) =~
             "context 0 of #{ctx_max} tokens"

    await(id, :turn_ended)

    # And through a restart, from an old-shape entry.
    :sys.replace_state(pid, old)
    Nano.StateStore.put(ctx.name, old.(Nano.StateStore.get(ctx.name)))
    Fake.push(ctx.model, text: "ok")
    kill(ctx, id)
    assert delivery(List.last(request!(ctx.model)["messages"])) =~ "Your process exited"
    assert NanoAgent.info(ctx.name).system_prompt =~ "a context of #{ctx_max}\ntokens"
  end
end

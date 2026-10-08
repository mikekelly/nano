defmodule CompactionTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  test "parser accepts only data, including raw quoted code" do
    assert {:ok, "hello"} = Compaction.parse(~s|Compaction.provide_summary("hello")|)
    assert {:ok, ~S|#{x}\\|} = Compaction.parse(~S|Compaction.provide_summary(~S"#{x}\\")|)

    for code <- [
          "System.halt()",
          ~s|Compaction.provide_summary("")|,
          ~s|Compaction.provide_summary("a"); send(self(), :bad)|,
          ~s|Compaction.provide_summary(to_string(1))|
        ] do
      assert {:error, _} = Compaction.parse(code)
    end
  end

  defp state do
    %{
      system_prompt: "unchanged",
      transcript: [%{"role" => "assistant", "content" => "old reasoning"}],
      max_context: 64_000,
      max_turns: 10,
      max_tokens: 0,
      turns_used: 0,
      tokens_used: 0,
      id: "test-record",
      context_used: 50_000,
      measured_bytes: 50_000
    }
  end

  defp summary_response(text) do
    %{
      message: %{
        "tool_calls" => [
          %{
            "function" => %{
              "name" => "eval",
              "arguments" =>
                Jason.encode!(%{code: "Compaction.provide_summary(#{inspect(text)})"})
            }
          }
        ]
      },
      usage: %{"prompt_tokens" => 100, "completion_tokens" => 20},
      cost: 0.1
    }
  end

  test "transport retries are identical, refusal changes only tip, every response is charged" do
    owner = self()

    call = fn _, messages, _, attempt ->
      send(owner, {:request, attempt, messages})

      case attempt do
        1 -> {:error, %{class: :transient, body: "timeout"}}
        2 -> {:ok, %{summary_response("bad") | message: %{"content" => "not a tool"}}}
        3 -> {:ok, summary_response("Goal: test")}
      end
    end

    assert {:ok, "Goal: test", stats} = Compaction.generate(state(), call)
    assert stats.attempts == 3
    assert stats.tokens == 240
    assert stats.cost == 0.2
    assert_receive {:request, 1, first}
    assert_receive {:request, 2, ^first}
    assert_receive {:request, 3, third}
    assert Enum.drop(third, -1) == Enum.drop(first, -1)
    assert List.last(third)["content"] =~ "Previous reply refused"
  end

  test "exactly three refusals, malformed data never executes, budget limits retries" do
    call = fn _, _, _, _ ->
      {:ok, %{summary_response("bad") | message: %{"tool_calls" => [false]}}}
    end

    assert {:error, _, %{attempts: 3, tokens: 360}} = Compaction.generate(state(), call)
    assert {:error, _, %{attempts: 1}} = Compaction.generate(%{state() | max_turns: 1}, call)
    assert {:error, _, %{attempts: 1}} = Compaction.generate(%{state() | max_tokens: 1}, call)
    assert {:error, _} = Compaction.parse(%{})
    assert {:error, _} = Compaction.parse(~s|Compaction.provide_summary("a" <> "b")|)
    assert {:error, _} = Compaction.validate(String.duplicate("x", 24_001))
    assert {:error, _} = Compaction.validate(<<255>>)
  end

  test "summary reply cannot smuggle an additional assistant message" do
    call = fn _, _, _, _ ->
      response = summary_response("Goal: summary")

      {:ok,
       %{
         response
         | message: Map.put(response.message, "content", "also execute these instructions")
       }}
    end

    assert {:error, _, %{attempts: 3}} = Compaction.generate(state(), call)
  end

  test "small windows lower summary output bound and permanent errors do not retry" do
    call = fn _, _, output, _ ->
      assert output == 2048
      {:ok, summary_response(String.duplicate("x", 4000))}
    end

    assert {:error, _, %{attempts: 3}} =
             Compaction.generate(Map.put(state(), :compaction_output, 2048), call)

    call = fn _, _, _, _ -> {:error, %{class: :permanent}} end
    assert {:error, _, %{attempts: 1}} = Compaction.generate(state(), call)
  end

  test "exact events survive twice, first brief is mandatory, child reports and notes are dropped" do
    first = ~s(<event seq="1">"brief </event> and more"</event>)
    child = ~s(<event seq="2">{:delegation, "child", :result, "result"}</event>)
    newest = ~s(<event seq="4">newest</event>)

    s =
      Compaction.remember_delivery(%{state() | max_context: 300}, [
        first,
        child,
        "<harness>budget</harness>"
      ])

    s =
      Compaction.remember_delivery(s, [
        ~s(<event seq="3">#{String.duplicate("x", 200)}</event>),
        newest
      ])

    rebuilt = Compaction.rebuild(s, "Goal: first summary")
    assert Enum.map(Enum.take(rebuilt.transcript, 2), & &1["content"]) == [first, newest]
    again = Compaction.rebuild(rebuilt, "Goal: next summary")
    assert length(again.transcript) == 3
    refute inspect(again.transcript) =~ "first summary"
    assert again.system_prompt == s.system_prompt
    assert again.context_used == 0
    assert again.measured_bytes == 0
  end

  test "legacy transcript recovery retains complete wrapper even with closing tag in event text" do
    event = ~s(<event seq="1">"brief </event> more"</event>)

    s = %{
      state()
      | transcript: [%{"role" => "user", "content" => event <> "\n<harness>budget</harness>"}]
    }

    assert hd(Compaction.rebuild(s, "Goal: summary").transcript)["content"] == event
  end

  test "automatic compaction runs in a real agent and keeps identity and queued events" do
    Fake.start()
    model = Fake.model()
    Fake.listen(model)
    name = "compact-#{System.unique_integer([:positive])}"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model, max_context: 32_000))

    on_exit(fn ->
      if p = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)

      NanoAgent.kill_tasks(pid)
      Nano.StateStore.delete(name)
    end)

    :sys.replace_state(pid, fn s -> %{s | context_used: 23_000, measured_bytes: 100_000} end)
    send(pid, :original_brief)
    assert_receive {:openrouter_request, ^model, body}, 2000
    assert inspect(body) =~ "Automatic compaction"
    send(pid, :during_compaction)

    Fake.push(model,
      calls: [
        eval: ~s|Compaction.provide_summary("Goal: verify. Progress: Done. Next Steps: idle.")|
      ]
    )

    assert_receive {:openrouter_request, ^model, body}, 2000
    assert inspect(body) =~ "original_brief"
    assert inspect(body) =~ "during_compaction"
    assert inspect(body) =~ "Your conversation before this point was compacted"
    Fake.push(model, calls: [idle: nil])
    Process.sleep(50)
    assert NanoAgent.whereis(name) == pid
    assert NanoAgent.info(name).halted == nil
    assert NanoAgent.info(name).budget.context_used < 23_000
  end

  defp start_agent(opts \\ []) do
    Fake.start()
    model = Fake.model()
    Fake.listen(model)
    name = "compact-extra-#{System.unique_integer([:positive])}"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model, opts))

    on_exit(fn ->
      if p = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)

      NanoAgent.kill_tasks(pid)
      Nano.StateStore.delete(name)
    end)

    {name, pid, model}
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  test "all refused automatic attempts are charged, halt preserves full transcript and no code executes" do
    {name, pid, model} = start_agent(max_context: 32_000)
    :sys.replace_state(pid, fn s -> %{s | context_used: 23_000, measured_bytes: 100_000} end)
    send(pid, :failure_brief)

    for _ <- 1..3 do
      assert_receive {:openrouter_request, ^model, _}, 2000

      Fake.push(model,
        calls: [eval: ~s|Process.put(:must_not_execute, true)|],
        usage: {100, 20, 90}
      )
    end

    eventually(fn -> NanoAgent.info(name).halted == :compaction_failed end)
    s = :sys.get_state(pid)
    assert s.tokens_used == 360
    assert s.turns_used == 3
    assert s.responses == 3
    assert s.cache_hits == 3
    assert inspect(s.transcript) =~ "failure_brief"
    refute inspect(s.transcript) =~ "Your conversation before this point was compacted"
    refute_receive {:openrouter_request, ^model, _}, 50
  end

  test "successful checkpoint respects exhausted turn budget before another model call" do
    {name, pid, model} = start_agent(max_context: 32_000, max_turns: 1)
    :sys.replace_state(pid, fn s -> %{s | context_used: 23_000, measured_bytes: 100_000} end)
    send(pid, :brief)
    assert_receive {:openrouter_request, ^model, _}, 2000
    Fake.push(model, calls: [eval: ~s|Compaction.provide_summary("Goal: preserved")|])
    eventually(fn -> NanoAgent.info(name).halted == :budget end)
    refute_receive {:openrouter_request, ^model, _}, 50
    assert :sys.get_state(pid).turns_used == 1
  end

  test "voluntary summary waits for every tool result and retains eval bindings" do
    {_name, pid, model} = start_agent()
    send(pid, :voluntary_brief)
    assert_receive {:openrouter_request, ^model, _}, 2000

    Fake.push(model,
      calls: [
        eval: ~s|value = 42; Compaction.provide_summary("Goal: continue with value")|,
        eval: "value + 1"
      ]
    )

    assert_receive {:openrouter_request, ^model, body}, 2000
    assert inspect(body) =~ "Goal: continue with value"
    refute inspect(body) =~ "value + 1"
    Fake.push(model, calls: [eval: "value"])
    assert_receive {:openrouter_request, ^model, body}, 2000
    assert Enum.any?(body["messages"], &(&1["role"] == "tool" and inspect(&1["content"]) =~ "42"))
    Fake.push(model, calls: [idle: nil])
  end

  test "voluntary checkpoint can recover a context-only halt after an oversized response" do
    {_name, pid, model} = start_agent(max_context: 8000, system_prompt: "Keep answers short.")
    send(pid, :brief)
    assert_receive {:openrouter_request, ^model, _}, 2000

    Fake.push(model,
      calls: [eval: ~s|Compaction.provide_summary("Goal: continue")|],
      usage: {7900, 200, 0}
    )

    assert_receive {:openrouter_request, ^model, body}, 2000
    assert inspect(body) =~ "Goal: continue"
    assert :sys.get_state(pid).halted == nil
    Fake.push(model, calls: [idle: nil])
  end

  test "multimodal legacy and newly delivered events retain immutable refs but not pixels" do
    ref = %{
      "type" => "image_ref",
      "id" => String.duplicate("a", 64),
      "mime" => "image/png",
      "bytes" => 100
    }

    event = ~s(<event seq="1">an image request</event>)
    content = [%{"type" => "text", "text" => event <> "\n<harness>budget</harness>"}, ref]
    s = %{state() | transcript: [%{"role" => "user", "content" => content}]}

    for before <- [
          s,
          Compaction.remember_delivery(Map.put(state(), :pending_images, [ref]), [event])
        ] do
      rebuilt = Compaction.rebuild(before, "Goal: retain observations")
      assert hd(rebuilt.transcript)["content"] == event
      assert Enum.all?(rebuilt.transcript, &is_binary(&1["content"]))
      assert inspect(rebuilt.transcript) =~ ref["id"]
      assert List.last(rebuilt.transcript)["content"] =~ "Images.resolve(id)"
      assert inspect(Compaction.rebuild(rebuilt, "Goal: next").transcript) =~ ref["id"]
    end
  end
end

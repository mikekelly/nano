defmodule Nano.BotsRuntimeTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()

    path =
      Path.join(
        System.tmp_dir!(),
        "nova-bots-runtime-#{System.unique_integer([:positive])}/state.term"
      )

    {:ok, service} =
      Nano.Bots.start_link(
        name: {:global, make_ref()},
        path: path,
        decision: fn _, _ -> {:error, :offline} end,
        runner: fn _, _, _, _ -> :ok end
      )

    on_exit(fn -> File.rm_rf(Path.dirname(path)) end)
    %{s: service}
  end

  defp eventually(fun, n \\ 100) do
    cond do
      fun.() ->
        :ok

      n == 0 ->
        flunk("condition did not settle")

      true ->
        Process.sleep(20)
        eventually(fun, n - 1)
    end
  end

  test "proactive monitor rolls over idle agent without waiting for a human turn", %{s: s} do
    model = Fake.model()
    Fake.listen(model)
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s, agent_options: Fake.opts(model))
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)
    name = "bot-#{a.id}-#{chat.id}-0"
    {:ok, _} = NanoAgent.start(Keyword.merge(Fake.opts(model), name: name))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    saved = Nano.StateStore.get(name)

    Nano.StateStore.put(name, %{
      saved
      | context_used: saved.max_context,
        transcript: [%{role: "user", content: "Commitment: book vegetarian dinner on Friday"}]
    })

    send(s, :monitor)
    eventually(fn -> Nano.Bots.snapshot(s).sessions[chat.id].generation == 1 end)
    eventually(fn -> NanoAgent.whereis(name) == nil end)
    brief = Nano.Bots.snapshot(s).sessions[chat.id].brief
    assert brief =~ "vegetarian dinner"
    {:ok, checkpoint} = Nano.Bots.checkpoint(chat.id, 0, server: s)
    assert checkpoint.text =~ "vegetarian dinner"
  end

  test "compaction defers retirement while an eval is running", %{s: s} do
    model = Fake.model()
    Fake.listen(model)
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)
    name = "bot-#{a.id}-#{chat.id}-0"
    {:ok, pid} = NanoAgent.start(Keyword.merge(Fake.opts(model), name: name))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    saved = Nano.StateStore.get(name)

    Nano.StateStore.put(name, %{
      saved
      | context_used: saved.max_context,
        status: :running_tool,
        halted: :context
    })

    send(s, :monitor)
    Process.sleep(30)
    assert Process.alive?(pid)
    assert Nano.Bots.snapshot(s).sessions[chat.id].generation == 0

    refute match?(
             {:current_function, {:sys, :suspend_loop, _}},
             Process.info(pid, :current_function)
           )

    Nano.StateStore.put(name, %{saved | context_used: saved.max_context, status: :idle})
    send(s, :monitor)
    eventually(fn -> Nano.Bots.snapshot(s).sessions[chat.id].generation == 1 end)
  end

  test "real context policy compacts only after a running eval completes", %{s: s} do
    model = Fake.model()
    Fake.listen(model)
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)
    name = "bot-#{a.id}-#{chat.id}-0"
    Registry.register(Nano.Registry, {:bots_eval_observer, name}, nil)

    code =
      "[{p, _}] = Registry.lookup(Nano.Registry, {:bots_eval_observer, " <>
        inspect(name) <>
        "}); send(p, {:eval_started, self()}); receive do :finish -> String.duplicate(\"🧠\", 7000) end"

    Fake.push(model, calls: [eval: code], usage: {9000, 100, 0})
    Fake.push(model, text: "finished")

    {:ok, pid} =
      NanoAgent.start(
        Keyword.merge(Fake.opts(model),
          name: name,
          max_context: 8192,
          system_prompt: "short",
          context_policy: Nano.Bots.Context
        )
      )

    on_exit(fn ->
      Nano.Ops.stop_agent(name)
      Nano.StateStore.delete(name)
    end)

    NanoAgent.notify(pid, :hello)
    assert_receive {:openrouter_request, ^model, _}, 2000
    assert_receive {:eval_started, tool}, 2000
    state = Nano.StateStore.get(name)
    assert state.halted == :context
    assert state.status == :running_tool
    assert state.task != nil or state.calls != []
    send(s, :monitor)
    Process.sleep(30)
    assert Process.alive?(tool)
    assert Process.alive?(pid)
    assert Nano.Bots.snapshot(s).sessions[chat.id].generation == 0
    # Stop only the isolated monitor so the final state remains available for
    # cumulative-budget assertions rather than being archived and retired.
    GenServer.stop(s)
    send(tool, :finish)
    assert_receive {:openrouter_request, ^model, request}, 2000
    assert Enum.map(request["messages"], & &1["role"]) == ["system", "user"]
    assert Jason.encode!(request["messages"]) =~ "Bot working checkpoint"

    eventually(fn ->
      match?(%{status: :idle, task: nil, calls: []}, Nano.StateStore.get(name))
    end)

    final = Nano.StateStore.get(name)
    assert final.halted == nil
    assert final.turns_used == 2
    assert final.tokens_used == 9210
    assert final.task == nil
    assert final.calls == []
  end

  test "worker throw and exit reconcile to unavailable", %{s: s} do
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)

    for runner <- [fn _, _, _, _ -> throw(:bad) end, fn _, _, _, _ -> exit(:bad) end] do
      :sys.replace_state(s, &%{&1 | runner: runner})
      send(s, {:deliver, chat.id, a.id, "test"})
      eventually(fn -> Nano.Bots.snapshot(s).sessions[chat.id].status[a.id] == :unavailable end)
    end
  end

  test "preparation disk failure retains failed item and labels status", %{s: s} do
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)

    :sys.replace_state(s, fn state ->
      %{
        state
        | path: Path.join(state.path, "impossible"),
          preparing: MapSet.put(state.preparing, chat.id),
          work_queues: %{chat.id => ["next"]}
      }
    end)

    send(s, {:prepared, chat.id, 0, chat, "failed"})
    eventually(fn -> Nano.Bots.snapshot(s).sessions[chat.id].status[a.id] == :unavailable end)
    state = :sys.get_state(s)
    assert state.work_queues[chat.id] == ["failed", "next"]
    refute MapSet.member?(state.preparing, chat.id)
  end

  test "bootstrap failure with zero turns is not stuck thinking", %{s: s} do
    model = Fake.model()
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)
    name = "bot-#{a.id}-#{chat.id}-0"
    {:ok, _} = NanoAgent.start(Keyword.merge(Fake.opts(model), name: name))

    on_exit(fn ->
      Nano.Ops.stop_agent(name)
      Nano.StateStore.delete(name)
    end)

    saved = Nano.StateStore.get(name)

    Nano.StateStore.put(name, %{
      saved
      | status: :idle,
        halted: :start_failed,
        turns_used: 0,
        task: nil,
        calls: [],
        pending: []
    })

    :sys.replace_state(s, fn state ->
      %{state | data: put_in(state.data, [:sessions, chat.id, :status, a.id], :thinking)}
    end)

    send(s, :monitor)
    eventually(fn -> Nano.Bots.snapshot(s).sessions[chat.id].status[a.id] == :unavailable end)
  end

  test "failed archive does not stop old agent or start a fresh budget", %{s: s} do
    model = Fake.model()
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s, agent_options: Fake.opts(model))
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)
    name = "bot-#{a.id}-#{chat.id}-0"
    {:ok, pid} = NanoAgent.start(Keyword.merge(Fake.opts(model), name: name))

    on_exit(fn ->
      Nano.Ops.stop_agent(name)
      Nano.StateStore.delete(name)
    end)

    :sys.replace_state(s, &%{&1 | path: Path.join(&1.path, "impossible")})

    assert {:error, :bot_budget_archive_unavailable} =
             Nano.Bots.Runtime.deliver(
               Map.put(a, :server, s),
               %{chat | generation: 1},
               "test",
               []
             )

    assert Process.alive?(pid)
    assert NanoAgent.whereis("bot-#{a.id}-#{chat.id}-1") == nil
  end

  test "missing or corrupt prior archive fails closed", %{s: s} do
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)

    :sys.replace_state(s, fn state ->
      %{state | data: put_in(state.data, [:sessions, chat.id, :generation], 1)}
    end)

    assert {:error, :missing_budget_archive} = Nano.Bots.usage(chat.id, a.id, s)
    state = :sys.get_state(s)
    path = Path.join([Path.dirname(state.path), "checkpoints", "#{chat.id}-0.term"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "corrupt")
    assert {:error, :invalid_budget_archive} = Nano.Bots.usage(chat.id, a.id, s)
  end

  test "provider settings

 are durable and secrets are rejected",
       %{s: s} do
    {:ok, a} =
      Nano.Bots.create_bot("Ada",
        server: s,
        agent_options: [
          model: "test/model",
          reasoning: "off",
          max_context: 20000,
          api_key: "never-persist-this"
        ]
      )

    assert a.agent_options[:model] == "test/model"
    refute Keyword.has_key?(a.agent_options, :api_key)
    assert :ok = Nano.Bots.configure(a.id, server: s, agent_options: [model: "test/new"])
    assert Nano.Bots.snapshot(s).bots[a.id].agent_options == [model: "test/new"]
  end

  test "slow semantic decisions do not block snapshot or acknowledgements", %{s: s} do
    # Replace only this isolated service's callback, not application configuration.
    :sys.replace_state(s, fn state ->
      %{
        state
        | decision: fn _, _ ->
            Process.sleep(150)
            {:error, :offline}
          end
      }
    end)

    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)
    start = System.monotonic_time(:millisecond)
    assert :ok = Nano.Bots.say(chat.id, "Hello", s)
    assert Nano.Bots.snapshot(s).sessions[chat.id].messages != []
    assert System.monotonic_time(:millisecond) - start < 100
  end
end

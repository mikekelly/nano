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

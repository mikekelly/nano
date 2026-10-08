defmodule Seedling.BotNativeDeliveryTest do
  use ExUnit.Case, async: false
  alias Seedling.{Bots, CapabilityStore}
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()
    root = Path.join(System.tmp_dir!(), "orion-native-bots-" <> CapabilityStore.id())
    model = Fake.model()
    {:ok, server} = Bots.start_link(name: nil, root: root, decision_opts: [key: nil])
    opts = [server: server]

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
      File.rm_rf(root)
    end)

    %{server: server, opts: opts, model: model}
  end

  defp session(c, extra \\ []) do
    {:ok, bot} =
      Bots.create(
        "Native test",
        c.opts ++ [model: c.model, reasoning: "off", max_context: 64000] ++ extra
      )

    {:ok, chat} = Bots.session([bot["id"]], c.opts)
    name = Bots.agent_name(chat["id"], bot["id"])

    on_exit(fn ->
      if pid = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(name)
    end)

    {bot, chat, name}
  end

  defp eventually(fun, n \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, n - 1)
        )
  end

  defp status(c, bot, chat),
    do: Bots.snapshot(c.server)["sessions"][chat["id"]]["status"][bot["id"]]

  test "real HTTP hard refusal is visible and next human request cannot stick thinking", c do
    {bot, chat, name} = session(c)
    Fake.push(c.model, status: 400)
    assert {:ok, _} = Bots.say(chat["id"], "First request", c.opts)
    assert_receive {:openrouter_request, model, _}, 2000
    assert model == c.model
    eventually(fn -> NanoAgent.info(name) && NanoAgent.info(name).halted == :model_refused end)
    eventually(fn -> status(c, bot, chat) =~ "unavailable" end)
    assert {:ok, _} = Bots.say(chat["id"], "Try again without operator resume", c.opts)
    eventually(fn -> status(c, bot, chat) =~ "paused" end)
    refute_receive {:openrouter_request, ^model, _}, 100
    assert length(Bots.snapshot(c.server)["sessions"][chat["id"]]["messages"]) == 2
  end

  test "real native turn budget halt is visible without consuming the next message", c do
    {bot, chat, name} = session(c, max_turns: 1)
    Fake.push(c.model, calls: [eval: "1 + 1"])
    assert {:ok, _} = Bots.say(chat["id"], "Use an eval", c.opts)
    assert_receive {:openrouter_request, model, _}, 2000
    eventually(fn -> NanoAgent.info(name) && NanoAgent.info(name).halted == :budget end)
    eventually(fn -> status(c, bot, chat) =~ "unavailable" end)
    assert {:ok, _} = Bots.say(chat["id"], "Another request", c.opts)
    eventually(fn -> status(c, bot, chat) =~ "paused" end)
    refute_receive {:openrouter_request, ^model, _}, 100
  end

  test "transient provider retry returns to idle after a real second HTTP request", c do
    {bot, chat, name} = session(c)
    old = Application.get_env(:nano, :openrouter_backoff_ms)
    Application.put_env(:nano, :openrouter_backoff_ms, 10)
    on_exit(fn -> Application.put_env(:nano, :openrouter_backoff_ms, old) end)
    Fake.push(c.model, status: 500)
    Fake.push(c.model, text: "private recovered reply")
    assert {:ok, _} = Bots.say(chat["id"], "Transient request", c.opts)
    assert_receive {:openrouter_request, model, _}, 2000
    assert_receive {:openrouter_request, ^model, _}, 2000
    eventually(fn -> NanoAgent.info(name) && NanoAgent.info(name).status == :idle end)
    eventually(fn -> status(c, bot, chat) == "idle" end)
    assert NanoAgent.info(name).halted == nil
    assert length(Bots.snapshot(c.server)["sessions"][chat["id"]]["messages"]) == 1
  end

  test "stopped native session revives the saved id and history, never a fresh agent", c do
    {_bot, chat, name} = session(c)
    Fake.push(c.model, text: "private final result")
    assert {:ok, _} = Bots.say(chat["id"], "Original retained marker", c.opts)
    assert_receive {:openrouter_request, model, _}, 2000
    eventually(fn -> NanoAgent.info(name) && NanoAgent.info(name).status == :idle end)
    old = NanoAgent.info(name)
    DynamicSupervisor.terminate_child(Nano.AgentSupervisor, NanoAgent.whereis(name))
    Fake.push(c.model, text: "still private")
    assert {:ok, _} = Bots.say(chat["id"], "After stop", c.opts)
    assert_receive {:openrouter_request, ^model, body}, 2000
    assert Jason.encode!(body["messages"]) =~ "Original retained marker"
    assert NanoAgent.info(name).id == old.id
    assert NanoAgent.info(name).restart_count > old.restart_count
  end
end

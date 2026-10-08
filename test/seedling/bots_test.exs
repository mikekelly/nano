defmodule Seedling.BotsTest do
  use ExUnit.Case, async: true
  alias Seedling.{Bots, CapabilityStore, Memory}

  setup do
    root = Path.join(System.tmp_dir!(), "orion-bots-test-" <> CapabilityStore.id())
    parent = self()

    starter = fn opts ->
      name = opts[:name]

      pid =
        spawn(fn ->
          :yes = Nano.Names.register_name({:agent, name}, self())
          send(parent, {:started, name, self(), opts})
          forward(parent)
        end)

      {:ok, pid}
    end

    {:ok, server} =
      Bots.start_link(name: nil, root: root, agent_starter: starter, decision_opts: [key: nil])

    opts = [server: server]

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)

      for {{:agent, name}, pid} <- Nano.Names.all(), String.starts_with?(name, "bot-") do
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} -> if dict[:test_owner] == parent, do: Process.exit(pid, :kill)
          _ -> :ok
        end
      end

      File.rm_rf(root)
    end)

    %{server: server, opts: opts, root: root, starter: starter}
  end

  defp forward(parent) do
    Process.put(:test_owner, parent)

    receive do
      {:post, server, session, bot, text} ->
        send(parent, {:posted, Bots.post(session, bot, text, server: server)})

      msg ->
        send(parent, {:bot_event, self(), msg})
    end

    forward(parent)
  end

  defp bot(opts, name),
    do: Bots.create(name, opts ++ [model: "fake/model", reasoning: "off", max_context: 20000])

  test "two bots, isolated sessions, shared bot memory and authorized post", c do
    assert {:ok, a} = bot(c.opts, "Muse")
    assert {:ok, b} = bot(c.opts, "Dots")
    assert {:ok, one} = Bots.session([a["id"]], c.opts)
    assert {:ok, group} = Bots.session([a["id"], b["id"]], c.opts)

    assert {:ok, _} =
             Memory.remember(a["id"], "preference", "Quiet hotels",
               root: c.root,
               session: one["id"]
             )

    assert {:ok, _} = Bots.say(one["id"], "Quiet hotels please", c.opts)
    one_name = Bots.agent_name(one["id"], a["id"])
    assert_receive {:started, ^one_name, one_pid, startup}
    assert startup[:system_prompt] =~ "ONLY to session #{one["id"]}"
    assert_receive {:bot_event, ^one_pid, %{session_id: session, memory: memory}}
    assert session == one["id"]
    assert memory =~ "Quiet hotels"
    assert {:ok, _} = Bots.say(group["id"], "Help with hotels", c.opts)
    group_a_name = Bots.agent_name(group["id"], a["id"])
    group_b_name = Bots.agent_name(group["id"], b["id"])
    assert_receive {:started, ^group_a_name, group_a, _}
    assert_receive {:started, ^group_b_name, group_b, _}
    refute group_a == one_pid
    assert_receive {:bot_event, ^group_a, %{conversation: conversation, session_id: group_id}}
    assert group_id == group["id"]
    refute Enum.any?(conversation, &(&1["text"] == "Quiet hotels please"))
    assert {:error, :not_session_agent} = Bots.post(one["id"], a["id"], "forged", c.opts)
    send(group_a, {:post, c.server, group["id"], a["id"], "Safe reply"})
    assert_receive {:posted, {:ok, _}}

    assert List.last(Bots.snapshot(c.server)["sessions"][group_id]["messages"])["text"] ==
             "Safe reply"

    Enum.each([one_pid, group_a, group_b], &Process.exit(&1, :kill))
  end

  test "restart preserves identity and correlated human request provenance", c do
    assert {:ok, b} = bot(c.opts, "Muse")
    assert {:ok, chat} = Bots.session([b["id"]], c.opts)
    name = "asker-" <> CapabilityStore.id()
    :yes = Nano.Names.register_name({:agent, name}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, name}) end)
    assert {:ok, r} = Bots.request_human(b["id"], "Which dates?", c.opts ++ [reply_to: self()])
    assert r["requester"] == name
    assert r["reply_target"] == name

    assert {:error, :wrong_answer_session} =
             Bots.answer(r["id"], "Tomorrow", c.opts ++ [session: "wrong"])

    GenServer.stop(c.server)

    {:ok, restarted} =
      Bots.start_link(
        name: nil,
        root: c.root,
        agent_starter: c.starter,
        decision_opts: [key: nil]
      )

    opts = [server: restarted, session: chat["id"]]
    assert Bots.snapshot(restarted)["bots"][b["id"]] == b
    assert {:ok, answered} = Bots.answer(r["id"], "Tomorrow", opts)
    assert answered["state"] == "answered"
    assert_receive %{type: :bot_human_answer, request_id: id, answer: "Tomorrow"}
    assert id == r["id"]
    assert {:error, :request_not_open} = Bots.answer(r["id"], "Again", opts)
    assert {:ok, %{"answer" => "Tomorrow"}} = Bots.request_status(id, opts)
    GenServer.stop(restarted)
  end

  test "notification limits are durable, per-hour cap and cooldown", c do
    assert {:ok, b} = bot(c.opts, "Muse")
    assert {:ok, _} = Bots.session([b["id"]], c.opts)
    Phoenix.PubSub.subscribe(Nano.PubSub, "bots")

    assert {:ok, _} =
             Bots.notifications([enabled: true, per_hour: 1, cooldown_seconds: 0], c.opts)

    assert {:ok, _} = Bots.request_human(b["id"], "First?", c.opts ++ [reply_to: self()])
    assert_receive {:bots, %{notify: true, message: %{"text" => "First?"}}}
    assert {:ok, _} = Bots.request_human(b["id"], "Second?", c.opts ++ [reply_to: self()])
    assert_receive {:bots, %{notify: false, message: %{"text" => "Second?"}}}
    assert {:error, :invalid_notification_limits} = Bots.notifications([per_hour: 100], c.opts)
  end
end

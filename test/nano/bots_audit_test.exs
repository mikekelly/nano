defmodule Nano.BotsAuditTest do
  use ExUnit.Case, async: true

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "nova-bots-audit-#{System.unique_integer([:positive])}/state.term"
      )

    parent = self()

    {:ok, s} =
      Nano.Bots.start_link(
        name: {:global, make_ref()},
        path: path,
        decision: fn
          :respond, _ -> {:ok, %{value: true, probability: 0.9, confidence: 0.9}}
          _, _ -> {:error, :offline}
        end,
        runner: fn bot, chat, text, _ ->
          send(parent, {:delivery, bot.id, chat.id, text, self()})

          receive do
            :release -> :ok
          after
            5000 -> :ok
          end
        end
      )

    on_exit(fn -> File.rm_rf(Path.dirname(path)) end)
    %{s: s}
  end

  test "eval task request reply target is the stable registered caller", %{s: s} do
    name = "audit-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(Nano.Registry, {:agent, name}, nil)
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)
    task = Task.async(fn -> Nano.Bots.ask_human(a.id, "Date?", session: chat.id, server: s) end)
    {:ok, rid} = Task.await(task)
    assert Nano.Bots.snapshot(s).requests[rid].reply_to == name
    assert Nano.Bots.answer(rid, "Friday", s) == :ok
    assert_receive {:"$gen_cast", {:notify, {:nano_human_answer, ^rid, "Friday"}}}
  end

  test "old generation eval cannot post and delivery result does not undo idle", %{s: s} do
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)
    :ok = Nano.Bots.say(chat.id, "Hello", s)
    aid = a.id
    sid = chat.id
    assert_receive {:delivery, ^aid, ^sid, "Hello", worker}
    :ok = Nano.Bots.post(sid, aid, "Hi", s)
    send(worker, :release)
    Process.sleep(20)
    assert Nano.Bots.snapshot(s).sessions[sid].status[aid] == :idle
    {:ok, _} = Registry.register(Nano.Registry, {:agent, "bot-#{aid}-#{sid}-0"}, nil)
    :ok = Nano.Bots.say(sid, String.duplicate("long message ", 2000), s)
    assert Nano.Bots.snapshot(s).sessions[sid].generation == 1
    task = Task.async(fn -> Nano.Bots.post(sid, aid, "stale", s) end)
    assert {:error, :invalid_message_or_participant} = Task.await(task)
  end

  test "model-routed group peer turns have a finite budget", %{s: s} do
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, b} = Nano.Bots.create_bot("Bea", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id, b.id], server: s)
    :ok = Nano.Bots.say(chat.id, "Help", s)
    aid = a.id
    bid = b.id
    sid = chat.id
    assert_receive {:delivery, ^aid, ^sid, "Help", w1}
    assert_receive {:delivery, ^bid, ^sid, "Help", w2}
    send(w1, :release)
    send(w2, :release)
    :ok = Nano.Bots.post(sid, aid, "Bea, what do you think?", s)
    assert_receive {:delivery, ^bid, ^sid, "Peer bot Ada said: Bea, what do you think?", w3}
    send(w3, :release)
    :ok = Nano.Bots.post(sid, bid, "Ada, another question", s)
    assert_receive {:delivery, ^aid, ^sid, "Peer bot Bea said: Ada, another question", w4}
    send(w4, :release)
    :ok = Nano.Bots.post(sid, aid, "more", s)
    refute_receive {:delivery, _, _, _, _}, 50
  end

  test "probabilities and confidence must be bounded typed values" do
    assert {:ok, %{value: true, probability: 0.9, confidence: 0.8}} =
             Nano.Bots.Decision.validate(
               :respond,
               %{"respond" => true, "probability" => 0.9, "confidence" => 0.8},
               %{}
             )

    assert {:error, :invalid_decision} =
             Nano.Bots.Decision.validate(
               :respond,
               %{"respond" => true, "probability" => 1.1, "confidence" => 0.8},
               %{}
             )

    assert {:error, :invalid_decision} =
             Nano.Bots.Decision.validate(
               :respond,
               %{"respond" => "yes", "probability" => 0.9, "confidence" => 0.8},
               %{}
             )
  end
end

defmodule Nano.BotsTest do
  use ExUnit.Case, async: true

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "nova-bots-test-#{System.unique_integer([:positive])}/state.term"
      )

    name = {:global, {:bots_test, make_ref()}}
    parent = self()

    {:ok, pid} =
      Nano.Bots.start_link(
        name: name,
        path: path,
        decision: fn _, _ -> {:error, :offline} end,
        runner: fn bot, chat, text, memories ->
          send(parent, {:delivered, bot.id, chat.id, text, memories})
          :ok
        end
      )

    on_exit(fn -> File.rm_rf(Path.dirname(path)) end)
    %{server: pid, path: path}
  end

  test "identities, sessions and human request correlation survive restart", %{
    server: s,
    path: path
  } do
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, b} = Nano.Bots.create_bot("Bea", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id, b.id], server: s)
    {:ok, rid} = Nano.Bots.ask_human(a.id, "Choose a date", session: chat.id, server: s)
    assert :ok = Nano.Bots.answer(rid, "Friday", s)
    assert_receive {:nano_human_answer, ^rid, "Friday"}
    assert {:error, :invalid_or_answered_request} = Nano.Bots.answer(rid, "Saturday", s)
    GenServer.stop(s)
    {:ok, restored} = Nano.Bots.start_link(name: {:global, make_ref()}, path: path)
    assert Nano.Bots.snapshot(restored).bots[a.id] == a
    assert Nano.Bots.snapshot(restored).requests[rid].answer == "Friday"
    GenServer.stop(restored)
  end

  test "memory is bounded and relevant across isolated sessions", %{server: s} do
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, one} = Nano.Bots.create_session([a.id], server: s)
    {:ok, two} = Nano.Bots.create_session([a.id], server: s)
    assert :ok = Nano.Bots.remember(a.id, "User prefers vegetarian dinner", server: s)
    assert :ok = Nano.Bots.say(two.id, "Plan dinner", s)
    aid = a.id
    sid = two.id

    assert_receive {:delivered, ^aid, ^sid, "Plan dinner",
                    [%{text: "User prefers vegetarian dinner"}]}

    assert Nano.Bots.snapshot(s).sessions[one.id].messages == []

    assert {:error, :invalid_message_or_participant} =
             Nano.Bots.post(one.id, "unknown", "hello", s)
  end

  test "automatic generation rollover retains display history without tool-call surgery", %{
    server: s
  } do
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)
    assert :ok = Nano.Bots.say(chat.id, String.duplicate("preference ", 2300), s)
    saved = Nano.Bots.snapshot(s).sessions[chat.id]
    assert saved.generation == 1
    assert saved.context_bytes == 0
    assert byte_size(saved.brief) <= 12_000
    assert length(saved.messages) == 1
  end

  test "invalid decision outputs and unavailable providers are honest" do
    mem = [%{text: "dinner vegetarian", at: 1}]
    assert Nano.Bots.relevant(mem, "dinner", fn _, _ -> {:ok, [%{text: "invented"}]} end) == mem
    assert {:error, :decision_unavailable} = Nano.Bots.Decision.decide(:compact, %{bytes: 1})
  end

  test "notifications are opt-in and bounded", %{server: s} do
    Phoenix.PubSub.subscribe(Nano.PubSub, "nano:bots")
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, chat} = Nano.Bots.create_session([a.id], server: s)
    :ok = Nano.Bots.post(chat.id, a.id, "First", s)
    assert_receive {:bots_changed, %{notify: false, text: "First"}}
    :ok = Nano.Bots.set_notifications(true, s)
    :ok = Nano.Bots.post(chat.id, a.id, "Second", s)
    assert_receive {:bots_changed, %{notify: true, text: "Second"}}
    :ok = Nano.Bots.post(chat.id, a.id, "Third", s)
    assert_receive {:bots_changed, %{notify: false, text: "Third"}}
  end

  test "write failure does not acknowledge a lost identity", %{server: s, path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.mkdir_p!(path <> ".tmp")
    assert {:error, :eisdir} = Nano.Bots.create_bot("Ada", server: s)
    assert Nano.Bots.snapshot(s).bots == %{}
  end

  test "requests cannot be routed to a chat excluding the bot", %{server: s} do
    {:ok, a} = Nano.Bots.create_bot("Ada", server: s)
    {:ok, b} = Nano.Bots.create_bot("Bea", server: s)
    {:ok, chat} = Nano.Bots.create_session([b.id], server: s)

    assert {:error, :no_matching_session} =
             Nano.Bots.ask_human(a.id, "Hello", session: chat.id, server: s)

    assert {:error, :invalid_name} = Nano.Bots.create_bot("", server: s)
    assert {:error, :invalid_participants} = Nano.Bots.create_session([], server: s)
  end
end

defmodule SeedBotsTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "seed-bots-#{System.unique_integer([:positive])}")
    start_supervised!({SeedBots, directory: dir, agents: false, routing: false})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "identities, isolated sessions, messages and bounded exchanges persist", %{dir: dir} do
    assert {:error, :invalid_identity} = SeedBots.create_bot(%{name: " "})
    {:ok, bot} = SeedBots.create_bot(%{name: "Muse"})
    {:ok, a} = SeedBots.create_session([bot.id])
    {:ok, b} = SeedBots.create_session([bot.id])
    assert {:ok, _} = SeedBots.post(a.id, "Hello")
    assert SeedBots.get_session(b.id).messages == []
    for _ <- 1..8, do: assert({:ok, _} = SeedBots.speak(a.id, bot.id, "Useful reply"))
    assert {:error, :exchange_limit} = SeedBots.speak(a.id, bot.id, "loop")
    assert List.last(SeedBots.get_session(a.id).messages).author == "system"
    assert {:ok, _} = SeedBots.post(a.id, "continue")
    assert {:ok, _} = SeedBots.speak(a.id, bot.id, "okay")
    stop_supervised!(SeedBots)
    start_supervised!({SeedBots, directory: dir, agents: false, routing: false})
    assert [%{name: "Muse"}] = SeedBots.bots()
    assert length(SeedBots.sessions()) == 2
    assert length(SeedBots.get_session(a.id).messages) == 12
  end

  test "human request is answerable once and sends correlated response" do
    {:ok, bot} = SeedBots.create_bot(%{name: "Bot"})
    {:ok, chat} = SeedBots.create_session([bot.id])
    {:ok, rid} = SeedBots.ask_human(chat.id, bot.id, "Which option?")
    assert :ok = SeedBots.answer(rid, "second")
    assert_receive {:seed_bots_answer, ^rid, "second"}
    assert {:error, :unknown_or_answered_request} = SeedBots.answer(rid, "third")
  end

  test "validation, stop and selective empty memory" do
    assert {:error, :invalid_participants} = SeedBots.create_session([])
    {:ok, bot} = SeedBots.create_bot(%{name: "Bot"})
    {:ok, chat} = SeedBots.create_session([bot.id])
    assert {:error, :not_participant} = SeedBots.speak(chat.id, "intruder", "hello")
    assert {:error, :invalid_message} = SeedBots.post(chat.id, String.duplicate("a", 32_001))
    assert :ok = SeedBots.stop(chat.id)
    assert {:error, :exchange_limit} = SeedBots.speak(chat.id, bot.id, "hello")
    assert [] = SeedBots.memories(bot.id, "nothing")
    assert {:error, :invalid_memory} = SeedBots.remember(bot.id, "")

    assert {:ok, %{source_session: sid}} =
             SeedBots.remember(bot.id, "Likes tea", session: chat.id)

    assert sid == chat.id
  end
end

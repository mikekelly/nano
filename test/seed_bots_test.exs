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

  test "decision-selected memory is shared across sessions but never across identities", %{
    dir: dir
  } do
    stop_supervised!(SeedBots)

    decision = fn :memory, %{query: query, candidates: candidates} ->
      {:ok, %{ids: for(c <- candidates, String.contains?(c.text, query), do: c.id)}}
    end

    start_supervised!(
      {SeedBots, directory: dir, agents: false, routing: false, decision: decision}
    )

    {:ok, muse} = SeedBots.create_bot(%{name: "Muse"})
    {:ok, scout} = SeedBots.create_bot(%{name: "Scout"})
    {:ok, first} = SeedBots.create_session([muse.id])
    {:ok, second} = SeedBots.create_session([muse.id])
    {:ok, tea} = SeedBots.remember(muse.id, "Likes tea", session: first.id)
    {:ok, _} = SeedBots.remember(muse.id, "Prefers walking", session: first.id)
    assert [^tea] = SeedBots.memories(muse.id, "tea")
    assert SeedBots.get_session(second.id).messages == []
    assert [] = SeedBots.memories(scout.id, "tea")
    assert [] = SeedBots.memories(muse.id, "unrelated")
    stop_supervised!(SeedBots)

    start_supervised!(
      {SeedBots, directory: dir, agents: false, routing: false, decision: decision}
    )

    assert [^tea] = SeedBots.memories(muse.id, "tea")
  end

  test "agent limits reject invalid values before starting", %{dir: dir} do
    for options <- [
          [max_context: 0],
          [max_context: "1000"],
          [max_turns: -1],
          [max_tokens: -1],
          [reasoning: "secret"],
          [model: nil]
        ] do
      assert {:error, :invalid_agent_options} = SeedBots.start_link([directory: dir] ++ options)
    end
  end

  test "another process cannot impersonate a session bot", %{dir: dir} do
    {:ok, bot} = SeedBots.create_bot(%{name: "Muse"})
    {:ok, chat} = SeedBots.create_session([bot.id])
    stop_supervised!(SeedBots)

    start_supervised!(
      {SeedBots,
       directory: dir,
       agents: true,
       routing: false,
       max_context: 20000,
       max_turns: 20,
       max_tokens: 100_000,
       reasoning: "low"}
    )

    assert {:error, :wrong_agent} = SeedBots.speak(chat.id, bot.id, "impersonation")
    assert SeedBots.get_session(chat.id).messages == []
    assert :ok = SeedBots.stop(chat.id)
    assert {:error, :wrong_agent} = SeedBots.speak(chat.id, bot.id, "after stop")
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

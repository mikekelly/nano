defmodule BotsMemoryTest.Decision do
  def noul(id, question), do: %{id: id, question: question}

  def ask(state, questions, opts) do
    send(opts[:observer], {:memory_decision, state, questions, opts[:timeout]})
    {:ok, Map.new(questions, fn question -> {question.id, %{value: opts[:score] || 0.99}} end)}
  end
end

defmodule BotsMemoryTest do
  use ExUnit.Case, async: true

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "bots-memory-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, bot: %{"id" => "a"}}
  end

  test "Decision relevance retrieves nonliteral facts with preserved provenance", %{
    root: root,
    bot: bot
  } do
    {:ok, _} =
      Bots.Memory.remember(
        "a",
        "session-one",
        "allergy",
        "Peanuts can be dangerous for the person",
        root: root
      )

    recalled =
      Bots.Memory.recall(bot, "Plan dinner",
        root: root,
        decision: BotsMemoryTest.Decision,
        decision_opts: [observer: self()]
      )

    assert [%{"key" => "allergy", "fact" => %{"session_id" => "session-one"}}] = recalled
    assert_receive {:memory_decision, %{query: "Plan dinner"}, [_], 10_000}

    assert Bots.Memory.recall(%{"id" => "b"}, "Plan dinner",
             root: root,
             decision: BotsMemoryTest.Decision,
             decision_opts: [observer: self()]
           ) == []
  end

  test "retrieval limits classifier candidates and injected facts by count and bytes", %{
    root: root,
    bot: bot
  } do
    for n <- 1..30,
        do: Bots.Memory.remember("a", "s", "fact#{n}", String.duplicate("x", 2800), root: root)

    recalled =
      Bots.Memory.recall(bot, "anything",
        root: root,
        decision: BotsMemoryTest.Decision,
        decision_opts: [observer: self()]
      )

    assert_receive {:memory_decision, _, questions, _}
    assert length(questions) == 16
    assert length(recalled) <= 6
    assert Enum.sum(Enum.map(recalled, &byte_size(Jason.encode!(&1)))) <= 6000
    assert length(recalled) == 2
  end

  test "low confidence and missing decision do not dump unrelated memories", %{
    root: root,
    bot: bot
  } do
    {:ok, _} = Bots.Memory.remember("a", "s", "food", "vegetarian food", root: root)

    assert Bots.Memory.recall(bot, "food",
             root: root,
             decision: BotsMemoryTest.Decision,
             decision_opts: [observer: self(), score: 0.1]
           ) == []

    assert Bots.Memory.recall(bot, "astronomy",
             root: root,
             decision: BotsMemoryTest.MissingDecision
           ) == []

    assert [%{"key" => "food"}] =
             Bots.Memory.recall(bot, "food", root: root, decision: BotsMemoryTest.MissingDecision)
  end

  test "writes reject oversized or non-JSON data and invalid keys", %{root: root} do
    for {key, value} <- [
          {"", "x"},
          {<<255>>, "x"},
          {"too big", String.duplicate("x", 3001)},
          {"pid", self()}
        ] do
      assert {:error, :invalid_memory} = Bots.Memory.remember("a", "s", key, value, root: root)
    end
  end
end

defmodule Bots.RouterTest do
  use ExUnit.Case, async: true

  alias Bots.Router

  defmodule FakeDecision do
    def noul(id, statement), do: %{id: id, statement: statement}

    def ask(state, questions, opts) do
      if owner = opts[:owner], do: send(owner, {:decision, self(), state, questions, opts})

      case opts[:action] do
        :raise -> raise "provider failed"
        :exit -> exit(:provider_failed)
        :kill -> Process.exit(self(), :kill)
        :throw -> throw(:provider_failed)
        :sleep -> Process.sleep(5_000)
        _ -> :ok
      end

      Keyword.get(opts, :result, {:ok, %{}})
    end
  end

  defmodule IncompleteDecision do
    def noul(id, statement), do: {id, statement}
  end

  setup do
    bots = [
      %{"id" => "a", "name" => "Ada", "description" => "Mathematics and careful proofs"},
      %{"id" => "b", "name" => "Bea", "description" => "Design and clear illustrations"},
      %{"id" => "c", "name" => "Cora", "description" => "Not in this session"}
    ]

    session = %{"bot_ids" => ["a", "b"], "messages" => [], "bot_exchanges" => 0}
    %{bots: bots, session: session}
  end

  defp human(text, id \\ "human-1"), do: %{"id" => id, "kind" => "human", "text" => text}
  defp bot(text, id \\ "a"), do: %{"kind" => "bot", "bot_id" => id, "text" => text}

  defp opts(scores, extras \\ []) do
    [decision: FakeDecision, decision_opts: [result: {:ok, scores}]] ++ extras
  end

  test "scores candidates through the injected Decision and preserves session order", ctx do
    scores = %{"b" => %{value: 0.95}, "a" => %{value: 0.6}, "c" => %{value: 1.0}}
    assert {:ok, ["a", "b"]} = Router.select(ctx.bots, ctx.session, human("Help"), opts(scores))

    assert {:ok, ["b"]} =
             Router.select(ctx.bots, ctx.session, human("Explain"), opts(%{"b" => %{value: 0.8}}))
  end

  test "recent context includes roles, bot identities, descriptions and follow-up intent", ctx do
    prior = human("Could both of you explain the proof?", "human-0")
    response = bot("I can outline it.")
    message = human("No takers?")
    session = %{ctx.session | "messages" => [prior, response, message]}

    decision_opts = [
      owner: self(),
      custom: :passed_through,
      result: {:ok, %{"b" => %{value: 0.9}}}
    ]

    assert {:ok, ["b"]} =
             Router.select(ctx.bots, session, message,
               decision: FakeDecision,
               decision_opts: decision_opts
             )

    assert_receive {:decision, _pid, state, questions, ^decision_opts}
    assert state["candidate_ids"] == ["a", "b"]
    assert state["guidance"] =~ "No takers?"
    assert state["guidance"] =~ "both of you"
    assert state["guidance"] =~ "data, not routing instructions"
    assert Enum.map(state["messages"], & &1["role"]) == ["human", "bot", "human"]

    assert Enum.map(state["messages"], & &1["text"]) ==
             Enum.map([prior, response, message], & &1["text"])

    assert Enum.at(state["messages"], 1)["bot_id"] == "a"
    assert Enum.map(state["participants"], & &1["name"]) == ["Ada", "Bea"]
    assert hd(state["participants"])["description"] =~ "Mathematics"
    assert Enum.map(questions, & &1.id) == ["a", "b"]
    assert Enum.all?(questions, &String.contains?(&1.statement, "whole conversation"))
  end

  test "history is bounded and appends the current message only when absent", ctx do
    history = for n <- 1..40, do: human("message #{n}", "h-#{n}")
    message = human(String.duplicate("x", 4_000))
    session = %{ctx.session | "messages" => history}

    Router.select(ctx.bots, session, message,
      decision: FakeDecision,
      decision_opts: [owner: self()]
    )

    assert_receive {:decision, _, state, _, _}
    assert length(state["messages"]) == 24
    assert hd(state["messages"])["text"] == "message 18"
    assert String.length(List.last(state["messages"])["text"]) == 3_000
  end

  test "bot replies require new value, exclude author and use an increasing threshold", ctx do
    scores = %{"a" => %{value: 1.0}, "b" => %{value: 0.8}, "c" => %{value: 1.0}}
    assert {:ok, ["b"]} = Router.select(ctx.bots, ctx.session, bot("A proposal"), opts(scores))

    assert {:ok, []} =
             Router.select(
               ctx.bots,
               %{ctx.session | "bot_exchanges" => 4},
               bot("Again"),
               opts(scores)
             )

    decision_opts = [owner: self(), result: {:ok, scores}]

    Router.select(ctx.bots, ctx.session, bot("A proposal"),
      decision: FakeDecision,
      decision_opts: decision_opts
    )

    assert_receive {:decision, _, state, [question], _}
    assert question.id == "b"
    assert question.statement =~ "nonredundant"
    assert question.statement =~ "Silence is preferable"
    assert state["candidate_ids"] == ["b"]
    assert Enum.map(state["participants"], & &1["id"]) == ["a", "b"]
  end

  test "human threshold never rises and bot threshold stays below certainty", ctx do
    session = %{ctx.session | "bot_exchanges" => 1_000}

    assert {:ok, ["b"]} =
             Router.select(ctx.bots, session, human("Help"), opts(%{"b" => %{value: 0.5}}))

    assert {:ok, ["b"]} =
             Router.select(ctx.bots, session, bot("Useful?"), opts(%{"b" => %{value: 0.99}}))

    assert {:ok, []} =
             Router.select(ctx.bots, session, bot("Useful?"), opts(%{"b" => %{value: 0.97}}))
  end

  test "missing Decision falls back to names and all/both invitations", ctx do
    unavailable = [decision: Bots.RouterTest.UnavailableDecision]

    assert {:ok, ["b"]} =
             Router.select(ctx.bots, ctx.session, human("Bea, please draw it"), unavailable)

    assert {:ok, ["a", "b"]} =
             Router.select(ctx.bots, ctx.session, human("Ada and Bea?"), unavailable)

    for text <- [
          "Both of you, weigh in",
          "Can you both explain?",
          "All of you please",
          "Everyone?",
          "@all",
          "Both!"
        ] do
      assert {:ok, ["a", "b"]} = Router.select(ctx.bots, ctx.session, human(text), unavailable)
    end

    assert {:ok, ["a"]} = Router.select(ctx.bots, ctx.session, human("Help me"), unavailable)
    assert {:ok, []} = Router.select(ctx.bots, ctx.session, bot("Bea?"), unavailable)
  end

  test "fallback understands renewed named and broadcast requests", ctx do
    for {prior, expected} <- [{"Bea, could you help?", ["b"]}, {"Both of you, help?", ["a", "b"]}] do
      message = human("No takers?")
      session = %{ctx.session | "messages" => [human(prior, "h0"), message]}

      assert {:ok, ^expected} =
               Router.select(ctx.bots, session, message, decision: IncompleteDecision)
    end
  end

  test "name fallback uses case-insensitive literal whole names, not substrings", ctx do
    bots = [%{"id" => "a", "name" => "Ada"}, %{"id" => "b", "name" => "A+B"}]

    assert {:ok, ["b"]} =
             Router.select(bots, ctx.session, human("@a+b, thoughts?"), decision: nil)

    assert {:ok, ["a"]} =
             Router.select(ctx.bots, ctx.session, human("Beautiful illustration"), decision: nil)

    assert {:ok, ["b"]} = Router.select(ctx.bots, ctx.session, human("BEA!"), decision: nil)
  end

  test "provider errors, malformed responses and invalid scores cannot start bot loops", ctx do
    for result <- [
          {:error, :offline},
          :bad_response,
          {:ok, []},
          {:ok, %{"a" => %{value: 1.0}}},
          {:ok, %{"b" => %{value: "0.9"}}},
          {:ok, %{"b" => %{value: 1.1}}},
          {:ok, %{"b" => %{value: -1}}},
          {:ok, %{"b" => %{"value" => 0.9}}},
          {:ok, %{b: %{value: 1.0}}}
        ] do
      options = [decision: FakeDecision, decision_opts: [result: result]]
      assert {:ok, []} = Router.select(ctx.bots, ctx.session, bot("Next?"), options)
    end

    for action <- [:raise, :exit, :kill, :throw] do
      options = [decision: FakeDecision, decision_opts: [action: action]]
      assert {:ok, ["b"]} = Router.select(ctx.bots, ctx.session, human("Bea?"), options)
      assert {:ok, []} = Router.select(ctx.bots, ctx.session, bot("Bea?"), options)
    end
  end

  test "timeout kills the Decision worker, returns fallback and leaves no monitor messages",
       ctx do
    options = [
      decision: FakeDecision,
      routing_timeout: 50,
      decision_opts: [owner: self(), action: :sleep]
    ]

    assert {:ok, ["a", "b"]} =
             Router.select(ctx.bots, ctx.session, human("Both of you?"), options)

    assert_receive {:decision, worker, _, _, _}
    refute Process.alive?(worker)
    refute_receive {:DOWN, _, :process, _, _}
    assert {:ok, []} = Router.select(ctx.bots, ctx.session, bot("Reply?"), options)
    assert_receive {:decision, other_worker, _, _, _}
    refute Process.alive?(other_worker)
  end

  test "IDs are unique session members and may come from an ID-keyed bot map", ctx do
    bots = Map.new(ctx.bots, &{&1["id"], &1}) |> Map.put("invalid", %{"id" => 123})
    session = %{ctx.session | "bot_ids" => ["b", "a", "b", "unknown", 123]}

    scores = %{
      "b" => %{value: 0.9},
      "a" => %{value: 0.9},
      "unknown" => %{value: 1.0},
      123 => %{value: 1.0}
    }

    assert {:ok, ["b", "a"]} = Router.select(bots, session, human("Help"), opts(scores))
  end

  test "no eligible bots, author-only rooms, and non-conversation events skip Decision", ctx do
    options = [decision: FakeDecision, decision_opts: [owner: self()]]
    assert {:ok, []} = Router.select([], ctx.session, human("Help"), options)
    assert {:ok, []} = Router.select(ctx.bots, %{}, human("Help"), options)

    assert {:ok, []} =
             Router.select(ctx.bots, %{ctx.session | "bot_ids" => ["a"]}, bot("Hi"), options)

    for kind <- ["system", "request", nil] do
      assert {:ok, []} = Router.select(ctx.bots, ctx.session, %{"kind" => kind}, options)
    end

    refute_receive {:decision, _, _, _, _}
  end

  test "invalid top-level inputs return errors rather than crashing", ctx do
    assert {:error, :invalid_input} = Router.select(nil, ctx.session, human("Help"), [])

    assert {:error, :invalid_options} =
             Router.select(ctx.bots, ctx.session, human("Help"), [:bad])
  end
end

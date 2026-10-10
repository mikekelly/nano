defmodule Nano.Bots.MemoryTest do
  use ExUnit.Case, async: true
  alias Nano.Bots
  alias Nano.Bots.Memory

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "altair-memory-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    store = start_supervised!({Bots.Store, [name: nil, store_dir: dir, pubsub: nil]})
    opts = [server: store]
    {:ok, bot} = Bots.create_bot(%{name: "Mira", voice: "Dry wit"}, opts)
    {:ok, other} = Bots.create_bot(%{name: "Other"}, opts)
    %{opts: opts, bot: bot, other: other}
  end

  defp decision(fun) do
    [
      api_key: "fake",
      transport: fn request ->
        answers =
          Map.new(request.body["questions"], fn {id, _} ->
            {id, %{"type" => "noul", "noul" => fun.(id, request.body["state"])}}
          end)

        {:ok, %{status: 200, body: %{"model" => "fake", "answers" => answers}}}
      end
    ]
  end

  defp remember(bot, text, opts),
    do: Memory.remember(bot.id, text, %{session_id: "old", message_id: "source"}, opts)

  test "relevant preference only, provenance and bot boundaries", c do
    {:ok, relevant} = remember(c.bot, "Prefers trains", c.opts)
    {:ok, _} = remember(c.bot, "Owns a blue mug", c.opts)
    {:ok, _} = remember(c.other, "PRIVATE OTHER BOT", c.opts)

    transport =
      decision(fn id, state ->
        refute state =~ "PRIVATE OTHER BOT"
        if id == "1", do: 0.99, else: 0.1
      end)

    assert {:ok, [^relevant]} =
             Memory.retrieve(
               c.bot.id,
               "How should I travel?",
               c.opts ++ [decision_opts: transport]
             )

    assert relevant.provenance == %{session_id: "old", message_id: "source"}
  end

  test "hard item and full provenance byte budgets", c do
    for i <- 1..25, do: remember(c.bot, "Fact #{i}", c.opts)
    opts = c.opts ++ [decision_opts: decision(fn _, _ -> 1 end)]
    assert {:ok, records} = Memory.retrieve(c.bot.id, "facts", opts ++ [limit: 3])
    assert length(records) == 3
    budget = byte_size(Memory.render(hd(records))) + 1
    assert {:ok, few} = Memory.retrieve(c.bot.id, "facts", opts ++ [byte_budget: budget])
    assert Enum.sum(Enum.map(few, &(byte_size(Memory.render(&1)) + 1))) <= budget
    assert {:ok, []} = Memory.retrieve(c.bot.id, "facts", opts ++ [byte_budget: 1])
    assert {:error, :invalid_options} = Memory.retrieve(c.bot.id, "facts", opts ++ [limit: 201])
  end

  test "bounded candidates/query/context and oversized record skipped", c do
    {:ok, _} = remember(c.bot, String.duplicate("huge", 10000), c.opts)

    assert {:ok, []} =
             Memory.retrieve(
               c.bot.id,
               "huge",
               c.opts ++
                 [
                   decision_opts:
                     decision(fn _, _ -> flunk("oversized candidate must be skipped") end)
                 ]
             )

    for i <- 1..205, do: remember(c.bot, "Fact #{i}", c.opts)
    assert {:ok, all} = Bots.list_memories(c.bot.id, c.opts ++ [limit: 200])
    assert length(all) == 200

    transport =
      decision(fn _, state ->
        assert byte_size(state) < 40000
        refute state =~ String.duplicate("Q", 2001)
        refute state =~ String.duplicate("C", 4001)
        1
      end)

    assert {:ok, _} =
             Memory.retrieve(
               c.bot.id,
               String.duplicate("Q", 10000),
               c.opts ++ [context: String.duplicate("C", 10000), decision_opts: transport]
             )
  end

  test "failure is explicit and yields no fake relevance", c do
    remember(c.bot, "Prefers trains", c.opts)

    assert {:error, {:relevance_unavailable, :missing_api_key}} =
             Memory.retrieve(c.bot.id, "travel", c.opts ++ [decision_opts: [api_key: nil]])

    assert {:error, {:relevance_unavailable, :transport_error}} =
             Memory.retrieve(
               c.bot.id,
               "travel",
               c.opts ++
                 [decision_opts: [api_key: "fake", transport: fn _ -> {:error, :offline} end]]
             )
  end

  test "human edits and deletion remain authoritative", c do
    {:ok, r} = remember(c.bot, "Prefers trains", c.opts)
    assert {:error, :missing_provenance} = Memory.remember(c.bot.id, "fact", %{}, c.opts)

    {:ok, edited} =
      Bots.update_memory(
        r.id,
        %{text: "Prefers buses", provenance: %{session_id: "new", message_id: "correction"}},
        c.opts
      )

    opts = c.opts ++ [decision_opts: decision(fn _, _ -> 1 end)]
    assert {:ok, [^edited]} = Memory.retrieve(c.bot.id, "travel", opts)
    assert {:ok, ^edited} = Bots.delete_memory(r.id, c.opts)
    assert {:ok, []} = Memory.retrieve(c.bot.id, "travel", opts)
  end
end

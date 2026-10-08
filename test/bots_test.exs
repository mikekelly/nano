defmodule BotsTest.Runtime do
  def dispatch(bot, session, context, opts) do
    send(opts[:observer], {:dispatch, bot, session, context})

    case opts[:runtime_result] do
      :crash -> raise "scripted runtime failure"
      nil -> :ok
      result -> result
    end
  end

  def stop(bot, session, opts), do: send(opts[:observer], {:stopped, bot["id"], session["id"]})
end

defmodule BotsTest.Router do
  def select(bots, session, message, opts) do
    if opts[:route_observer], do: send(opts[:observer], {:routing, message["text"], self()})
    if opts[:route_delay], do: Process.sleep(opts[:route_delay])

    case opts[:routing] do
      :crash ->
        raise "scripted decision failure"

      :none ->
        {:ok, []}

      :all ->
        {:ok, Enum.map(bots, & &1["id"])}

      :conversation ->
        send(opts[:observer], {:conversation, session["messages"]})
        {:ok, Enum.map(bots, & &1["id"])}

      _ ->
        {:ok, if(message["kind"] == "human", do: [hd(bots)["id"]], else: [])}
    end
  end
end

defmodule BotsTest.NoDecision do
  def noul(id, text), do: {id, text}
  def ask(_, _, _), do: {:error, :offline}
end

defmodule BotsTest do
  use ExUnit.Case, async: true

  defp service(opts \\ []) do
    root =
      Path.join(
        System.tmp_dir!(),
        "bots-core-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    opts =
      Keyword.merge(
        [
          name: nil,
          root: root,
          runtime: BotsTest.Runtime,
          router: BotsTest.Router,
          observer: self(),
          outbox_interval: 60_000,
          decision: BotsTest.NoDecision
        ],
        opts
      )

    {:ok, server} = Bots.start_link(opts)
    Process.unlink(server)
    Bots.snapshot(server: server)

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
      File.rm_rf(root)
    end)

    %{server: server, root: root, start_opts: opts}
  end

  defp bot(s, name \\ "Mira") do
    {:ok, bot} = Bots.create_bot(%{name: name, description: "Helpful " <> name}, server: s.server)
    bot
  end

  defp chat(s, bots) do
    {:ok, session} = Bots.create_session(Enum.map(bots, & &1["id"]), server: s.server)
    session
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  test "identities, sessions, string-key contracts, preferences and history survive service restart" do
    s = service()
    b = bot(s)
    c = chat(s, [b])

    assert {:ok, prefs} =
             Bots.preferences(%{notifications: true, cooldown_seconds: 60, max_per_hour: 2},
               server: s.server
             )

    {:ok, human} = Bots.say(c["id"], "hello", server: s.server)
    assert_receive {:dispatch, ^b, _, ctx}, 1000
    assert ctx.conversation == [human]
    assert {:ok, output} = Bots.post(ctx.token, "Hello **friend**", server: s.server)
    eventually(fn -> Bots.session(c["id"], server: s.server)["status"] == "idle" end)
    GenServer.stop(s.server)
    {:ok, server} = Bots.start_link(s.start_opts)
    Process.unlink(server)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    snapshot = Bots.snapshot(server: server)
    assert snapshot["bots"] == [b]
    assert snapshot["preferences"] == prefs
    assert Bots.session(c["id"], server: server)["messages"] == [human, output]
    assert Enum.all?(Map.keys(b), &is_binary/1)
    assert Bitwise.band(File.stat!(Path.join(s.root, "state.json")).mode, 0o777) == 0o600
  end

  test "test instances and PubSub topics are isolated" do
    a = service()
    b = service()
    :ok = Bots.subscribe(server: a.server)
    bot_a = bot(a)
    assert_receive {:bots_changed, nil}
    assert Bots.snapshot(server: b.server)["bots"] == []
    bot(b)
    refute_receive {:bots_changed, _}, 30
    c = chat(a, [bot_a])
    assert_receive {:bots_changed, _}
    Bots.say(c["id"], "hi", server: a.server)
    assert_receive {:dispatch, _, _, ctx}, 1000
    assert {:error, :stale_token} = Bots.post(ctx.token, "wrong service", server: b.server)
    assert {:ok, _} = Bots.post(ctx.token, "right service", server: a.server)
  end

  test "only explicit posts appear, grants are single-use, and sessions do not leak" do
    s = service()
    b = bot(s)
    a = chat(s, [b])
    other = chat(s, [b])
    Bots.say(a["id"], "private a", server: s.server)
    assert_receive {:dispatch, _, _, ca}, 1000
    Bots.say(other["id"], "private b", server: s.server)
    assert_receive {:dispatch, _, _, cb}, 1000
    assert Enum.map(ca.conversation, & &1["text"]) == ["private a"]
    assert Enum.map(cb.conversation, & &1["text"]) == ["private b"]
    send(s.server, {:harness, "eval noise must stay out"})
    assert {:ok, msg} = Bots.post(ca.token, "answer a", server: s.server)
    assert msg["bot_id"] == b["id"]
    assert {:error, :stale_token} = Bots.post(ca.token, "duplicate", server: s.server)
    assert length(Bots.session(other["id"], server: s.server)["messages"]) == 1
    assert length(Bots.session(a["id"], server: s.server)["messages"]) == 2
  end

  test "human message revokes stale response and sees all pending human conversation" do
    s = service()
    c = chat(s, [bot(s)])
    Bots.say(c["id"], "first", server: s.server)
    assert_receive {:dispatch, _, _, first}, 1000
    Bots.say(c["id"], "No takers?", server: s.server)
    assert_receive {:dispatch, _, _, second}, 1000
    assert {:error, :stale_token} = Bots.post(first.token, "stale", server: s.server)
    assert Enum.map(second.conversation, & &1["text"]) == ["first", "No takers?"]
    assert {:ok, _} = Bots.post(second.token, "Both questions answered", server: s.server)
  end

  test "routing never blocks service and stale decisions cannot starve a newer human" do
    s = service(route_delay: 100, route_observer: true)
    c = chat(s, [bot(s)])
    Bots.say(c["id"], "old", server: s.server)
    assert_receive {:routing, "old", worker}
    started = System.monotonic_time(:millisecond)
    assert Bots.snapshot(server: s.server)["sessions"] != []
    assert System.monotonic_time(:millisecond) - started < 80
    Bots.say(c["id"], "new", server: s.server)
    assert_receive {:routing, "new", _}
    eventually(fn -> not Process.alive?(worker) end)
    assert_receive {:dispatch, _, _, ctx}, 1000
    assert ctx.message["text"] == "new"
    refute_receive {:dispatch, _, _, _}, 150
  end

  test "route outage, abstention and timeout each guarantee a human responder" do
    for opts <- [[routing: :crash], [routing: :none], [route_delay: 200, routing_timeout: 20]] do
      s = service(opts)
      c = chat(s, [bot(s)])
      Bots.say(c["id"], "anyone?", server: s.server)
      assert_receive {:dispatch, _, _, ctx}, 1000
      assert ctx.message["text"] == "anyone?"
      Bots.post(ctx.token, "Yes", server: s.server)
    end
  end

  test "all group members observe all messages, even those not previously selected" do
    s = service(routing: :conversation, max_bot_exchanges: 2)
    a = bot(s, "A")
    b = bot(s, "B")
    c = chat(s, [a, b])
    Bots.say(c["id"], "both of you debate", server: s.server)
    assert_receive {:dispatch, first, _, ctx1}, 1000
    assert_receive {:dispatch, second, _, ctx2}, 1000
    assert MapSet.new([first["id"], second["id"]]) == MapSet.new([a["id"], b["id"]])
    Bots.post(ctx1.token, "First perspective", server: s.server)
    Bots.post(ctx2.token, "Second perspective", server: s.server)
    assert_receive {:dispatch, _, _, follow}, 1000

    assert Enum.map(follow.conversation, & &1["text"]) == [
             "both of you debate",
             "First perspective",
             "Second perspective"
           ]

    Bots.post(follow.token, "A useful reply", server: s.server)
    assert_receive {:dispatch, _, _, last}, 1000
    Bots.post(last.token, "Conclusion", server: s.server)

    eventually(fn ->
      Enum.any?(
        Bots.session(c["id"], server: s.server)["messages"],
        &String.contains?(&1["text"], "limit reached")
      )
    end)

    refute_receive {:dispatch, _, _, _}, 30
    # Ceiling applies only to bot-to-bot exchanges; the human always gets a fresh turn.
    Bots.say(c["id"], "What about another angle?", server: s.server)
    assert_receive {:dispatch, _, _, _}, 1000
    assert Bots.session(c["id"], server: s.server)["bot_exchanges"] == 0
  end

  test "stop invalidates work, emits status and a human can resume" do
    s = service()
    c = chat(s, [bot(s)])
    Bots.subscribe(server: s.server)
    Bots.say(c["id"], "start", server: s.server)
    assert_receive {:dispatch, _, _, ctx}, 1000
    assert {:ok, stopped} = Bots.stop(c["id"], server: s.server)
    assert stopped["status"] == "stopped"
    assert_receive {:stopped, _, _}, 1000
    assert_receive {:bots_changed, _}
    assert {:error, :stale_token} = Bots.post(ctx.token, "late", server: s.server)
    assert {:error, :stale_token} = Bots.finish(ctx.token, server: s.server)
    Bots.say(c["id"], "continue", server: s.server)
    assert_receive {:dispatch, _, _, resumed}, 1000
    assert resumed.token != ctx.token
  end

  test "runtime exceptions and response timeouts visibly finish thinking" do
    for opts <- [[runtime_result: :crash], [response_timeout: 20]] do
      s = service(opts)
      c = chat(s, [bot(s)])
      Bots.say(c["id"], "hello", server: s.server)
      assert_receive {:dispatch, _, _, ctx}, 1000
      eventually(fn -> Bots.session(c["id"], server: s.server)["status"] == "error" end)
      assert List.last(Bots.session(c["id"], server: s.server)["messages"])["kind"] == "system"
      assert {:error, :stale_token} = Bots.post(ctx.token, "too late", server: s.server)
    end
  end

  test "finish without posting surfaces a failure instead of silent starvation" do
    s = service()
    c = chat(s, [bot(s)])
    Bots.say(c["id"], "hello", server: s.server)
    assert_receive {:dispatch, _, _, ctx}, 1000
    assert {:ok, session} = Bots.finish(ctx.token, server: s.server)
    assert session["status"] == "error"
    assert List.last(session["messages"])["text"] =~ "without a reply"
  end

  test "restart recovers unanswered humans and revokes pre-restart tokens" do
    s = service()
    c = chat(s, [bot(s)])
    Bots.say(c["id"], "still waiting", server: s.server)
    assert_receive {:dispatch, _, _, old}, 1000
    Process.exit(s.server, :kill)
    eventually(fn -> not Process.alive?(s.server) end)
    {:ok, server} = Bots.start_link(s.start_opts)
    Process.unlink(server)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert_receive {:dispatch, _, _, new}, 1000
    assert new.message["text"] == "still waiting"
    assert {:error, :stale_token} = Bots.post(old.token, "old", server: server)
    assert {:ok, _} = Bots.post(new.token, "recovered", server: server)
  end

  test "request answers transition once, remain durable, and replay until acknowledged" do
    s = service()
    b = bot(s)

    {:ok, request} =
      Bots.request(b["id"], "Choose a region",
        requester: self(),
        idempotency_key: "region",
        server: s.server
      )

    assert {:ok, ^request} =
             Bots.request(b["id"], "Retry",
               requester: self(),
               idempotency_key: "region",
               server: s.server
             )

    rid = request["id"]
    assert Bots.session(request["session_id"], server: s.server)["messages"] |> length() == 1
    assert {:ok, answer} = Bots.reply(rid, "Europe", server: s.server)
    assert answer["status"] == "answered"
    assert_receive {:bots_answer, ^rid, "Europe"}
    assert {:error, :already_answered} = Bots.reply(rid, "Asia", server: s.server)
    refute_receive {:bots_answer, _, _}, 30
    GenServer.stop(s.server)
    {:ok, server} = Bots.start_link(s.start_opts)
    Process.unlink(server)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert_receive {:bots_answer, ^rid, "Europe"}
    assert {:ok, %{"status" => "delivered"}} = Bots.ack(rid, server: server)
    send(server, :outbox)
    refute_receive {:bots_answer, _, _}, 30
    assert Bots.request_status(rid, server: server)["answer"] == "Europe"
  end

  test "concurrent replies have only one winner" do
    s = service()
    b = bot(s)
    {:ok, request} = Bots.request(b["id"], "Pick", requester: self(), server: s.server)

    results =
      1..12
      |> Task.async_stream(fn n -> Bots.reply(request["id"], "#{n}", server: s.server) end)
      |> Enum.map(&elem(&1, 1))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_answered})) == 11
    assert_receive {:bots_answer, _, _}
    refute_receive {:bots_answer, _, _}, 30
  end

  test "request session is right bot's latest direct chat, pending survives restart" do
    s = service()
    a = bot(s, "A")
    b = bot(s, "B")
    c = chat(s, [a])
    other = chat(s, [b])

    {:ok, req} =
      Bots.request(a["id"], "Need credential", requester: "stable-agent", server: s.server)

    assert req["session_id"] == c["id"]

    assert {:error, :bot_not_in_session} =
             Bots.request(a["id"], "Wrong room",
               requester: self(),
               session_id: other["id"],
               server: s.server
             )

    GenServer.stop(s.server)
    {:ok, server} = Bots.start_link(s.start_opts)
    Process.unlink(server)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert Bots.request_status(req["id"], server: server)["status"] == "pending"
    assert List.last(Bots.session(c["id"], server: server)["messages"])["request_id"] == req["id"]
  end

  test "notification preference, cooldown, hourly budget and restart persist" do
    s = service()
    b = bot(s)
    Bots.subscribe(server: s.server)
    Bots.request(b["id"], "Silent by default", requester: self(), server: s.server)
    refute_receive {:bots_notification, _}, 30

    Bots.preferences(%{notifications: true, cooldown_seconds: 60, max_per_hour: 1},
      server: s.server
    )

    {:ok, req} = Bots.request(b["id"], "Action needed", requester: self(), server: s.server)
    assert_receive {:bots_notification, notice}
    assert notice.session_id == req["session_id"]
    assert notice.body == "Action needed"
    Bots.request(b["id"], "No second interruption", requester: self(), server: s.server)
    refute_receive {:bots_notification, _}, 30
    GenServer.stop(s.server)
    {:ok, server} = Bots.start_link(s.start_opts)
    Process.unlink(server)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    Bots.request(b["id"], "Still budgeted", requester: self(), server: server)
    refute_receive {:bots_notification, _}, 30
  end

  test "memory remains per bot across isolated sessions with relevant bounded retrieval" do
    s = service()
    a = bot(s, "A")
    b = bot(s, "B")
    c = chat(s, [a])
    Bots.say(c["id"], "I prefer vegetarian food", server: s.server)
    assert_receive {:dispatch, _, _, ctx}, 1000

    assert {:ok, _} =
             Bots.remember(ctx.token, "food", "Person prefers vegetarian food", server: s.server)

    assert {:error, :invalid_memory} =
             Bots.remember(ctx.token, "huge", String.duplicate("x", 4000), server: s.server)

    Bots.post(ctx.token, "Remembered", server: s.server)
    assert {:error, :stale_token} = Bots.remember(ctx.token, "late", "fact", server: s.server)
    another = chat(s, [a])
    Bots.say(another["id"], "Recommend food", server: s.server)
    assert_receive {:dispatch, _, _, recalled}, 1000

    assert [%{"key" => "food", "fact" => %{"value" => "Person prefers vegetarian food"}}] =
             recalled.memories

    assert Enum.map(recalled.conversation, & &1["text"]) == ["Recommend food"]
    other_bot = chat(s, [b])
    Bots.say(other_bot["id"], "Recommend food", server: s.server)
    assert_receive {:dispatch, _, _, isolated}, 1000
    assert isolated.memories == []
  end

  test "invalid inputs fail without crashing or mutating state" do
    s = service()

    for attrs <- [
          nil,
          17,
          [:bad],
          %{name: " "},
          %{name: String.duplicate("x", 81)},
          %{name: 4},
          %{{:tuple, :key} => "x"}
        ] do
      assert {:error, :invalid_name} = Bots.create_bot(attrs, server: s.server)
    end

    b = bot(s)

    for ids <- [[], nil, ["missing"], [b["id"] | Enum.to_list(1..13)]] do
      assert {:error, :invalid_participants} = Bots.create_session(ids, server: s.server)
    end

    c = chat(s, [b])

    for text <- [nil, 1, "", "  ", String.duplicate("x", 50_001)] do
      assert {:error, :invalid_text} = Bots.say(c["id"], text, server: s.server)
    end

    assert {:error, :invalid_attachments} =
             Bots.say(c["id"], "x", attachments: [%{path: "/etc/passwd"}], server: s.server)

    assert {:error, :invalid_preferences} =
             Bots.preferences(%{cooldown_seconds: 0}, server: s.server)

    assert Bots.session(c["id"], server: s.server)["messages"] == []
  end

  test "a corrupt store is not silently discarded, and duplicate root cannot race writes" do
    s = service()
    owner = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(owner, {:duplicate_result, Bots.start_link(s.start_opts)})
    end)

    assert_receive {:duplicate_result, {:error, :bots_root_in_use}}
    # Failed start_link sends EXIT to the caller; use an isolated process for corrupt startup.
    GenServer.stop(s.server)
    File.write!(Path.join(s.root, "state.json"), "broken")
    parent = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(parent, {:start_result, Bots.start_link(s.start_opts)})
    end)

    assert_receive {:start_result, {:error, :invalid_bots_store}}
    assert File.read!(Path.join(s.root, "state.json")) == "broken"
  end

  test "write failure returns an error without publishing or updating in-memory identity" do
    s = service()
    # Replacing the root with a file is deterministic even when tests run as root.
    File.rm_rf!(s.root)
    File.write!(s.root, "not a directory")
    assert {:error, {:persistence, _}} = Bots.create_bot(%{name: "Not saved"}, server: s.server)
    assert Bots.snapshot(server: s.server)["bots"] == []
  end
end

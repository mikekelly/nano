defmodule Seedling.BotsTest do
  use ExUnit.Case, async: true
  alias Seedling.Bots

  setup do
    root =
      Path.join(System.tmp_dir!(), "bots-test-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

    File.mkdir_p!(root)
    File.write!(Path.join(root, "test-owner"), :erlang.term_to_binary(self()))
    {:ok, server} = Bots.start_link(root: root, runtime: Bots.TestRuntime, gate: Bots.TestGate)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, bot} = Bots.create_bot("Muse", server: server, description: "Trip helper")
    {:ok, second} = Bots.create_bot("Dots", server: server)
    %{root: root, server: server, opts: [server: server], bot: bot["id"], second: second["id"]}
  end

  defp session(ctx, ids), do: elem(Bots.create_session(ids, ctx.opts), 1)["id"]

  defp post(ctx, pid, bid, sid, text) do
    send(pid, {:post, self(), bid, sid, text, ctx.opts})
    assert_receive {:posted, result}
    result
  end

  test "identity survives restart; contexts are per pair; selective memories cross sessions",
       ctx do
    sid = session(ctx, [ctx.bot])
    {:ok, _} = Bots.remember(ctx.bot, "Prefers quiet hotels", ctx.opts ++ [tags: ["travel"]])
    {:ok, _} = Bots.remember(ctx.bot, "Has a cat named Kiwi", ctx.opts ++ [tags: ["pets"]])
    {:ok, _} = Bots.say(sid, "Find quiet hotels", ctx.opts)
    assert_receive {:delivered, bid, ^sid, _, memories, pid}
    assert bid == ctx.bot
    assert [%{"text" => "Prefers quiet hotels"}] = memories
    assert {:error, _} = Bots.post(ctx.bot, sid, "forged", ctx.opts)
    assert {:ok, _} = post(ctx, pid, ctx.bot, sid, "Here are hotels")
    other = session(ctx, [ctx.bot])
    {:ok, _} = Bots.say(other, "More quiet hotels", ctx.opts)
    assert_receive {:delivered, ^bid, ^other, _, [_], other_pid}
    refute pid == other_pid
    {:ok, page} = Bots.history(other, ctx.opts)
    assert Enum.map(page.messages, & &1["text"]) == ["More quiet hotels"]
    GenServer.stop(ctx.server)

    {:ok, restarted} =
      Bots.start_link(root: ctx.root, runtime: Bots.TestRuntime, gate: Bots.TestGate)

    {:ok, snapshot} = Bots.snapshot(server: restarted)
    assert Enum.any?(snapshot.bots, &(&1["id"] == ctx.bot and &1["name"] == "Muse"))

    assert {:ok, %{memories: [%{"text" => "Prefers quiet hotels"}]}} =
             Bots.memories(ctx.bot, "quiet hotels", server: restarted)
  end

  test "shared conversation reaches peers, increasing exchanges have a visible ceiling and human resets",
       ctx do
    sid = session(ctx, [ctx.bot, ctx.second])
    {:ok, _} = Bots.configure(%{exchange_ceiling: 2}, ctx.opts)
    {:ok, _} = Bots.say(sid, "Let's plan", ctx.opts)
    assert_receive {:delivered, b1, ^sid, _, _, p1}
    assert_receive {:delivered, b2, ^sid, _, _, p2}
    assert MapSet.new([b1, b2]) == MapSet.new([ctx.bot, ctx.second])
    assert {:ok, _} = post(ctx, p1, b1, sid, "A new idea")
    assert_receive {:delivered, ^b2, ^sid, %{"from" => ^b1, "text" => "A new idea"}, _, ^p2}
    assert {:ok, _} = post(ctx, p2, b2, sid, "Another idea")
    assert {:error, _} = post(ctx, p1, b1, sid, "Loop")
    {:ok, page} = Bots.history(sid, ctx.opts)
    assert List.last(page.messages)["text"] =~ "limit reached"
    {:ok, _} = Bots.say(sid, "Continue please", ctx.opts)
    assert {:ok, _} = post(ctx, p1, b1, sid, "Resumed")
    {:ok, _} = Bots.stop(sid, ctx.opts)
    assert {:error, _} = post(ctx, p2, b2, sid, "Stopped")
  end

  test "quiet gates avoid delivery and status can be cleared", ctx do
    sid = session(ctx, [ctx.bot])
    {:ok, _} = Bots.say(sid, "silent", ctx.opts)
    refute_receive {:delivered, _, _, _, _, _}, 50
    {:ok, _} = Bots.say(sid, "Hello", ctx.opts)
    assert_receive {:delivered, _, _, _, _, pid}
    send(pid, {:quiet, self(), ctx.bot, sid, ctx.opts})
    assert_receive {:quieted, {:ok, "quiet"}}
    {:ok, snap} = Bots.snapshot(ctx.opts)
    assert snap.statuses[{sid, ctx.bot}] == "quiet"
  end

  test "answerable requests persist, route to right session and reply with correlation exactly once after ack",
       ctx do
    sid = session(ctx, [ctx.bot])

    {:ok, req} =
      Bots.ask_human(
        ctx.bot,
        "Choose a destination",
        ctx.opts ++ [reply_to: self(), correlation: "trip"]
      )

    assert req["session"] == sid
    assert {:ok, _} = Bots.answer(req["id"], "Kyoto", ctx.opts)
    rid = req["id"]
    assert_receive {:bots_human_answer, ^rid, "trip", "Kyoto"}
    assert {:error, _} = Bots.answer(rid, "Again", ctx.opts)
    assert {:ok, ^rid} = Bots.ack(rid, ctx.opts)
    send(ctx.server, :retry_answers)
    refute_receive {:bots_human_answer, ^rid, _, _}, 50
    {:ok, snap} = Bots.snapshot(ctx.opts)
    assert [%{"state" => "delivered"}] = snap.requests
    refute Map.has_key?(hd(snap.requests), "reply_to")
  end

  test "requests without sessions create one; cancellation and expiry are actionable", ctx do
    {:ok, req} = Bots.ask_human(ctx.second, "Need a human", ctx.opts)
    {:ok, page} = Bots.history(req["session"], ctx.opts)
    assert hd(page.messages)["request"] == req["id"]
    assert {:ok, _} = Bots.cancel_request(req["id"], ctx.opts)
    assert {:error, e} = Bots.answer(req["id"], "late", ctx.opts)
    assert e =~ "cancelled"
    {:ok, expired} = Bots.ask_human(ctx.bot, "Soon", ctx.opts ++ [expires_in: 1])
    Process.sleep(1010)
    assert {:error, e} = Bots.answer(expired["id"], "late", ctx.opts)
    assert e =~ "expired"
  end

  test "notification budgets are durable and default off", ctx do
    sid = session(ctx, [ctx.bot])
    {:ok, req} = Bots.ask_human(ctx.bot, "First", ctx.opts)
    refute req["notify"]

    assert {:ok, _} =
             Bots.notification_limits(
               sid,
               %{enabled: true, per_hour: 1, cooldown_seconds: 0},
               ctx.opts
             )

    {:ok, req} = Bots.ask_human(ctx.bot, "Second", ctx.opts)
    assert req["notify"]
    {:ok, req} = Bots.ask_human(ctx.bot, "Third", ctx.opts)
    refute req["notify"]
    assert {:error, _} = Bots.notification_limits(sid, %{per_hour: 31}, ctx.opts)
  end

  test "bounded history and attachments refuse unknown refs, paths and oversized messages", ctx do
    sid = session(ctx, [ctx.bot])
    for i <- 1..5, do: Bots.say(sid, "silent #{i}", ctx.opts)
    {:ok, page} = Bots.history(sid, ctx.opts ++ [limit: 2])
    assert page.truncated and page.notice =~ "Earlier"
    assert Enum.map(page.messages, & &1["text"]) == ["silent 4", "silent 5"]
    {:ok, older} = Bots.history(sid, ctx.opts ++ [limit: 2, before: page.before])
    assert Enum.map(older.messages, & &1["text"]) == ["silent 2", "silent 3"]
    assert {:error, _} = Bots.history(sid, ctx.opts ++ [before: "unknown"])
    assert {:error, _} = Bots.say(sid, String.duplicate("x", 8001), ctx.opts)
    assert {:error, _} = Bots.say(sid, "file", ctx.opts ++ [attachments: ["/etc/passwd"]])
    path = Path.join(ctx.root, "evil.html")
    File.write!(path, "<script>alert(1)</script>")
    {:ok, file} = Bots.attach(path, "../../evil.html", ctx.opts)
    assert file["name"] == "evil.html"
    {:ok, stored} = Bots.attachment(file["id"], ctx.opts)
    assert File.read!(stored["path"]) == "<script>alert(1)</script>"
    assert {:ok, _} = Bots.say(sid, "An inert file", ctx.opts ++ [attachments: [file["id"]]])
    assert {:error, _} = Bots.attach(ctx.root, "directory", ctx.opts)
  end

  test "invalid API input is rejected without killing store", ctx do
    assert {:error, _} = Bots.create_bot("", ctx.opts)
    assert {:error, _} = Bots.create_session([ctx.bot, ctx.bot], ctx.opts)
    assert {:error, _} = Bots.create_session(["missing"], ctx.opts)
    assert {:error, _} = Bots.configure(%{api_key: "never"}, ctx.opts)
    assert {:error, _} = Bots.ask_human(ctx.bot, "Question", ctx.opts ++ [reply_to: "bad"])
    assert {:error, _} = Bots.memories(ctx.bot, "query", ctx.opts ++ [limit: 99])
    assert {:ok, _} = Bots.snapshot(ctx.opts)
  end

  test "malformed arguments, dead servers and corrupt identities return errors without replacement",
       ctx do
    assert {:error, _} = Bots.snapshot(:bad)
    assert {:error, _} = Bots.create_bot("Bad", ctx.opts ++ [description: 1])
    assert {:error, _} = Bots.configure(%{{:bad, :key} => 1}, ctx.opts)
    assert {:error, _} = Bots.notification_limits("id", %{{:bad, :key} => 1}, ctx.opts)
    assert {:error, _} = Bots.say("id", %{}, ctx.opts)
    assert {:error, _} = Bots.attach(5, "file", ctx.opts)
    assert {:error, _} = Bots.remember(ctx.bot, "Fact", ctx.opts ++ [session: %{}])
    assert {:error, _} = Bots.ask_human(ctx.bot, "Question", ctx.opts ++ [expires_in: "soon"])
    assert Process.alive?(ctx.server)
    root = Path.join(ctx.root, "broken")
    File.mkdir_p!(root)

    invalid =
      Jason.encode!(%{
        version: 1,
        bots: %{"bad" => nil},
        sessions: %{},
        memories: %{},
        requests: %{},
        attachments: %{},
        config: %{}
      })

    File.write!(Path.join(root, "store.json"), invalid)
    assert {:error, e} = Bots.server(root)
    assert e =~ "valid backup"
    assert {:error, _} = Bots.snapshot(root: root)
    assert File.read!(Path.join(root, "store.json")) == invalid
    GenServer.stop(ctx.server)
    assert {:error, e} = Bots.snapshot(ctx.opts)
    assert e =~ "unavailable"
  end

  test "single-bot proactive messages do not consume a bot-to-bot budget", ctx do
    sid = session(ctx, [ctx.bot])
    {:ok, _} = Bots.configure(%{exchange_ceiling: 1}, ctx.opts)
    {:ok, _} = Bots.say(sid, "Hello", ctx.opts)
    assert_receive {:delivered, _, _, _, _, pid}
    assert {:ok, _} = post(ctx, pid, ctx.bot, sid, "First")
    assert {:ok, _} = post(ctx, pid, ctx.bot, sid, "Second")
    {:ok, snapshot} = Bots.snapshot(ctx.opts)
    assert hd(snapshot.sessions)["exchanges"] == 0
  end
end

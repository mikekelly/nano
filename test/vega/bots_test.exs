defmodule Vega.BotsTest.Runtime do
  def deliver(bot, session, message, root) do
    pid = :global.whereis_name({__MODULE__, root})
    send(pid, {:delivered, bot, session, message})
    :ok
  end

  def notify(name, event) do
    case :global.whereis_name({__MODULE__, name}) do
      :undefined ->
        {:error, :not_found}

      pid ->
        send(pid, event)
        :ok
    end
  end

  def info(_), do: nil
end

defmodule Vega.BotsTest do
  use ExUnit.Case, async: true
  alias Vega.Bots

  setup do
    root = Path.join(System.tmp_dir!(), "vega-bots-test-" <> Vega.Store.id())
    :yes = :global.register_name({Vega.BotsTest.Runtime, root}, self())

    {:ok, pid} =
      start_supervised(
        {Vega.Bots.Server,
         name: {:global, {:bots, root}},
         root: root,
         runtime: Vega.BotsTest.Runtime,
         tick_ms: 20,
         answer_retry_ms: 40}
      )

    on_exit(fn ->
      :global.unregister_name({Vega.BotsTest.Runtime, root})
      File.rm_rf(root)
    end)

    %{root: root, opts: [server: pid], name: {:global, {:bots, root}}}
  end

  defp bot(name, opts) do
    {:ok, bot} =
      Bots.create_bot(
        name,
        opts ++
          [model: "test/model", reasoning: "off", max_context: 16000, max_turns: 0, max_tokens: 0]
      )

    bot
  end

  test "explicit model configuration and stable friendly identity", c do
    assert {:error, :explicit_identity_model_and_limits_required} =
             Bots.create_bot("Muse", c.opts)

    b = bot("Muse", c.opts)
    assert b["face"]["colour"] in ~w(lilac sky peach mint rose gold)
    assert {:ok, ^b} = Bots.get_bot(b["id"], c.opts)
    assert {:ok, next} = Bots.update_bot(b["id"], %{name: "Aster"}, c.opts)
    assert next["face"] == b["face"]
    assert next["id"] == b["id"]
    assert {:error, :invalid_fields} = Bots.update_bot(b["id"], %{id: "evil"}, c.opts)
  end

  test "individual and group contexts stay isolated, all group authors explicit", c do
    a = bot("Muse", c.opts)
    b = bot("Dot", c.opts)
    {:ok, one} = Bots.create_session([a["id"]], c.opts)
    {:ok, group} = Bots.create_session([a["id"], b["id"]], c.opts)
    assert {:error, :invalid_participants} = Bots.create_session([a["id"], a["id"]], c.opts)
    {:ok, input} = Bots.send_message(one["id"], "Private pineapple", c.opts)
    assert_receive {:delivered, ^a, session, ^input}
    assert session["id"] == one["id"]
    {:ok, _} = Bots.send_message(group["id"], "Group adventure", c.opts)
    assert_receive {:delivered, ^a, gs, _}
    assert gs["id"] == group["id"]
    assert_receive {:delivered, ^b, gs, _}
    assert gs["id"] == group["id"]
    assert Bots.agent_name(a["id"], one["id"]) != Bots.agent_name(a["id"], group["id"])
    {:ok, _} = Bots.post(group["id"], b["id"], "I am Dot", c.opts)
    assert {:error, :invalid_message_or_author} = Bots.post(one["id"], b["id"], "wrong", c.opts)
    refute_receive {:delivered, _, _, %{"text" => "I am Dot"}}, 50
    {:ok, one} = Bots.get_session(one["id"], c.opts)
    assert Enum.map(one["messages"], & &1["text"]) == ["Private pineapple"]
    {:ok, group} = Bots.get_session(group["id"], c.opts)
    assert List.last(group["messages"])["author_id"] == b["id"]
  end

  test "posts publish only consumer data and statuses are independent", c do
    b = bot("Muse", c.opts)
    {:ok, s} = Bots.create_session([b["id"]], c.opts)
    {:ok, _} = Bots.subscribe(c.opts)
    {:ok, m} = Bots.post(s["id"], b["id"], "**hello**", c.opts)
    assert_receive {:vega_bots, %{"type" => "message", "message_id" => mid}}
    assert mid == m["id"]
    {:ok, _} = Bots.status(s["id"], b["id"], "thinking", c.opts ++ [detail: "Planning"])
    {:ok, s} = Bots.get_session(s["id"], c.opts)
    assert s["statuses"][b["id"]] == %{"state" => "thinking", "detail" => "Planning"}
    assert length(s["messages"]) == 1
  end

  test "human answer survives absence and requester restart by name until ack", c do
    b = bot("Muse", c.opts)
    name = "requester." <> Vega.Store.id()

    {:ok, r} =
      Bots.request_human(
        b["id"],
        "Which hotel?",
        c.opts ++ [requester: name, request_id: "correlation-1"]
      )

    assert {:ok, ^r} =
             Bots.request_human(
               b["id"],
               "Which hotel?",
               c.opts ++ [requester: name, request_id: "correlation-1"]
             )

    {:ok, answered} = Bots.answer_request(r["id"], "The blue hotel", c.opts)
    assert answered["status"] == "answered"
    assert {:ok, ^answered} = Bots.answer_request(r["id"], "The blue hotel", c.opts)
    assert {:error, :already_answered} = Bots.answer_request(r["id"], "Other", c.opts)
    parent = self()

    first =
      spawn(fn ->
        receive do
          event ->
            send(parent, event)

            receive do
              :stop -> :ok
            end
        end
      end)

    :yes = :global.register_name({Vega.BotsTest.Runtime, name}, first)
    on_exit(fn -> :global.unregister_name({Vega.BotsTest.Runtime, name}) end)
    assert_receive {:vega_human_answer, "correlation-1", "The blue hotel"}, 300
    :global.unregister_name({Vega.BotsTest.Runtime, name})
    send(first, :stop)
    parent = self()

    new =
      spawn(fn ->
        receive do
          event ->
            send(parent, {:restarted, event})

            receive do
              :stop -> :ok
            end
        end
      end)

    :yes = :global.register_name({Vega.BotsTest.Runtime, name}, new)
    assert_receive {:restarted, {:vega_human_answer, "correlation-1", "The blue hotel"}}, 300

    assert {:error, :invalid_acknowledgement} =
             Bots.acknowledge_answer(r["id"], c.opts ++ [requester: "wrong"])

    assert {:ok, _} = Bots.acknowledge_answer(r["id"], c.opts ++ [requester: name])
    send(new, :stop)
    {:ok, session} = Bots.get_session(r["session_id"], c.opts)
    assert length(session["messages"]) == 2
    assert {:ok, []} = Bots.pending_requests(c.opts)
  end

  test "state, faces, chats and memory survive service restart", c do
    b = bot("Muse", c.opts)
    {:ok, s} = Bots.create_session([b["id"]], c.opts)
    {:ok, m} = Bots.post(s["id"], b["id"], "Hi", c.opts)

    assert {:ok, memory} =
             Bots.remember(
               b["id"],
               "Person loves pineapple",
               c.opts ++ [provenance: %{"session" => s["id"]}]
             )

    assert {:ok, [^memory]} = Bots.retrieve(b["id"], "pineapple", c.opts)
    stop_supervised(Vega.Bots.Server)

    {:ok, pid} =
      start_supervised(
        {Vega.Bots.Server,
         name: c.name, root: c.root, runtime: Vega.BotsTest.Runtime, tick_ms: 20}
      )

    opts = [server: pid]
    assert {:ok, ^b} = Bots.get_bot(b["id"], opts)
    assert {:ok, restored} = Bots.get_session(s["id"], opts)
    assert restored["messages"] == [m]
    {:ok, bytes} = File.read(Vega.Bots.Persistence.path(c.root))
    assert {:ok, %{"entries" => [_]}} = Jason.decode(bytes)
  end

  test "accepted inputs persist until visible reply, with proactive posts not acknowledging", c do
    b = bot("Muse", c.opts)
    {:ok, s} = Bots.create_session([b["id"]], c.opts)
    {:ok, input} = Bots.send_message(s["id"], "Please reply", c.opts)
    assert_receive {:delivered, _, _, ^input}
    {:ok, _} = Bots.post(s["id"], b["id"], "An unsolicited update", c.opts ++ [proactive: true])
    {:ok, saved} = Vega.Bots.Persistence.load(c.root)
    assert Enum.any?(saved["outbox"], &(&1["message_id"] == input["id"]))
    stop_supervised(Vega.Bots.Server)

    {:ok, pid} =
      start_supervised(
        {Vega.Bots.Server,
         name: c.name, root: c.root, runtime: Vega.BotsTest.Runtime, tick_ms: 20}
      )

    opts = [server: pid]
    {:ok, _} = Bots.retry(s["id"], opts)
    assert_receive {:delivered, _, _, ^input}

    {:ok, reply} =
      Bots.post(s["id"], b["id"], "Here is the reply", opts ++ [reply_to: input["id"]])

    assert {:ok, ^reply} =
             Bots.post(s["id"], b["id"], "Here is the reply", opts ++ [reply_to: input["id"]])

    assert {:error, :invalid_message_or_author} =
             Bots.post(s["id"], b["id"], "bad", opts ++ [reply_to: "missing"])

    {:ok, saved} = Vega.Bots.Persistence.load(c.root)
    assert saved["outbox"] == []
  end

  test "snapshots exclude closed chat history and bounded latest reads stay nonblocking", c do
    b = bot("Muse", c.opts)
    {:ok, s} = Bots.create_session([b["id"]], c.opts)

    Enum.each(1..95, fn n ->
      {:ok, _} = Bots.post(s["id"], b["id"], "message #{n}", c.opts ++ [proactive: true])
    end)

    {:ok, snapshot} = Bots.snapshot(c.opts)
    assert length(hd(snapshot["sessions"])["messages"]) == 1
    assert hd(snapshot["sessions"])["message_count"] == 95
    :sys.suspend(c.opts[:server])

    try do
      assert {:ok, _} = Bots.snapshot(c.opts)
      assert {:ok, page} = Bots.get_session(s["id"], c.opts)
      assert length(page["messages"]) == 80
      assert page["history"]["has_more"]
      assert page["history"]["start"] == 15
    after
      :sys.resume(c.opts[:server])
    end

    {:ok, page} = Bots.get_session(s["id"], c.opts)
    {:ok, older} = Bots.get_session(s["id"], c.opts ++ [before: page["history"]["next_before"]])
    assert length(older["messages"]) == 15
    refute older["history"]["has_more"]
    assert hd(older["messages"])["text"] == "message 1"
    assert {:error, :invalid_cursor} = Bots.get_session(s["id"], c.opts ++ [before: "unknown"])
  end

  test "notification settings validate person controlled bounds and attachments fail closed", c do
    assert {:error, :invalid_settings} =
             Bots.update_settings(%{notification_interval_seconds: 0}, c.opts)

    assert {:error, :invalid_settings} =
             Bots.update_settings(%{notification_max_per_hour: 61}, c.opts)

    assert {:ok, settings} =
             Bots.update_settings(
               %{notifications_enabled: true, notification_max_per_hour: 2},
               c.opts
             )

    assert settings["notifications_enabled"]
    b = bot("Muse", c.opts)
    {:ok, s} = Bots.create_session([b["id"]], c.opts)

    assert {:error, _} =
             Bots.send_message(
               s["id"],
               "picture",
               c.opts ++ [images: [%{"path" => "/etc/passwd"}]]
             )
  end
end

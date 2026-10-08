defmodule Seedling.BotsRegressionTest do
  use ExUnit.Case, async: true
  alias Seedling.{Bots, BotFiles, CapabilityStore, ChatContext}

  # Fake mailbox agents never invoke a provider. Every catalog/name is unique, and
  # runtime.exs gives this test VM an isolated state/image/log directory.
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURf8AAP///0EdNBEAAAABYktHRAH/Ai3eAAAAB3RJTUUH6goIDC8zUNkCFQAAAApJREFUCNdjYAAAAAIAAeIhvDMAAAAldEVYdGRhdGU6Y3JlYXRlADIwMjYtMTAtMDhUMTI6NDc6NTErMDA6MDAp2KFtAAAAJXRFWHRkYXRlOm1vZGlmeQAyMDI2LTEwLTA4VDEyOjQ3OjUxKzAwOjAwWIUZ0QAAACh0RVh0ZGF0ZTp0aW1lc3RhbXAAMjAyNi0xMC0wOFQxMjo0Nzo1MSswMDowMA+QOA4AAAAASUVORK5CYII="

  setup do
    root = Path.join(System.tmp_dir!(), "orion-bots-regression-" <> CapabilityStore.id())
    owner = self()
    starter = fn opts -> {:ok, fake_agent(opts[:name], owner)} end
    config = [name: nil, root: root, agent_starter: starter, decision_opts: [key: nil]]
    server = start_supervised!({Bots, config})

    on_exit(fn ->
      for {{:agent, name}, pid} <- Nano.Names.all(),
          {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
          dictionary[:bots_regression_owner] == owner do
        Process.exit(pid, :kill)
        Nano.StateStore.delete(name)
      end

      File.rm_rf(root)
    end)

    %{root: root, config: config, server: server, opts: [server: server]}
  end

  defp fake_agent(name, owner) do
    caller = self()

    pid =
      spawn(fn ->
        Process.put(:bots_regression_owner, owner)

        case Nano.Names.register_name({:agent, name}, self()) do
          :yes ->
            send(caller, {:fake_ready, self(), self()})
            forward(owner)

          :no ->
            # An old at-least-once delivery task may race service restart. Like
            # NanoAgent.start, reuse the process that won the name registration.
            send(caller, {:fake_ready, self(), NanoAgent.whereis(name)})
        end
      end)

    receive do
      {:fake_ready, ^pid, winner} when is_pid(winner) -> winner
    after
      1000 -> flunk("fake agent did not register #{name}")
    end
  end

  defp forward(owner) do
    receive do
      {:ack, server, request} ->
        send(owner, {:ack_result, self(), Bots.acknowledge(request, server: server)})

      event ->
        send(owner, {:agent_event, self(), event})
    end

    forward(owner)
  end

  defp bot_and_session(c) do
    {:ok, bot} =
      Bots.create(
        "Regression companion",
        c.opts ++ [model: "fake/model", reasoning: "off", max_context: 20000]
      )

    {:ok, chat} = Bots.session([bot["id"]], c.opts)
    {bot, chat}
  end

  defp restart(c) do
    :ok = stop_supervised(Bots)
    server = start_supervised!({Bots, c.config})
    %{c | server: server, opts: [server: server]}
  end

  defp request(c, id), do: Bots.snapshot(c.server)["requests"][id]

  defp status(c, chat, bot),
    do: Bots.snapshot(c.server)["sessions"][chat["id"]]["status"][bot["id"]]

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

  test "offline answers survive restart, retry to a replacement named target, and require target acknowledgement",
       c do
    {bot, chat} = bot_and_session(c)
    target = "regression-reply-" <> CapabilityStore.id()
    requester = "regression-requester-" <> CapabilityStore.id()
    :yes = Nano.Names.register_name({:agent, requester}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, requester}) end)

    assert {:ok, r} =
             Bots.request_human(
               bot["id"],
               "Which dates?",
               c.opts ++ [session: chat["id"], reply_to: target]
             )

    assert r["requester"] == requester
    assert r["reply_target"] == target
    assert {:error, :request_not_completed} = Bots.acknowledge(r["id"], c.opts)

    assert {:error, :wrong_answer_session} =
             Bots.answer(r["id"], "Tomorrow", c.opts ++ [session: "wrong"])

    assert {:ok, _} = Bots.answer(r["id"], "Tomorrow", c.opts ++ [session: chat["id"]])
    c = restart(c)
    assert request(c, r["id"])["delivery_state"] == "pending"
    assert request(c, r["id"])["delivery_attempts"] == 0

    assert {:error, :request_not_open} =
             Bots.answer(r["id"], "Again", c.opts ++ [session: chat["id"]])

    recipient = fake_agent(target, self())
    send(c.server, :outbox)

    assert_receive {:agent_event, ^recipient,
                    %{
                      type: :bot_human_answer,
                      request_id: id,
                      bot_id: bot_id,
                      session_id: session_id,
                      state: "answered",
                      answer: "Tomorrow"
                    }},
                   2000

    assert {id, bot_id, session_id} == {r["id"], bot["id"], chat["id"]}
    first = request(c, id)
    assert first["delivery_attempts"] == 1

    assert first["next_delivery"] in (System.system_time(:second) + 58)..(System.system_time(
                                                                            :second
                                                                          ) + 60)

    # The actual requester is not the designated reply target.
    assert {:error, :not_reply_target} = Bots.acknowledge(id, c.opts)
    send(c.server, :outbox)
    _ = Bots.snapshot(c.server)
    refute_receive {:agent_event, ^recipient, %{type: :bot_human_answer}}, 50
    assert request(c, id)["delivery_attempts"] == 1

    # Fast-forward only this catalog's durable retry timestamp while stopped;
    # production backoff need not make the suite wait a minute.
    :ok = stop_supervised(Bots)
    ref = Process.monitor(recipient)
    Process.exit(recipient, :kill)
    assert_receive {:DOWN, ^ref, :process, ^recipient, :killed}
    eventually(fn -> NanoAgent.whereis(target) == nil end)

    assert {:ok, :ok} =
             CapabilityStore.update(
               :bots,
               "catalog",
               %{},
               fn doc ->
                 {:ok, put_in(doc, ["requests", id, "next_delivery"], 0), :ok}
               end,
               root: c.root
             )

    replacement = fake_agent(target, self())
    server = start_supervised!({Bots, c.config})
    c = %{c | server: server, opts: [server: server]}

    assert_receive {:agent_event, ^replacement,
                    %{type: :bot_human_answer, request_id: ^id, answer: "Tomorrow"}},
                   2000

    assert request(c, id)["delivery_attempts"] == 2

    assert request(c, id)["next_delivery"] in (System.system_time(:second) + 118)..(System.system_time(
                                                                                      :second
                                                                                    ) + 120)

    send(replacement, {:ack, c.server, id})
    assert_receive {:ack_result, ^replacement, {:ok, :ok}}, 2000
    c = restart(c)
    send(c.server, :outbox)
    assert request(c, id)["delivery_state"] == "acknowledged"
    refute_receive {:agent_event, ^replacement, %{type: :bot_human_answer}}, 50

    assert {:ok, %{"answer" => "Tomorrow", "delivery_state" => "acknowledged"}} =
             Bots.request_status(id, c.opts)
  end

  test "unnamed pid targets can only acknowledge their own correlated answer", c do
    {bot, chat} = bot_and_session(c)
    parent = self()
    pid = spawn(fn -> forward(parent) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    assert {:ok, r} = Bots.request_human(bot["id"], "Ready?", c.opts ++ [reply_to: pid])
    assert r["reply_target"] == nil
    assert {:ok, _} = Bots.answer(r["id"], "Yes", c.opts ++ [session: chat["id"]])
    assert_receive {:agent_event, ^pid, %{type: :bot_human_answer, request_id: id}}, 2000
    assert {:error, :not_reply_target} = Bots.acknowledge(id, c.opts)
    send(pid, {:ack, c.server, id})
    assert_receive {:ack_result, ^pid, {:ok, :ok}}, 2000
  end

  test "restart rehydrates a thinking watcher and turn_ended clears it without exposing harness text",
       c do
    {bot, chat} = bot_and_session(c)
    name = Bots.agent_name(chat["id"], bot["id"])
    id = CapabilityStore.id()
    Nano.StateStore.put(name, %{id: id, name: name, status: :thinking, halted: nil})
    on_exit(fn -> Nano.StateStore.delete(name) end)
    GenServer.cast(c.server, {:delivery, chat["id"], bot["id"], "thinking", id})
    assert status(c, chat, bot) == "thinking"
    c = restart(c)
    eventually(fn -> status(c, chat, bot) == "thinking" end)

    Phoenix.PubSub.broadcast(
      Nano.PubSub,
      "agent:" <> id,
      {:nano_log, %{type: :model_response, agent_id: id, text: "SECRET harness final"}}
    )

    Phoenix.PubSub.broadcast(
      Nano.PubSub,
      "agent:" <> CapabilityStore.id(),
      {:nano_log, %{type: :turn_ended, agent_id: "unrelated"}}
    )

    assert status(c, chat, bot) == "thinking"

    Phoenix.PubSub.broadcast(
      Nano.PubSub,
      "agent:" <> id,
      {:nano_log, %{type: :turn_ended, agent_id: id}}
    )

    eventually(fn -> status(c, chat, bot) == "idle" end)
    assert Bots.snapshot(c.server)["sessions"][chat["id"]]["messages"] == []
  end

  test "restart reconciles saved paused and tool/retry states; catalog-only watcher still receives turn_ended",
       c do
    {bot, chat} = bot_and_session(c)
    name = Bots.agent_name(chat["id"], bot["id"])
    id = CapabilityStore.id()
    on_exit(fn -> Nano.StateStore.delete(name) end)
    GenServer.cast(c.server, {:delivery, chat["id"], bot["id"], "thinking", id})
    _ = Bots.snapshot(c.server)

    for {saved_status, halted, expected} <- [
          {:running_tool, nil, "thinking"},
          {:waiting_retry, nil, "thinking"},
          {:idle, :context, "paused; operator attention needed"},
          {:idle, nil, "idle"}
        ] do
      Nano.StateStore.put(name, %{id: id, name: name, status: saved_status, halted: halted})
      c = restart(c)
      eventually(fn -> status(c, chat, bot) == expected end)
    end

    Nano.StateStore.delete(name)
    c = restart(c)
    eventually(fn -> status(c, chat, bot) == "idle" end)
    GenServer.cast(c.server, {:delivery, chat["id"], bot["id"], "thinking", nil})
    assert status(c, chat, bot) == "thinking"

    Phoenix.PubSub.broadcast(
      Nano.PubSub,
      "agent:" <> id,
      {:nano_log, %{type: :turn_ended, agent_id: id}}
    )

    eventually(fn -> status(c, chat, bot) == "idle" end)
  end

  test "24 long multibyte messages and image delivery stay bounded while originals remain pageable",
       c do
    {bot, chat} = bot_and_session(c)
    text = String.duplicate("🙂界", 6000)

    for _ <- 1..23 do
      assert {:ok, m} = Bots.say(chat["id"], text, c.opts)
      assert_receive {:agent_event, _, %{type: :bot_chat, message_id: id}}, 2000
      assert id == m["id"]
    end

    path = Path.join(c.root, "pixel.png")
    File.write!(path, Base.decode64!(@png))
    assert {:ok, file} = BotFiles.add(path, "pixel.png", root: c.root)
    assert file["image"]["mime"] == "image/png"
    assert {:ok, latest} = Bots.say(chat["id"], text, c.opts ++ [files: [file]])
    assert_receive {:agent_event, _, {:"$gen_cast", {:images, refs, envelope}}}, 2000
    assert refs == [file["image"]]
    assert String.valid?(envelope)
    assert byte_size(envelope) <= 40_000
    assert byte_size(Jason.encode!(%{images: refs, text: envelope})) <= 40_000
    assert envelope =~ latest["id"]
    assert envelope =~ "Truncated for context budget"
    assert envelope =~ "Seedling.Bots.message"
    assert envelope =~ "offset: 0"

    latest_id = latest["id"]
    refute_receive {:agent_event, _, %{type: :bot_chat, message_id: ^latest_id}}, 50

    durable = Bots.snapshot(c.server)["sessions"][chat["id"]]

    event =
      ChatContext.build(
        durable,
        bot,
        text,
        %{text: String.duplicate("记", 2000), method: :lexical_fallback},
        :one_to_one,
        latest
      )

    assert byte_size(Jason.encode!(event)) <= 40_000
    assert length(event.conversation) in 1..23
    refute Enum.any?(event.conversation, &(&1["id"] == latest["id"]))
    assert String.valid?(event.message)
    assert event.message =~ "Truncated for context budget"
    assert event.memory =~ "Truncated for context budget"

    assert Enum.all?(event.conversation, fn row ->
             String.valid?(row["text"]) and row["text"] =~ "Truncated for context budget"
           end)

    assert length(durable["messages"]) == 24
    assert Enum.all?(durable["messages"], &(&1["text"] == text))
    c = restart(c)

    pages =
      for offset <- [0, 3000, 6000, 9000] do
        assert {:ok, page} =
                 Bots.message(chat["id"], latest["id"], c.opts ++ [offset: offset, limit: 3000])

        assert page["total_chars"] == 12_000
        assert page["next_offset"] == offset + 3000
        assert String.valid?(page["text"])
        page["text"]
      end

    assert Enum.join(pages) == text
    assert {:error, :not_found} = Bots.message(chat["id"], "missing", c.opts)
  end
end

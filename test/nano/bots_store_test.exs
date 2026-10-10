defmodule Nano.BotsStoreTest do
  use ExUnit.Case, async: true
  alias Nano.Bots
  alias Nano.Bots.Store

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "altair-bots-foundation-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    {:ok, pid} = Store.start_link(name: nil, store_dir: dir, pubsub: nil)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(dir)
    end)

    opts = [server: pid]
    {:ok, bot} = Bots.create_bot(%{name: "Muse", voice: "warm"}, opts)
    {:ok, session} = Bots.create_session(%{participant_ids: [bot.id], exchange_ceiling: 2}, opts)
    %{dir: dir, pid: pid, opts: opts, bot: bot, session: session}
  end

  test "ordering, cursor, idempotency and fencing", c do
    {:ok, h} = Bots.post_human(c.session.id, %{text: "hello", idempotency_key: "h"}, c.opts)
    assert h.sequence == 1 and h.epoch == 1

    assert {:ok, ^h} =
             Bots.post_human(c.session.id, %{text: "hello", idempotency_key: "h"}, c.opts)

    a = %{text: "hi", actor: {:bot, c.bot.id}, epoch: 1, idempotency_key: "b"}
    {:ok, b} = Bots.publish(c.session.id, a, c.opts)
    assert b.sequence == 2
    assert {:ok, ^b} = Bots.publish(c.session.id, a, c.opts)

    assert {:error, :idempotency_conflict} =
             Bots.publish(c.session.id, %{a | text: "changed"}, c.opts)

    {:ok, _} = Bots.publish(c.session.id, %{a | idempotency_key: "b2"}, c.opts)

    assert {:error, :exchange_ceiling} =
             Bots.publish(c.session.id, %{a | idempotency_key: "b3"}, c.opts)

    assert {:ok, %{messages: [^h], next_cursor: 1, has_more: true}} =
             Bots.list_messages(c.session.id, c.opts ++ [limit: 1])

    assert {:ok, %{messages: [^b | _], has_more: false}} =
             Bots.list_messages(c.session.id, c.opts ++ [after: 1])

    assert {:error, :invalid} = Bots.list_messages(c.session.id, c.opts ++ [limit: 201])
    {:ok, s} = Bots.stop_session(c.session.id, c.opts)
    assert s.stopped and s.epoch == 2

    assert {:error, :stale_epoch} =
             Bots.publish(c.session.id, %{a | idempotency_key: "old"}, c.opts)

    assert {:error, :stopped} =
             Bots.publish(c.session.id, %{a | epoch: 2, idempotency_key: "stopped"}, c.opts)

    {:ok, h2} = Bots.post_human(c.session.id, %{text: "again", idempotency_key: "h2"}, c.opts)
    assert h2.epoch == 3
    assert {:ok, _} = Bots.publish(c.session.id, %{a | epoch: 3, idempotency_key: "new"}, c.opts)
  end

  test "restart preserves identity, session, messages and ack", c do
    {:ok, q} =
      Bots.request_human(
        %{bot_id: c.bot.id, session_id: c.session.id, requester: "worker-one", text: "choice?"},
        c.opts
      )

    assert {:error, :not_answered} = Bots.ack_request(q.id, c.opts)
    {:ok, q} = Bots.answer_request(q.id, "yes", c.opts)
    assert q.status == :answered
    {:ok, q} = Bots.mark_delivery(q.id, c.opts)
    assert q.delivery_attempts == 1
    GenServer.stop(c.pid)
    {:ok, pid} = Store.start_link(name: nil, store_dir: c.dir, pubsub: nil)
    opts = [server: pid]
    assert {:ok, [^q]} = Bots.outbox(opts)
    assert {:ok, bot} = Bots.get_bot(c.bot.id, opts)
    assert bot.voice == "warm"

    assert {:ok,
            %{
              messages: [
                %{text: "yes", actor: :human, request_id: request_id}
              ]
            }} =
             Bots.list_messages(c.session.id, opts)

    {:ok, q} = Bots.ack_request(q.id, opts)
    assert q.status == :acked
    assert request_id == q.id
    GenServer.stop(pid)
    {:ok, pid} = Store.start_link(name: nil, store_dir: c.dir, pubsub: nil)
    assert {:ok, []} = Bots.outbox(server: pid)
    assert {:ok, ^q} = Bots.get_request(q.id, server: pid)
    GenServer.stop(pid)
  end

  test "memory is bot scoped, bounded and human editable", c do
    {:ok, other} = Bots.create_bot(%{name: "Other"}, c.opts)

    {:ok, m} =
      Bots.create_memory(
        c.bot.id,
        %{text: "likes tea", provenance: %{session_id: c.session.id}},
        c.opts
      )

    assert {:ok, []} = Bots.list_memories(other.id, c.opts)
    {:ok, edited} = Bots.update_memory(m.id, %{text: "likes coffee"}, c.opts)
    assert edited.provenance == m.provenance
    assert {:ok, ^edited} = Bots.delete_memory(m.id, c.opts)

    for n <- 1..201 do
      assert {:ok, _} =
               Bots.create_memory(c.bot.id, %{text: "fact #{n}", provenance: %{}}, c.opts)
    end

    assert {:ok, memories} = Bots.list_memories(c.bot.id, c.opts ++ [limit: 200])
    assert length(memories) == 200
    assert hd(memories).text == "fact 201"
    refute Enum.any?(memories, &(&1.text == "fact 1"))

    assert {:error, :invalid} =
             Bots.create_memory(c.bot.id, %{text: "bad", provenance: %{pid: self()}}, c.opts)

    assert {:error, :immutable_id} = Bots.update_bot(c.bot.id, %{id: "new"}, c.opts)
  end

  test "malformed attrs and foreign bots cannot mutate the session", c do
    {:ok, other} = Bots.create_bot(%{name: "Foreign"}, c.opts)

    for bad <- [nil, [], "bad", %{name: self()}] do
      assert {:error, :invalid} = Bots.create_bot(bad, c.opts)
      assert {:error, :invalid} = Bots.post_human(c.session.id, bad, c.opts)
      assert {:error, :invalid} = Bots.request_human(bad, c.opts)
    end

    assert {:error, :invalid_actor} =
             Bots.publish(
               c.session.id,
               %{
                 actor: {:bot, other.id},
                 epoch: 0,
                 text: "intrusion",
                 idempotency_key: "foreign"
               },
               c.opts
             )

    assert {:error, :invalid} =
             Bots.request_human(
               %{
                 bot_id: other.id,
                 session_id: c.session.id,
                 requester: "worker",
                 text: "intrusion"
               },
               c.opts
             )

    assert {:error, :reserved_key} =
             Bots.post_human(
               c.session.id,
               %{text: "spoof", idempotency_key: "request-answer:abc"},
               c.opts
             )

    assert {:error, :invalid} =
             Bots.create_memory(
               c.bot.id,
               %{text: "fact", provenance: %{callback: fn -> :ok end}},
               c.opts
             )

    assert {:ok, %{messages: []}} = Bots.list_messages(c.session.id, c.opts)
  end

  test "failed atomic write leaves in-memory and disk state unchanged", c do
    File.mkdir!(Path.join(c.dir, "domain.term.tmp"))

    assert {:error, {:storage, _}} =
             Bots.post_human(c.session.id, %{text: "lost", idempotency_key: "lost"}, c.opts)

    assert {:ok, %{epoch: 0}} = Bots.get_session(c.session.id, c.opts)
    assert {:ok, %{messages: []}} = Bots.list_messages(c.session.id, c.opts)
    GenServer.stop(c.pid)
    {:ok, pid} = Store.start_link(name: nil, store_dir: c.dir, pubsub: nil)
    assert {:ok, %{epoch: 0}} = Bots.get_session(c.session.id, server: pid)
    GenServer.stop(pid)
  end

  test "session topic receives persisted session and request events", c do
    GenServer.stop(c.pid)
    {:ok, pid} = Store.start_link(name: nil, store_dir: c.dir)
    opts = [server: pid]
    Phoenix.PubSub.subscribe(Nano.PubSub, "bots:session:" <> c.session.id)
    {:ok, stopped} = Bots.stop_session(c.session.id, opts)
    assert_receive {:bots, :session_stopped, ^stopped}

    {:ok, q} =
      Bots.request_human(
        %{bot_id: c.bot.id, session_id: c.session.id, requester: "worker", text: "choice?"},
        opts
      )

    assert_receive {:bots, :request_created, ^q}
    refute_receive {:bots, :message_created, _}
    assert {:ok, %{messages: []}} = Bots.list_messages(c.session.id, opts)
    assert {:ok, [^q]} = Bots.list_requests(opts)
    GenServer.stop(pid)
  end

  test "corrupt snapshots fail
 and abandoned temp is ignored",
       c do
    GenServer.stop(c.pid)
    File.write!(Path.join(c.dir, "domain.term.tmp"), "incomplete")
    {:ok, pid} = Store.start_link(name: nil, store_dir: c.dir, pubsub: nil)
    assert {:ok, _} = Bots.get_bot(c.bot.id, server: pid)
    GenServer.stop(pid)
    File.write!(Path.join(c.dir, "domain.term"), "corrupt")
    Process.flag(:trap_exit, true)

    assert {:error, {:error, :corrupt_snapshot}} =
             Store.start_link(name: nil, store_dir: c.dir, pubsub: nil)
  end
end

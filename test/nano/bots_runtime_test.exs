defmodule Nano.Bots.RuntimeTest do
  use ExUnit.Case, async: true
  alias Nano.Bots
  alias Nano.Bots.Runtime

  defmodule Adapter do
    def ensure(bot, session, _opts), do: {:ok, Enum.join([bot.face, bot.id, session.id], "/")}

    def deliver(name, batch) do
      [requester, bot, session] = String.split(name, "/")
      send(String.to_existing_atom(requester), {:delivery, session, bot, batch})
      :ok
    end

    def notify(name, term) do
      case Process.whereis(String.to_existing_atom(name)) do
        nil ->
          {:error, :offline}

        pid ->
          send(pid, term)
          :ok
      end
    end

    def status(_), do: :thinking
    def lifecycle(name), do: Delegation.events(name)
    def ack_lifecycle(id), do: Delegation.ack(id)
  end

  setup do
    token = System.unique_integer([:positive]) |> Integer.to_string()
    dir = Path.join(System.tmp_dir!(), "altair-bots-runtime-test-" <> token)
    name = String.to_atom("runtime_test_" <> token)
    Process.register(self(), name)

    store =
      start_supervised!({Nano.Bots.Store, name: nil, store_dir: dir <> "/store", pubsub: nil})

    {:ok, a} =
      Bots.create_bot(%{name: Atom.to_string(name), face: Atom.to_string(name)}, server: store)

    {:ok, b} =
      Bots.create_bot(%{name: Atom.to_string(name), face: Atom.to_string(name)}, server: store)

    {:ok, session} = Bots.create_session(%{participant_ids: [a.id, b.id]}, server: store)

    runtime_opts = [
      name: nil,
      store: store,
      state_dir: dir <> "/runtime",
      pubsub: nil,
      adapter: Adapter,
      page_size: 2,
      retry_ms: 60_000,
      router_opts: [evaluate: fn _, _, _ -> {:error, :missing_key} end]
    ]

    runtime = start_supervised!({Runtime, runtime_opts})
    on_exit(fn -> File.rm_rf(dir) end)

    %{
      store: store,
      a: a,
      b: b,
      session: session,
      runtime: runtime,
      opts: runtime_opts,
      requester: Atom.to_string(name)
    }
  end

  test "human routing failure selects both, bounded catchup preserves all attribution and retries",
       c do
    for text <- ["both of you debate this", "No takers?", "one", "two", "three"],
        do:
          Bots.post_human(
            c.session.id,
            %{text: text, idempotency_key: Integer.to_string(System.unique_integer([:positive]))},
            server: c.store
          )

    Runtime.reconcile(server: c.runtime)
    assert_receive {:delivery, _, bot, page}
    assert bot in [c.a.id, c.b.id]
    assert length(page.messages) == 2
    assert page.has_more
    assert Enum.all?(page.messages, &(&1.actor == :human))
    assert :ok = Runtime.ack_delivery(page.delivery_id, server: c.runtime)
    assert_receive {:delivery, _, ^bot, next}
    # Retransmitted first pages may precede the new page.
    pages = collect_pages([next], bot)
    assert Enum.any?(pages, &(hd(&1.messages).sequence == 3))
    assert :ok = Runtime.ack_delivery(page.delivery_id, server: c.runtime)
  end

  test "stop and new human epoch fence old publication; explicit retries are idempotent", c do
    {:ok, human} =
      Bots.post_human(
        c.session.id,
        %{text: "hello", idempotency_key: Integer.to_string(System.unique_integer([:positive]))},
        server: c.store
      )

    assert {:ok, message} =
             Runtime.post(c.session.id, c.a.id, "consumer only",
               epoch: human.epoch,
               idempotency_key: "key",
               server: c.runtime
             )

    Bots.stop_session(c.session.id, server: c.store)

    assert {:error, :stale_epoch} =
             Runtime.post(c.session.id, c.a.id, "old",
               epoch: human.epoch,
               idempotency_key: "old",
               server: c.runtime
             )

    assert {:ok, ^message} =
             Runtime.post(c.session.id, c.a.id, "consumer only",
               epoch: human.epoch,
               idempotency_key: "key",
               server: c.runtime
             )

    {:ok, new} =
      Bots.post_human(
        c.session.id,
        %{
          text: "continue",
          idempotency_key: Integer.to_string(System.unique_integer([:positive]))
        },
        server: c.store
      )

    assert new.epoch > human.epoch

    assert {:error, :stale_epoch} =
             Runtime.post(c.session.id, c.a.id, "old",
               epoch: human.epoch,
               idempotency_key: "old2",
               server: c.runtime
             )
  end

  test "human request is answerable, durable answer retries until correlation ack", c do
    assert {:ok, request} =
             Runtime.ask_human(c.a.id, "choose a date", requester: c.requester, server: c.runtime)

    assert request.session_id == c.session.id
    assert request.status == :pending
    {:ok, _} = Bots.answer_request(request.id, "Friday", server: c.store)
    Runtime.reconcile(server: c.runtime)
    assert_receive {:bots_human_answer, %{request_id: id, answer: "Friday"}}
    assert id == request.id
    Runtime.reconcile(server: c.runtime)
    assert_receive {:bots_human_answer, %{request_id: ^id}}
    assert {:ok, %{status: :acked}} = Runtime.ack_human(id, server: c.runtime)
    assert {:ok, []} = Bots.outbox(server: c.store)
  end

  test "pending delivery restored without saved pids and independent sessions", c do
    Bots.post_human(
      c.session.id,
      %{text: "first", idempotency_key: Integer.to_string(System.unique_integer([:positive]))},
      server: c.store
    )

    Runtime.reconcile(server: c.runtime)
    assert_receive {:delivery, _, bot, page}
    stop_supervised!(Runtime)
    restarted = start_supervised!({Runtime, c.opts})
    Runtime.reconcile(server: restarted)
    pages = collect_pages([], bot)
    assert Enum.any?(pages, &(&1.delivery_id == page.delivery_id))
    {:ok, other} = Bots.create_session(%{participant_ids: [c.a.id]}, server: c.store)

    Bots.post_human(
      other.id,
      %{text: "isolated", idempotency_key: Integer.to_string(System.unique_integer([:positive]))},
      server: c.store
    )

    Runtime.reconcile(server: restarted)
    assert_receive {:delivery, sid, _, other_page} when sid == other.id
    assert Enum.map(other_page.messages, & &1.text) == ["isolated"]
  end

  test "bot-only routing failure stops with compact durable notice", c do
    {:ok, h} =
      Bots.post_human(c.session.id, %{text: "start", idempotency_key: "start"}, server: c.store)

    Runtime.reconcile(server: c.runtime)

    {:ok, _} =
      Runtime.post(c.session.id, c.a.id, "a bot reply",
        epoch: h.epoch,
        idempotency_key: "reply",
        server: c.runtime
      )

    Runtime.reconcile(server: c.runtime)
    assert {:ok, %{stopped: true}} = Bots.get_session(c.session.id, server: c.store)

    assert {:ok, [%{reason: :routing_unavailable, text: text}]} =
             Runtime.notices(server: c.runtime)

    assert byte_size(text) < 150
  end

  test "ceiling fences further publication and emits one notice", c do
    Bots.update_session(c.session.id, %{exchange_ceiling: 1}, server: c.store)

    {:ok, h} =
      Bots.post_human(c.session.id, %{text: "debate", idempotency_key: "debate"}, server: c.store)

    Runtime.reconcile(server: c.runtime)

    assert {:ok, _} =
             Runtime.post(c.session.id, c.a.id, "first",
               epoch: h.epoch,
               idempotency_key: "first",
               server: c.runtime
             )

    assert {:error, :exchange_ceiling} =
             Runtime.post(c.session.id, c.b.id, "second",
               epoch: h.epoch,
               idempotency_key: "second",
               server: c.runtime
             )

    Runtime.reconcile(server: c.runtime)
    Runtime.reconcile(server: c.runtime)
    assert {:ok, [%{reason: :ceiling}]} = Runtime.notices(server: c.runtime)
  end

  test "human bridge creates private chat when none eligible and retries after runtime restart",
       c do
    Bots.stop_session(c.session.id, server: c.store)

    assert {:ok, request} =
             Runtime.ask_human(c.a.id, "need choice", requester: c.requester, server: c.runtime)

    refute request.session_id == c.session.id

    assert {:ok, %{participant_ids: [bot]}} =
             Bots.get_session(request.session_id, server: c.store)

    assert bot == c.a.id
    Bots.answer_request(request.id, "yes", server: c.store)
    stop_supervised!(Runtime)
    restored = start_supervised!({Runtime, c.opts})
    Runtime.reconcile(server: restored)
    assert_receive {:bots_human_answer, %{request_id: id, answer: "yes"}}
    assert id == request.id
    Runtime.ack_human(id, server: restored)
    assert {:ok, []} = Bots.outbox(server: c.store)
  end

  test "large Unicode posts arrive in bounded attributed chunks without loss", c do
    text = String.duplicate("🙂", 5000)
    Bots.post_human(c.session.id, %{text: text, idempotency_key: "long"}, server: c.store)
    Runtime.reconcile(server: c.runtime)
    assert_receive {:delivery, _, bot, page}
    assert byte_size(:erlang.term_to_binary(page)) < 20_000
    assert [%{actor: :human, text_offset: 0}] = page.messages
    {chunks, final} = collect_chunks(c.runtime, bot, page, [])
    assert Enum.join(chunks) == text
    refute final.has_more
    assert final.next_cursor == 1
  end

  test "old same-epoch finish cannot erase newer selected delivery", c do
    stop_supervised!(Runtime)

    evaluator = fn _, questions, _ ->
      {:ok, %{answers: Map.new(questions, fn {id, _} -> {id, %{noul: 1.0}} end)}}
    end

    runtime = start_supervised!({Runtime, Keyword.put(c.opts, :router_opts, evaluate: evaluator)})

    {:ok, human} =
      Bots.post_human(c.session.id, %{text: "debate", idempotency_key: "begin"}, server: c.store)

    Runtime.reconcile(server: runtime)
    assert_receive {:delivery, _, bot, old}
    Runtime.ack_delivery(old.delivery_id, server: runtime)
    other = if bot == c.a.id, do: c.b.id, else: c.a.id

    Runtime.post(c.session.id, other, "distinct follow-up",
      epoch: human.epoch,
      idempotency_key: "follow",
      server: runtime
    )

    Runtime.reconcile(server: runtime)

    Runtime.finished(c.session.id, bot,
      epoch: human.epoch,
      delivery_id: old.delivery_id,
      server: runtime
    )

    assert Map.has_key?(:sys.get_state(runtime).data.selected, {c.session.id, bot})
    assert_receive {:delivery, _, ^bot, %{messages: [%{text: "distinct follow-up"}]}}
  end

  test "skipped bot catches every attributed post on its next selected turn", c do
    stop_supervised!(Runtime)

    eval = fn state, questions, _ ->
      selected = if state =~ "choose B", do: c.b.id, else: c.a.id

      {:ok,
       %{
         answers:
           Map.new(questions, fn {id, _} ->
             {id, %{noul: if(id == selected, do: 1.0, else: 0.0)}}
           end)
       }}
    end

    runtime = start_supervised!({Runtime, Keyword.put(c.opts, :router_opts, evaluate: eval)})

    {:ok, h} =
      Bots.post_human(c.session.id, %{text: "choose A", idempotency_key: "choose-a"},
        server: c.store
      )

    Runtime.reconcile(server: runtime)
    b = c.b.id
    refute_receive {:delivery, _, ^b, _}, 20

    Runtime.post(c.session.id, c.a.id, "A spoke",
      epoch: h.epoch,
      idempotency_key: "a-spoke",
      server: runtime
    )

    Runtime.reconcile(server: runtime)
    refute_receive {:delivery, _, ^b, _}, 20

    Bots.post_human(c.session.id, %{text: "choose B", idempotency_key: "choose-b"},
      server: c.store
    )

    Runtime.reconcile(server: runtime)
    assert_receive {:delivery, _, ^b, first}
    assert Enum.map(first.messages, & &1.actor) == [:human, {:bot, c.a.id}]
    assert first.has_more
    Runtime.ack_delivery(first.delivery_id, server: runtime)
    assert_receive {:delivery, _, ^b, %{messages: [%{text: "choose B"}], has_more: false}}
  end

  test "human answer delivery waits for stable requester to come back", c do
    {:ok, request} =
      Runtime.ask_human(c.a.id, "choose", requester: c.requester, server: c.runtime)

    Process.unregister(String.to_existing_atom(c.requester))
    Bots.answer_request(request.id, "answer", server: c.store)
    Runtime.reconcile(server: c.runtime)
    refute_receive {:bots_human_answer, _}, 20
    Process.register(self(), String.to_existing_atom(c.requester))
    Runtime.reconcile(server: c.runtime)
    assert_receive {:bots_human_answer, %{request_id: id, answer: "answer"}}
    assert id == request.id
    Runtime.ack_human(id, server: c.runtime)
  end

  test "write-ahead stop intent repairs crash between domain stop and notice", c do
    {:ok, h} =
      Bots.post_human(c.session.id, %{text: "hello", idempotency_key: "intent-h"},
        server: c.store
      )

    Runtime.reconcile(server: c.runtime)
    state = :sys.get_state(c.runtime)
    stop_supervised!(Runtime)
    intent = %{session_id: c.session.id, epoch: h.epoch, text: "Limit reached", reason: :ceiling}
    data = %{state.data | stop_intents: %{c.session.id => intent}}
    File.write!(state.path, :erlang.term_to_binary(data))
    Bots.stop_session(c.session.id, expected_epoch: h.epoch, server: c.store)
    runtime = start_supervised!({Runtime, c.opts})
    Runtime.reconcile(server: runtime)
    assert {:ok, [^intent]} = Runtime.notices(server: runtime)
    restored = :sys.get_state(runtime).data
    assert restored.pending == %{}
    assert restored.selected == %{}
    assert restored.stop_intents == %{}
  end

  test "production prompt composes full seed and bot flavour with explicit consumer tools, no false reporting",
       c do
    workspace = Path.join(c.opts[:state_dir], "workspace-" <> c.a.id)
    File.mkdir_p!(workspace)

    opts =
      Nano.Bots.Agent.prompt_options(c.a, c.session,
        store: c.store,
        runtime: :consumer_runtime,
        workspace: workspace
      )

    assert opts[:mode] == :consumer
    assert opts[:flavours] == ["bot"]
    assert {:ok, composed} = Delegation.Prompt.compose(opts)
    seed = File.read!(Path.expand("../../prompts/seed.txt", __DIR__))
    assert String.starts_with?(composed.prompt, seed)
    assert Enum.any?(composed.provenance.partials, &String.ends_with?(&1.path, "/bot.txt"))
    assert composed.prompt =~ "Nano.Bots.Runtime.post"
    assert composed.prompt =~ "epoch: batch.epoch"
    assert composed.prompt =~ "delivery_id: batch.delivery_id"
    assert composed.prompt =~ workspace
    refute composed.prompt =~ "Report to \"altair-bots\" using Delegation.report"
    refute composed.prompt =~ "This job is read-only"

    assert Nano.Bots.Agent.name(c.a.id, c.session.id) !=
             Nano.Bots.Agent.name(c.a.id, "different-session")
  end

  test "publication preserves validated attachment references and exact retry", c do
    ref = "attachment:" <> String.duplicate("a", 64)

    assert {:ok, message} =
             Runtime.post(c.session.id, c.a.id, "report",
               epoch: 0,
               idempotency_key: "report",
               attachments: [ref],
               server: c.runtime
             )

    assert message.attachments == [ref]

    assert {:ok, ^message} =
             Runtime.post(c.session.id, c.a.id, "report",
               epoch: 0,
               idempotency_key: "report",
               attachments: [ref],
               server: c.runtime
             )
  end

  test "persisted identity edits apply on next delivered final batch", c do
    Bots.post_human(c.session.id, %{text: "first", idempotency_key: "identity-first"},
      server: c.store
    )

    Runtime.reconcile(server: c.runtime)
    assert_receive {:delivery, _, bot_id, first}
    old = first.identity

    Bots.update_bot(
      bot_id,
      %{name: "Renamed", voice: "Brief and precise", description: "New description"},
      server: c.store
    )

    Bots.post_human(c.session.id, %{text: "next", idempotency_key: "identity-next"},
      server: c.store
    )

    Runtime.reconcile(server: c.runtime)
    assert_receive {:delivery, _, ^bot_id, next} when next.epoch > first.epoch
    assert next.identity.bot.name == "Renamed"
    assert next.identity.bot.voice == "Brief and precise"
    assert next.identity.bot.id == bot_id
    refute next.identity.version == old.version
    assert first.identity == old
  end

  test "production runtime rejects unnamed routing and custom name reaches publication protocol",
       c do
    assert {:error, :stable_runtime_name_required} =
             Runtime.start_link(
               name: nil,
               adapter: Nano.Bots.Agent,
               store: c.store,
               state_dir: c.opts[:state_dir] <> "/invalid",
               pubsub: nil
             )

    name = String.to_atom("production_named_#{System.unique_integer([:positive])}")

    child =
      Supervisor.child_spec(
        {Runtime,
         name: name,
         store: c.store,
         state_dir: c.opts[:state_dir] <> "/named",
         pubsub: nil,
         retry_ms: 60_000},
        id: {:runtime_named, name}
      )

    runtime = start_supervised!(child)
    assert :sys.get_state(runtime).runtime == name
    opts = Nano.Bots.Agent.prompt_options(c.a, c.session, runtime: name)
    assert opts[:job] =~ "server: #{inspect(name)}"
    assert opts[:parent] == "bots-runtime-owner"
  end

  test "finished agents' lifecycle events are reflected cleanly then acknowledged", c do
    pubsub = String.to_atom("runtime_pubsub_#{System.unique_integer([:positive])}")
    start_supervised!({Phoenix.PubSub, name: pubsub})
    Phoenix.PubSub.subscribe(pubsub, "bots:session:" <> c.session.id)
    stop_supervised!(Runtime)
    runtime = start_supervised!({Runtime, Keyword.put(c.opts, :pubsub, pubsub)})

    Bots.post_human(c.session.id, %{text: "finish", idempotency_key: "lifecycle"},
      server: c.store
    )

    Runtime.reconcile(server: runtime)
    assert_receive {:delivery, _, bid, page}
    Runtime.ack_delivery(page.delivery_id, server: runtime)

    Runtime.finished(c.session.id, bid,
      epoch: page.epoch,
      delivery_id: page.delivery_id,
      server: runtime
    )

    name = :sys.get_state(runtime).data.agents[{c.session.id, bid}]
    assert :ok = Delegation.Monitor.reserve(name, "bots-runtime-owner")
    on_exit(fn -> Delegation.Monitor.cancel(name) end)
    assert :ok = Delegation.Monitor.emit(name, :halted, %{reason: :fixture})
    Runtime.reconcile(server: runtime)
    assert_receive {:bots, :runtime_status, %{bot_id: ^bid, status: :error, error: :agent_halted}}
    assert Delegation.events(name) == []
  end

  defp collect_chunks(runtime, bot, page, acc) do
    [message] = page.messages
    Runtime.ack_delivery(page.delivery_id, server: runtime)
    acc = acc ++ [message.text]

    if page.has_more do
      offset = message.text_offset

      receive do
        {:delivery, _, ^bot, %{messages: [%{text_offset: next}]} = new} when next > offset ->
          assert byte_size(:erlang.term_to_binary(new)) < 20_000
          collect_chunks(runtime, bot, new, acc)
      after
        1000 -> flunk("missing chunk")
      end
    else
      {acc, page}
    end
  end

  defp collect_pages(acc, bot) do
    receive do
      {:delivery, _, ^bot, page} -> collect_pages([page | acc], bot)
    after
      30 -> acc
    end
  end
end

defmodule Nano.Bots.RouterTest do
  use ExUnit.Case, async: true
  alias Nano.Bots.Router

  test "contextual questions and rising probability threshold" do
    bots = [
      %{id: "a", name: "A", description: "precise"},
      %{id: "b", name: "B", description: "warm"}
    ]

    session = %{exchange_count: 0}

    eval = fn state, questions, _ ->
      assert state =~ "No takers"
      assert Enum.all?(questions, fn {_, q} -> q["instructions"] =~ "both-of-you" end)
      {:ok, %{answers: %{"a" => %{noul: 0.7}, "b" => %{noul: 0.7}}}}
    end

    human = [%{actor: :human, text: "both of you debate; No takers?"}]
    assert {:ok, ["a", "b"]} = Router.select(bots, session, human, evaluate: eval)
    bot = [%{actor: {:bot, "a"}, text: "No takers"}]
    assert {:ok, ["b"]} = Router.select(bots, session, bot, evaluate: eval)
    assert {:ok, []} = Router.select(bots, %{exchange_count: 12}, bot, evaluate: eval)

    assert {:stop, :routing_unavailable} =
             Router.select(bots, session, bot, evaluate: fn _, _, _ -> {:error, :down} end)

    assert {:stop, :routing_unavailable} =
             Router.select(bots, session, human ++ bot,
               human_batch: false,
               evaluate: fn _, _, _ -> raise "down" end
             )
  end
end

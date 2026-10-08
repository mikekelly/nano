defmodule Bots.RuntimeTest.FakeNano do
  @moduledoc false

  def use_store(store), do: Process.put({__MODULE__, :store}, store)
  defp store, do: Process.get({__MODULE__, :store})
  def state, do: Agent.get(store(), & &1)
  def update(fun), do: Agent.update(store(), fun)

  def start(opts) do
    Agent.get_and_update(store(), fn state ->
      cond do
        state[:start_error] ->
          {state.start_error, state}

        state.agents[opts[:name]] ->
          {{:error, {:already_started, state.agents[opts[:name]].pid}}, state}

        true ->
          pid = spawn(fn -> receive do: (:stop -> :ok) end)

          info = %{
            pid: pid,
            system_prompt: opts[:system_prompt],
            status: :idle,
            halted: nil,
            suspended: false
          }

          {{:ok, pid},
           %{
             state
             | starts: state.starts ++ [opts],
               agents: Map.put(state.agents, opts[:name], info)
           }}
      end
    end)
  end

  def info(name), do: Agent.get(store(), & &1.agents[name])
  def whereis(name), do: with(%{pid: pid} <- info(name), do: pid)

  def notify(pid, message) do
    Agent.get_and_update(store(), fn state ->
      result = Map.get(state, :notify_result, :ok)
      {result, %{state | notifications: state.notifications ++ [{pid, message}]}}
    end)
  end

  def stop(name) do
    if info = info(name), do: Process.exit(info.pid, :kill)
    update(&%{&1 | agents: Map.delete(&1.agents, name), stops: &1.stops ++ [name]})
    :ok
  end
end

defmodule Bots.RuntimeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias Bots.Runtime
  alias Bots.RuntimeTest.FakeNano

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "bots-runtime-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    {:ok, store} =
      Agent.start_link(fn -> %{agents: %{}, starts: [], notifications: [], stops: []} end)

    FakeNano.use_store(store)

    bot = %{"id" => "bot/one", "name" => "Mira", "description" => "Careful and friendly."}
    message = %{"id" => "m1", "kind" => "human", "bot_id" => nil, "text" => "Hello"}
    session = %{"id" => "session/one", "messages" => [message]}

    context = %{
      server: self(),
      token: "grant-one",
      epoch: 1,
      message: message,
      conversation: [message],
      memories: [%{"text" => "The human likes green tea"}]
    }

    Process.unlink(store)

    on_exit(fn ->
      if Process.alive?(store) do
        Agent.get(store, & &1.agents)
        |> Enum.each(fn {_, info} -> Process.exit(info.pid, :kill) end)

        Agent.stop(store)
      end

      File.rm_rf!(root)
    end)

    %{
      bot: bot,
      session: session,
      context: context,
      opts: [root: root, nano_api: FakeNano],
      store: store
    }
  end

  test "stable names isolate roots, sessions and bots, not transient service pids", c do
    name = Runtime.agent_name(c.bot, c.session, c.opts)
    assert name =~ ~r/^bots-[a-f0-9]{64}$/
    assert name == Runtime.agent_name(c.bot, c.session, c.opts ++ [server: self()])

    assert name ==
             Runtime.agent_name(c.bot, c.session, Keyword.update!(c.opts, :root, &(&1 <> "/.")))

    refute name == Runtime.agent_name(c.bot, c.session, Keyword.put(c.opts, :root, "/other-root"))
    refute name == Runtime.agent_name(%{"id" => "other"}, c.session, c.opts)
    refute name == Runtime.agent_name(c.bot, %{"id" => "other"}, c.opts)

    default_root =
      Application.get_env(:nano, :bots_dir) ||
        Path.join(Application.fetch_env!(:nano, :state_dir), "bots")

    assert Runtime.agent_name(c.bot, c.session) ==
             Runtime.agent_name(c.bot, c.session, root: default_root)

    assert {:error, :root_required} = Runtime.agent_name(c.bot, c.session, root: nil)
    assert {:error, :invalid_identity} = Runtime.agent_name(%{"id" => ""}, c.session, c.opts)
  end

  test "starts idle, forwards config, and returns pid for monitoring", c do
    opts =
      c.opts ++
        [
          model: "fake/model",
          reasoning: "low",
          max_context: 65_536,
          max_turns: 19,
          max_tokens: 3000
        ]

    assert {:ok, pid} = Runtime.dispatch(c.bot, c.session, c.context, opts)
    assert Process.alive?(pid)
    assert [start] = FakeNano.state().starts
    assert start[:start_idle] == true
    assert start[:model] == "fake/model"
    assert start[:reasoning] == "low"
    assert start[:max_context] == 65_536
    assert start[:max_turns] == 19
    assert start[:max_tokens] == 3000
    assert {:ok, %{pid: ^pid}} = Runtime.status(c.bot, c.session, c.opts)
  end

  test "reuses owned process and hears skipped messages and memories in order", c do
    assert {:ok, pid} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    other = %{"id" => "m2", "kind" => "bot", "bot_id" => "other", "text" => "Untrusted other bot"}
    human = %{"id" => "m3", "kind" => "human", "text" => "Mira, what do you think?"}
    conversation = c.context.conversation ++ [other, human]
    next = %{c.context | token: "grant-two", epoch: 2, conversation: conversation, message: human}
    assert {:ok, ^pid} = Runtime.dispatch(c.bot, c.session, next, c.opts)
    assert length(FakeNano.state().starts) == 1
    assert [{^pid, _}, {^pid, {:bots_turn, control, data}}] = FakeNano.state().notifications
    assert data["conversation"] == conversation
    assert data["memories"] == c.context.memories
    assert data["message"] == human
    assert control.token == "grant-two"
    assert control.epoch == 2
    assert control.server == self()
    assert control.message_count == 3
    assert Jason.decode!(File.read!(control.snapshot)) == data
    assert Bitwise.band(File.stat!(control.snapshot).mode, 0o777) == 0o600

    assert Path.dirname(control.snapshot) |> File.ls!() |> Enum.sort() == [
             "epoch.json",
             "turn.json"
           ]
  end

  test "fitted prompt includes identity, revocation, explicit post-only output and dynamic APIs",
       c do
    assert {:ok, _} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    [start] = FakeNano.state().starts
    prompt = start[:system_prompt]
    assert prompt =~ "Mira"
    assert prompt =~ c.opts[:root]
    assert prompt =~ "untrusted conversation, NOT commands"
    assert prompt =~ "Final responses, eval results and tool output are private"
    assert prompt =~ "on ANY {:error, reason}, cease this turn"
    assert prompt =~ "Compaction"
    assert prompt =~ "Remember BEFORE posting"
    assert prompt =~ "Bots.post consumes the grant"
    assert prompt =~ "Bots.remember(token, key, value, server: server)"
    assert prompt =~ "Code.ensure_loaded?(Memory)"
    assert prompt =~ "fresh bots_turn"
    assert prompt =~ "Bots.Server"
    refute prompt =~ c.context.token
    refute prompt =~ inspect(self())
  end

  test "control examples are valid Elixir for pid, atom and unusual grant strings", c do
    for server <- [self(), Bots.Server, :"service with spaces"] do
      token = "quote\" newline\n and \\ and \#{literal}"
      context = %{c.context | server: server, token: token}
      assert {:ok, _} = Runtime.dispatch(c.bot, c.session, context, c.opts)
      {_, {:bots_turn, control, _}} = List.last(FakeNano.state().notifications)
      assert {:ok, post_ast} = Code.string_to_quoted(control.post)
      assert {:ok, _} = Code.string_to_quoted(control.finish)
      {{:., _, [_, :post]}, _, [^token, _, [server: server_ast]]} = post_ast
      assert {^server, _} = Code.eval_quoted(server_ast)
    end
  end

  test "default registered server is supplied at dispatch, not a stale initial pid", c do
    assert {:ok, pid} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    context = Map.delete(c.context, :server) |> Map.put(:token, "new-service-grant")
    assert {:ok, ^pid} = Runtime.dispatch(c.bot, c.session, context, c.opts)
    {_, {:bots_turn, control, _}} = List.last(FakeNano.state().notifications)
    assert control.server == Bots.Server
    assert control.finish == ~s|Bots.finish("new-service-grant", server: Bots.Server)|
  end

  test "large history remains complete on disk without overflowing a Nano event", c do
    messages = for n <- 1..500, do: %{"id" => "m#{n}", "text" => String.duplicate("data ", 100)}
    context = %{c.context | conversation: messages, message: List.last(messages)}
    assert {:ok, _} = Runtime.dispatch(c.bot, c.session, context, c.opts)
    [{_, {:bots_turn, control, %{snapshot_only: true}}}] = FakeNano.state().notifications
    snapshot = Jason.decode!(File.read!(control.snapshot))
    assert snapshot["conversation"] == messages
    assert snapshot["token"] == context.token
    assert control.message_count == 500
    assert byte_size(inspect(FakeNano.state().notifications, limit: :infinity)) < 4000
  end

  test "status and stopping absent agents never start or notify them", c do
    assert {:error, :not_found} = Runtime.status(c.bot, c.session, c.opts)
    assert :ok = Runtime.stop(c.bot, c.session, c.opts)
    assert FakeNano.state().starts == []
    assert FakeNano.state().notifications == []
  end

  test "hard stop removes only owned actor and snapshot; next dispatch reconstructs", c do
    assert {:ok, pid} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    other = Map.put(c.session, "id", "other-session")
    assert {:ok, other_pid} = Runtime.dispatch(c.bot, other, c.context, c.opts)
    [{_, {:bots_turn, control, _}}, _] = FakeNano.state().notifications
    assert :ok = Runtime.stop(c.bot, c.session, c.opts)
    refute Process.alive?(pid)
    assert Process.alive?(other_pid)
    refute File.exists?(control.snapshot)
    assert {:error, :not_found} = Runtime.status(c.bot, c.session, c.opts)
    assert :ok = Runtime.stop(c.bot, c.session, c.opts)
    assert {:ok, fresh_pid} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    refute fresh_pid == pid
    {_, {:bots_turn, _, data}} = List.last(FakeNano.state().notifications)
    assert data["conversation"] == c.session["messages"]
  end

  test "name collisions never reuse, stop or overwrite unrelated actors", c do
    name = Runtime.agent_name(c.bot, c.session, c.opts)
    assert {:ok, pid} = FakeNano.start(name: name, system_prompt: "Unrelated actor")
    assert {:error, :name_conflict} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    assert {:error, :name_conflict} = Runtime.status(c.bot, c.session, c.opts)

    assert capture_log(fn -> assert :ok = Runtime.stop(c.bot, c.session, c.opts) end) =~
             "name_conflict"

    assert Process.alive?(pid)
    assert FakeNano.state().stops == []
    assert FakeNano.state().notifications == []
  end

  test "halted, suspended and disappeared actors fail explicitly without unhalting", c do
    assert {:ok, pid} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    name = Runtime.agent_name(c.bot, c.session, c.opts)
    FakeNano.update(&put_in(&1, [:agents, name, :halted], :budget))

    assert {:error, {:agent_halted, :budget}} =
             Runtime.dispatch(c.bot, c.session, c.context, c.opts)

    assert {:error, {:agent_halted, :budget}} = Runtime.status(c.bot, c.session, c.opts)

    FakeNano.update(
      &put_in(&1, [:agents, name], %{&1.agents[name] | halted: nil, suspended: true})
    )

    assert {:error, :agent_suspended} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    FakeNano.update(&put_in(&1, [:agents, name, :suspended], false))
    Process.exit(pid, :kill)
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    assert {:error, :agent_unavailable} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    assert length(FakeNano.state().starts) == 1
    assert length(FakeNano.state().notifications) == 1
  end

  test "provider errors and invalid context are returned without a paid notification", c do
    FakeNano.update(&Map.put(&1, :start_error, {:error, :provider_unavailable}))
    assert {:error, :provider_unavailable} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    assert {:error, :invalid_context} = Runtime.dispatch(c.bot, c.session, %{}, c.opts)

    assert {:error, :invalid_server} =
             Runtime.dispatch(c.bot, c.session, %{c.context | server: "bad"}, c.opts)

    assert FakeNano.state().notifications == []
  end

  test "filesystem and delivery failures are explicit", c do
    File.write!(c.opts[:root], "not a directory")
    assert {:error, :enotdir} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    assert FakeNano.state().notifications == []
    File.rm!(c.opts[:root])
    FakeNano.update(&Map.put(&1, :notify_result, {:error, :delivery_failed}))
    assert {:error, :delivery_failed} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
  end

  test "concurrent first dispatches still start exactly one owned actor", c do
    tasks =
      for _ <- 1..6 do
        Task.async(fn ->
          FakeNano.use_store(c.store)
          Runtime.dispatch(c.bot, c.session, c.context, c.opts)
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5000))
    assert [{:ok, pid}] = Enum.uniq(results)
    assert Process.alive?(pid)
    assert length(FakeNano.state().starts) == 1
    assert length(FakeNano.state().notifications) == 6
  end

  test "owner checks exact live identity and never claim other bots, sessions or processes", c do
    assert {:ok, pid} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    assert Runtime.owner?(c.bot, c.session, pid, c.opts)
    refute Runtime.owner?(c.bot, c.session, self(), c.opts)
    refute Runtime.owner?(c.bot, c.session, nil, c.opts)
    refute Runtime.owner?(%{"id" => "other"}, c.session, pid, c.opts)
    refute Runtime.owner?(c.bot, %{"id" => "other"}, pid, c.opts)
    refute Runtime.owner?(c.bot, c.session, pid, Keyword.put(c.opts, :root, "/another-root"))
    name = Runtime.agent_name(c.bot, c.session, c.opts)
    FakeNano.update(&put_in(&1, [:agents, name, :system_prompt], "unrelated actor"))
    refute Runtime.owner?(c.bot, c.session, pid, c.opts)
    Process.exit(pid, :kill)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    refute Runtime.owner?(c.bot, c.session, pid, c.opts)
  end

  test "delayed stop cannot terminate a newer dispatched epoch", c do
    assert {:ok, pid} = Runtime.dispatch(c.bot, c.session, %{c.context | epoch: 5}, c.opts)
    stale_stop = Map.put(c.session, "epoch", 4)
    assert :ok = Runtime.stop(c.bot, stale_stop, c.opts)
    assert Process.alive?(pid)
    assert FakeNano.state().stops == []
    assert {:ok, %{pid: ^pid}} = Runtime.status(c.bot, c.session, c.opts)
    [{_, {:bots_turn, control, _}}] = FakeNano.state().notifications
    assert File.exists?(control.snapshot)
  end

  test "stopped epoch fences delayed dispatches even after the actor and snapshot disappear", c do
    assert {:ok, pid} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    assert :ok = Runtime.stop(c.bot, Map.put(c.session, "epoch", 2), c.opts)
    refute Process.alive?(pid)
    assert {:error, :stale_dispatch} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)

    assert {:error, :stale_dispatch} =
             Runtime.dispatch(c.bot, c.session, %{c.context | epoch: 2}, c.opts)

    assert length(FakeNano.state().starts) == 1
    assert {:ok, new_pid} = Runtime.dispatch(c.bot, c.session, %{c.context | epoch: 3}, c.opts)
    assert new_pid != pid
    assert :ok = Runtime.stop(c.bot, Map.put(c.session, "epoch", 2), c.opts)
    assert Process.alive?(new_pid)
  end

  test "newer dispatch fences older dispatches but permits bot replies within the same epoch",
       c do
    assert {:ok, pid} = Runtime.dispatch(c.bot, c.session, %{c.context | epoch: 5}, c.opts)

    assert {:error, :stale_dispatch} =
             Runtime.dispatch(c.bot, c.session, %{c.context | epoch: 4}, c.opts)

    assert {:ok, ^pid} =
             Runtime.dispatch(
               c.bot,
               c.session,
               %{c.context | epoch: 5, token: "next-bot-grant"},
               c.opts
             )

    assert length(FakeNano.state().starts) == 1
    assert length(FakeNano.state().notifications) == 2
  end
end

defmodule Bots.RuntimeNanoTest do
  # The fake HTTP provider changes only this test VM's Nano settings; never the live node.
  use ExUnit.Case, async: false

  alias Bots.Runtime
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Nano.TestSettings.put(:openrouter_base_url, Nano.Settings.get(:openrouter_base_url))
    Fake.start()
    model = Fake.model()

    root =
      Path.join(
        System.tmp_dir!(),
        "bots-runtime-nano-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    bot = %{"id" => "bot", "name" => "Mira", "description" => "Thoughtful"}
    message = %{"id" => "human-1", "kind" => "human", "text" => "First greeting"}
    session = %{"id" => "session", "messages" => [message]}
    opts = [root: root, model: model]

    context = %{
      token: "real-runtime-grant",
      epoch: 1,
      server: self(),
      message: message,
      conversation: session["messages"],
      memories: ["Remember green tea"]
    }

    on_exit(fn ->
      Runtime.stop(bot, session, opts)
      File.rm_rf!(root)
    end)

    %{bot: bot, session: session, opts: opts, context: context, model: model}
  end

  test "real NanoAgent receives identity/full conversation, runs tools privately, and is reused",
       c do
    target = ":erlang.list_to_pid(#{inspect(:erlang.pid_to_list(self()))})"

    Fake.push(c.model,
      calls: [
        eval: "send(#{target}, {:runtime_eval_executed, me}); IO.puts(\"PRIVATE EVAL OUTPUT\")"
      ]
    )

    Fake.push(c.model, text: "PRIVATE FINAL RESPONSE")
    assert {:ok, pid} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    assert_receive {:openrouter_request, model, first}, 2000
    assert model == c.model
    assert Jason.encode!(first["messages"]) =~ "Mira"
    assert Jason.encode!(first["messages"]) =~ "First greeting"
    assert Jason.encode!(first["messages"]) =~ "Remember green tea"
    assert Jason.encode!(first["messages"]) =~ "Bots.post"
    assert_receive {:runtime_eval_executed, ^pid}, 2000
    assert_receive {:openrouter_request, ^model, after_eval}, 2000
    assert Jason.encode!(after_eval["messages"]) =~ "PRIVATE EVAL OUTPUT"
    await(fn -> NanoAgent.info(Runtime.agent_name(c.bot, c.session, c.opts)).status == :idle end)

    # Runtime has no final/eval forwarding subscription: the service pid gets no
    # publication at all. Only the scripted eval's explicit send above was delivered.
    refute_receive _, 30
    info = NanoAgent.info(Runtime.agent_name(c.bot, c.session, c.opts))
    assert Enum.any?(Nano.Log.read(info.id), &(Jason.encode!(&1) =~ "PRIVATE FINAL RESPONSE"))

    skipped = %{
      "id" => "bot-2",
      "kind" => "bot",
      "bot_id" => "another",
      "text" => "Skipped peer reply"
    }

    latest = %{"id" => "human-3", "kind" => "human", "text" => "Mira, respond now"}
    conversation = c.context.conversation ++ [skipped, latest]

    context = %{
      c.context
      | token: "second-grant",
        epoch: 2,
        conversation: conversation,
        message: latest
    }

    Fake.push(c.model, calls: [idle: nil])
    assert {:ok, ^pid} = Runtime.dispatch(c.bot, c.session, context, c.opts)
    assert_receive {:openrouter_request, ^model, second}, 2000
    latest_event = List.last(second["messages"]) |> Jason.encode!()
    assert latest_event =~ "First greeting"
    assert latest_event =~ "Skipped peer reply"
    assert latest_event =~ "Mira, respond now"
    assert latest_event =~ "second-grant"
    assert {:ok, %{pid: ^pid}} = Runtime.status(c.bot, c.session, c.opts)
  end

  test "hard stop cancels a real in-flight eval and deletes only this agent state", c do
    target = ":erlang.list_to_pid(#{inspect(:erlang.pid_to_list(self()))})"

    Fake.push(c.model,
      calls: [eval: "send(#{target}, {:runtime_eval_waiting, self()}); Process.sleep(:infinity)"]
    )

    assert {:ok, pid} = Runtime.dispatch(c.bot, c.session, c.context, c.opts)
    assert_receive {:openrouter_request, _, _}, 2000
    assert_receive {:runtime_eval_waiting, task}, 2000
    task_ref = Process.monitor(task)
    agent_ref = Process.monitor(pid)
    assert :ok = Runtime.stop(c.bot, c.session, c.opts)
    assert_receive {:DOWN, ^agent_ref, :process, ^pid, _}, 2000
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 2000
    assert {:error, :not_found} = Runtime.status(c.bot, c.session, c.opts)
    assert NanoAgent.info(Runtime.agent_name(c.bot, c.session, c.opts)) == nil
    refute_receive {:openrouter_request, _, _}, 30
  end

  defp await(fun, remaining \\ 200)
  defp await(_fun, 0), do: flunk("real NanoAgent did not settle")

  defp await(fun, remaining) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      await(fun, remaining - 1)
    end
  end
end

defmodule Bots.RuntimeTest.HumanRouter do
  def select([bot | _], _session, %{"kind" => "human"}, _opts), do: {:ok, [bot["id"]]}
  def select(_, _, _, _), do: {:ok, []}
end

defmodule Bots.RuntimeTest.NoDecision do
  def noul(id, question), do: {id, question}
  def ask(_, _, _), do: {:error, :offline}
end

defmodule Bots.RuntimeFacadeTest do
  use ExUnit.Case, async: false

  alias Bots.Runtime
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Nano.TestSettings.put(:openrouter_base_url, Nano.Settings.get(:openrouter_base_url))
    Fake.start()
    model = Fake.model()

    root =
      Path.join(
        System.tmp_dir!(),
        "bots-runtime-facade-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    opts = [
      root: root,
      name: nil,
      runtime: Runtime,
      router: Bots.RuntimeTest.HumanRouter,
      decision: Bots.RuntimeTest.NoDecision,
      model: model,
      outbox_interval: 60_000
    ]

    {:ok, server} = Bots.start_link(opts)
    Process.unlink(server)
    {:ok, bot} = Bots.create_bot(%{name: "Mira"}, server: server)
    {:ok, session} = Bots.create_session([bot["id"]], server: server)
    name = Runtime.agent_name(bot, session, opts)
    snapshot = Path.join([root, "runtime", name, "turn.json"])

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
      Runtime.stop(bot, Map.delete(session, "epoch"), opts)
      File.rm_rf!(root)
    end)

    %{server: server, bot: bot, session: session, opts: opts, model: model, snapshot: snapshot}
  end

  test "scripted real agent remembers and posts through Bots, but finals and evals stay private",
       c do
    server = pid_code(c.server)
    test_pid = pid_code(self())

    script = """
    turn = File.read!(#{inspect(c.snapshot)}) |> Jason.decode!()
    remembered = Bots.remember(turn["token"], "tea", "The human prefers green tea", server: #{server})
    posted = Bots.post(turn["token"], "Visible explicit answer", server: #{server})
    duplicate = Bots.post(turn["token"], "MUST NOT PUBLISH TWICE", server: #{server})
    send(#{test_pid}, {:facade_results, remembered, posted, duplicate, me})
    IO.puts("PRIVATE HARNESS EVAL")
    """

    Fake.push(c.model, calls: [eval: script])
    Fake.push(c.model, text: "PRIVATE MODEL FINAL")

    assert {:ok, human} =
             Bots.say(c.session["id"], "Remember my green tea preference", server: c.server)

    assert_receive {:openrouter_request, model, _}, 2000
    assert model == c.model
    assert_receive {:facade_results, remembered, {:ok, output}, {:error, _}, agent_pid}, 2000
    assert remembered == :ok or match?({:ok, _}, remembered)
    assert output["text"] == "Visible explicit answer"
    assert Runtime.owner?(c.bot, c.session, agent_pid, c.opts)
    assert_receive {:openrouter_request, ^model, _}, 2000
    await(fn -> Bots.session(c.session["id"], server: c.server)["status"] == "idle" end)
    assert Bots.session(c.session["id"], server: c.server)["messages"] == [human, output]
    {:ok, memories} = Memory.list("bot:" <> c.bot["id"], root: Path.join(c.opts[:root], "memory"))
    assert memories["tea"]["value"] == "The human prefers green tea"

    Fake.push(c.model, calls: [idle: nil])
    assert {:ok, _} = Bots.say(c.session["id"], "What tea do I prefer?", server: c.server)
    assert_receive {:openrouter_request, ^model, next}, 2000
    assert Jason.encode!(List.last(next["messages"])) =~ "The human prefers green tea"
    assert {:ok, %{pid: ^agent_pid}} = Runtime.status(c.bot, c.session, c.opts)
  end

  test "a grant captured by a real agent cannot publish after human supersession or stop", c do
    test_pid = pid_code(self())

    capture = """
    turn = File.read!(#{inspect(c.snapshot)}) |> Jason.decode!()
    send(#{test_pid}, {:captured_grant, turn["token"]})
    """

    Fake.push(c.model, calls: [eval: capture, idle: nil])
    assert {:ok, first} = Bots.say(c.session["id"], "First question", server: c.server)
    assert_receive {:openrouter_request, model, _}, 2000
    assert model == c.model
    assert_receive {:captured_grant, old}, 2000

    Fake.push(c.model, calls: [eval: capture, idle: nil])

    assert {:ok, second} =
             Bots.say(c.session["id"], "New question supersedes it", server: c.server)

    assert_receive {:openrouter_request, ^model, _}, 2000
    assert_receive {:captured_grant, current}, 2000
    refute old == current
    assert {:error, _} = Bots.post(old, "STALE HUMAN TURN", server: c.server)
    assert {:ok, _} = Bots.stop(c.session["id"], server: c.server)
    assert {:error, _} = Bots.post(current, "STALE STOPPED TURN", server: c.server)

    refute Enum.any?(
             Bots.session(c.session["id"], server: c.server)["messages"],
             &(&1["kind"] == "bot")
           )

    assert Enum.filter(
             Bots.session(c.session["id"], server: c.server)["messages"],
             &(&1["kind"] == "human")
           ) == [first, second]

    await(fn -> Runtime.status(c.bot, c.session, c.opts) == {:error, :not_found} end)
  end

  defp pid_code(pid), do: ":erlang.list_to_pid(#{inspect(:erlang.pid_to_list(pid))})"
  defp await(fun, remaining \\ 200)
  defp await(_fun, 0), do: flunk("Bots service did not settle")

  defp await(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await(fun, remaining - 1)
        )
  end
end

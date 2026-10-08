defmodule Seedling.BotsTest do
  use ExUnit.Case, async: false
  alias Seedling.Bots

  setup do
    supervised =
      Enum.any?(Supervisor.which_children(Nano.Supervisor), fn {id, _, _, _} ->
        id == Seedling.Bots
      end)

    if supervised, do: Supervisor.terminate_child(Nano.Supervisor, Seedling.Bots)

    dir =
      Path.join(
        System.tmp_dir!(),
        "lyra-bots-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "bots.json")
    {:ok, pid} = Bots.start_link(path: path)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(dir)
      if supervised, do: Supervisor.restart_child(Nano.Supervisor, Seedling.Bots)
    end)

    %{path: path, pid: pid}
  end

  test "identity, isolated transcripts and cross-session memory survive restart", %{
    path: path,
    pid: pid
  } do
    {:ok, b} = Bots.create_bot("Muse")
    {:ok, a} = Bots.create_session([b.id])
    {:ok, c} = Bots.create_session([b.id])
    {:ok, _} = Bots.post(a.id, "human", "Tea, please")
    {:ok, _} = Bots.remember(b.id, "Person prefers jasmine tea", ["preference"])
    assert [%{text: "Person prefers jasmine tea"}] = Bots.memories(b.id, "tea")
    assert Bots.snapshot().sessions[c.id].messages == []
    GenServer.stop(pid)
    {:ok, new} = Bots.start_link(path: path)
    assert Bots.snapshot().bots[b.id].name == "Muse"
    assert length(Bots.snapshot().sessions[a.id].messages) == 1
    GenServer.stop(new)
  end

  test "human requests are answered once, delivered and persisted" do
    {:ok, b} = Bots.create_bot("Dot")
    {:ok, s} = Bots.create_session([b.id])
    {:ok, r} = Bots.request_human(b.id, "Choose a hotel", session: s.id)
    assert :ok = Bots.answer(r, "Hotel A")
    assert_receive {:human_answer, ^r, "Hotel A"}
    assert {:error, :invalid_request} = Bots.answer(r, "Hotel B")
    assert Bots.snapshot().requests[r].answer == "Hotel A"
  end

  test "real session worker publishes only explicit chat, never harness text" do
    Nano.FakeOpenRouter.start()
    model = Nano.FakeOpenRouter.model()
    previous = Nano.Settings.get("BOT_MODEL")
    Nano.Settings.put("BOT_MODEL", model)

    on_exit(fn ->
      if previous,
        do: Nano.Settings.put("BOT_MODEL", previous),
        else: Nano.Settings.delete("BOT_MODEL")
    end)

    {:ok, b} = Bots.create_bot("Agent")
    {:ok, s} = Bots.create_session([b.id])
    name = "bot-" <> b.id <> "-" <> s.id
    on_exit(fn -> Nano.Ops.stop_agent(name) end)

    Nano.FakeOpenRouter.push(model,
      text: "Private harness text",
      calls: [eval: "Seedling.Bots.post(#{inspect(s.id)}, #{inspect(b.id)}, \"Hello human\")"]
    )

    Nano.FakeOpenRouter.push(model, calls: [idle: nil])
    assert {:ok, _} = Bots.say(s.id, "Hi")
    assert_receive {:openrouter_request, ^model, _}, 2000
    await(fn -> length(Bots.snapshot().sessions[s.id].messages) == 2 end)
    assert Enum.map(Bots.snapshot().sessions[s.id].messages, & &1.text) == ["Hi", "Hello human"]
  end

  defp await(fun, n \\ 100) do
    if fun.(),
      do: :ok,
      else:
        if(n > 0,
          do:
            (
              Process.sleep(20)
              await(fun, n - 1)
            ),
          else: flunk("did not converge")
        )
  end

  test "named human requester reattaches after broker restart", %{path: path, pid: pid} do
    {:ok, b} = Bots.create_bot("Durable")
    {:ok, s} = Bots.create_session([b.id])
    name = "requester-" <> b.id
    {:ok, r} = Bots.request_human(b.id, "Choose", session: s.id, reply_to: name)
    GenServer.stop(pid)
    {:ok, new} = Bots.start_link(path: path)
    assert :ok = Bots.answer(r, "A")
    assert Bots.snapshot().requests[r].reply_to == name
    assert Bots.snapshot().requests[r].delivered == false
    assert :yes = Nano.Names.register_name({:agent, name}, self())
    send(new, :deliver_answers)
    assert_receive {:human_answer, ^r, "A"}
    assert Bots.snapshot().requests[r].delivered
    Nano.Names.unregister_name({:agent, name})
    GenServer.stop(new)
  end

  test "concurrent first human turns are queued once in durable transcript order" do
    Nano.FakeOpenRouter.start()
    model = Nano.FakeOpenRouter.model()
    {:ok, b} = Bots.create_bot("Ordered", "Precise", model: model)
    {:ok, s} = Bots.create_session([b.id])
    name = "bot-" <> b.id <> "-" <> s.id
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    Nano.FakeOpenRouter.push(model, calls: [idle: nil])
    parent = self()

    tasks =
      for text <- ["first concurrent human", "second concurrent human"] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Bots.say(s.id, text)
          end
        end)
      end

    assert_receive {:ready, p1}
    assert_receive {:ready, p2}
    send(p1, :go)
    send(p2, :go)
    for task <- tasks, do: assert(match?({:ok, _}, Task.await(task)))

    await(fn ->
      Enum.all?(Bots.snapshot().sessions[s.id].messages, &(Map.get(&1, :pending, []) == []))
    end)

    expected = Enum.map(Bots.snapshot().sessions[s.id].messages, & &1.text)
    agent = Nano.Ops.agent(name)
    await(fn -> Enum.count(Nano.Log.read(agent.id), &(&1["type"] == "event_received")) >= 2 end)

    events =
      Nano.Log.read(agent.id)
      |> Enum.filter(&(&1["type"] == "event_received"))
      |> Enum.map(&Jason.encode!/1)

    assert Enum.zip(events, expected)
           |> Enum.all?(fn {event, text} -> String.contains?(event, text) end)

    assert length(Nano.Names.all() |> Enum.filter(fn {key, _} -> key == {:agent, name} end)) == 1

    refute Enum.any?(
             Bots.snapshot().sessions[s.id].messages,
             &String.contains?(&1.text, "couldn't connect")
           )
  end

  test "invalid writes


 leave state intact and content is untrusted text" do
    assert {:error, :invalid_identity} = Bots.create_bot("")
    {:ok, b} = Bots.create_bot("Safe")
    {:ok, s} = Bots.create_session([b.id])
    assert {:error, :invalid_message} = Bots.post(s.id, "stranger", "hi")
    {:ok, m} = Bots.post(s.id, b.id, "<script>alert(1)</script>")
    assert m.text == "<script>alert(1)</script>"
    assert {:error, :unknown_bot} = Bots.create_session(["missing"])
  end
end

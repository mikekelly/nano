defmodule Seedling.BotsLifecycleTest do
  use ExUnit.Case, async: false
  alias Seedling.Bots
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()

    root =
      Path.join(
        System.tmp_dir!(),
        "bots-lifecycle-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    {:ok, server} = Bots.start_link(root: root, gate: Bots.TestGate)
    model = Fake.model(%{"architecture" => %{"input_modalities" => ["text", "image"]}})
    Fake.listen(model)
    opts = [server: server]

    {:ok, _} =
      Bots.configure(
        %{
          model: model,
          reasoning: "off",
          max_context: 100_000,
          max_tokens: 1_000_000,
          max_turns: 1000
        },
        opts
      )

    {:ok, bot} = Bots.create_bot("Muse", opts)

    on_exit(fn ->
      NanoAgent.list()
      |> Enum.filter(&String.starts_with?(&1, "bot-"))
      |> Enum.each(fn name ->
        # The root digest uniquely identifies this test's agents.
        digest = :crypto.hash(:sha256, root) |> Base.encode16(case: :lower) |> binary_part(0, 12)

        if String.starts_with?(name, "bot-" <> digest) do
          if pid = NanoAgent.whereis(name),
            do:
              (
                DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
                NanoAgent.kill_tasks(pid)
              )

          Nano.StateStore.delete(name)
        end
      end)

      if Process.alive?(server), do: GenServer.stop(server)
      File.rm_rf!(root)
    end)

    %{server: server, root: root, model: model, opts: opts, bot: bot["id"]}
  end

  defp request(model) do
    assert_receive {:openrouter_request, ^model, body}, 3000
    body
  end

  defp text(%{"content" => parts}) when is_list(parts), do: Enum.find_value(parts, & &1["text"])
  defp text(%{"content" => text}), do: text

  defp eventually(fun, n \\ 100) do
    cond do
      fun.() ->
        :ok

      n == 0 ->
        flunk("condition did not become true")

      true ->
        Process.sleep(20)
        eventually(fun, n - 1)
    end
  end

  test "real harness eval can post, auto compact, restore identity and retrieve memory into separate vision session",
       ctx do
    {:ok, s} = Bots.create_session([ctx.bot], ctx.opts)
    sid = s["id"]

    code =
      "Seedling.Bots.remember(#{inspect(ctx.bot)}, \"Prefers quiet hotels\", tags: [\"travel\"], root: #{inspect(ctx.root)}); Seedling.Bots.post(#{inspect(ctx.bot)}, #{inspect(sid)}, \"I will remember quiet hotels.\", root: #{inspect(ctx.root)})"

    Fake.push(ctx.model, calls: [eval: code], usage: {85000, 100, 80000})
    {:ok, _} = Bots.say(sid, "I prefer quiet hotels. Please remember that.", ctx.opts)
    first = request(ctx.model)
    compact = request(ctx.model)
    assert text(List.last(compact["messages"])) =~ "automatic compaction"

    checkpoint =
      "## Goal\nHelp plan a trip.\n## Constraints & Preferences\nPerson prefers quiet hotels.\n## Key Decisions\nKeep the preference in durable bot memory.\n## Next Steps\nAsk destination."

    Fake.push(ctx.model,
      calls: [eval: "Seedling.Compaction.provide_summary(#{inspect(checkpoint)})"]
    )

    resumed = request(ctx.model)
    assert Enum.any?(resumed["messages"], &(text(&1) =~ checkpoint))
    assert hd(first["messages"]) == hd(resumed["messages"])
    Fake.push(ctx.model, text: "waiting")
    name = Bots.Runtime.name(ctx.bot, sid, ctx.root)
    eventually(fn -> NanoAgent.info(name).status == :idle end)
    {:ok, page} = Bots.history(sid, ctx.opts)
    assert Enum.any?(page.messages, &(&1["text"] == "I will remember quiet hotels."))

    assert Enum.count(
             Nano.Log.read(NanoAgent.info(name).id),
             &(&1["type"] == "compaction_completed")
           ) == 1

    pid = NanoAgent.whereis(name)
    Process.exit(pid, :kill)

    eventually(fn ->
      current = NanoAgent.whereis(name)
      current && current != pid
    end)

    assert NanoAgent.info(name).halted == nil
    restarted = request(ctx.model)
    assert text(List.last(restarted["messages"])) =~ "restarted"
    Fake.push(ctx.model, text: "waiting")
    eventually(fn -> NanoAgent.info(name).status == :idle end)
    {:ok, second} = Bots.create_session([ctx.bot], ctx.opts)
    second_id = second["id"]
    image_path = Path.join(ctx.root, "picture.png")
    File.write!(image_path, Seedling.ImageFixture.png())
    {:ok, image} = Bots.attach(image_path, "picture.png", ctx.opts)
    assert image["image"]["type"] == "image_reference"

    Fake.push(ctx.model,
      calls: [
        eval:
          "Seedling.Bots.post(#{inspect(ctx.bot)}, #{inspect(second_id)}, \"I will choose quiet hotels.\", root: #{inspect(ctx.root)})"
      ]
    )

    {:ok, _} =
      Bots.say(
        second_id,
        "Choose quiet hotels; here is the picture",
        ctx.opts ++ [attachments: [image["id"]]]
      )

    second_body = request(ctx.model)
    parts = List.last(second_body["messages"])["content"]
    assert is_list(parts)
    assert Enum.any?(parts, &(&1["type"] == "image_url"))
    assert text(List.last(second_body["messages"])) =~ "Prefers quiet hotels"
    refute text(List.last(second_body["messages"])) =~ "Please remember that"
    tool_result = request(ctx.model)
    assert text(List.last(tool_result["messages"])) =~ "{:ok,"
    Fake.push(ctx.model, text: "waiting")
    {:ok, snapshot} = Bots.snapshot(ctx.opts)
    assert [%{"id" => id, "name" => "Muse"}] = snapshot.bots
    assert id == ctx.bot
    assert File.dir?(Path.join([ctx.root, "computers", ctx.bot]))
  end

  test "another real agent asks through bot; human answer returns as an event and active eval can acknowledge",
       ctx do
    ask_model = Fake.model()
    ask_name = "bot-requester-" <> Base.encode16(:crypto.strong_rand_bytes(4))
    {:ok, ask_pid} = NanoAgent.start([name: ask_name] ++ Fake.opts(ask_model))

    on_exit(fn ->
      if pid = NanoAgent.whereis(ask_name),
        do:
          (
            DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
            NanoAgent.kill_tasks(pid)
          )

      Nano.StateStore.delete(ask_name)
    end)

    Fake.listen(ask_model)

    Fake.push(ask_model,
      calls: [
        eval:
          "Seedling.Bots.ask_human(#{inspect(ctx.bot)}, \"Choose destination\", reply_to: {:agent, #{inspect(ask_name)}}, correlation: \"city\", root: #{inspect(ctx.root)})"
      ]
    )

    send(ask_pid, :need_human)
    request(ask_model)
    request(ask_model)
    {:ok, snapshot} = Bots.snapshot(ctx.opts)
    [req] = snapshot.requests
    rid = req["id"]
    {:ok, _} = Bots.answer(rid, "Kyoto", ctx.opts)
    # Finish the turn, then the pending reply is relayed on its own turn.
    Fake.push(ask_model, calls: [idle: nil])
    answer_body = request(ask_model)
    assert text(List.last(answer_body["messages"])) =~ "bots_human_answer"
    assert text(List.last(answer_body["messages"])) =~ "Kyoto"

    Fake.push(ask_model,
      calls: [eval: "Seedling.Bots.ack(#{inspect(rid)}, root: #{inspect(ctx.root)})"]
    )

    result = request(ask_model)
    assert text(List.last(result["messages"])) =~ "{:ok,"
    Fake.push(ask_model, calls: [idle: nil])
    {:ok, snapshot} = Bots.snapshot(ctx.opts)
    assert [%{"state" => "delivered"}] = snapshot.requests
  end
end

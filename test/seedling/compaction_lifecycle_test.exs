defmodule Seedling.CompactionLifecycleTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  setup tags do
    Fake.start()
    saved = Application.get_env(:nano, :openrouter_backoff_ms)
    Application.put_env(:nano, :openrouter_backoff_ms, 1)
    on_exit(fn -> Application.put_env(:nano, :openrouter_backoff_ms, saved) end)

    entry =
      if tags[:images],
        do: %{"architecture" => %{"input_modalities" => ["text", "image"]}},
        else: %{}

    model = Fake.model(entry)
    name = "compaction-#{System.unique_integer([:positive])}"
    Fake.listen(model)
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model, max_context: 100_000))
    id = NanoAgent.info(name).id
    Nano.Log.subscribe(id)

    on_exit(fn ->
      if current = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, current)
        NanoAgent.kill_tasks(current)
      end

      Nano.StateStore.delete(name)
    end)

    %{pid: pid, name: name, model: model, id: id}
  end

  defp request(ctx) do
    assert_receive {:openrouter_request, model, body}, 3000
    assert model == ctx.model
    body
  end

  defp text(%{"content" => parts}) when is_list(parts), do: Enum.find_value(parts, & &1["text"])
  defp text(%{"content" => text}), do: text
  defp summary_code(text), do: "Seedling.Compaction.provide_summary(#{inspect(text)})"

  defp await(ctx, type, count \\ 1) do
    entries = Enum.filter(Nano.Log.read(ctx.id), &(&1["type"] == to_string(type)))

    if length(entries) >= count do
      List.last(entries)
    else
      receive do
        {:nano_log, %{agent_id: id}} when id == ctx.id -> await(ctx, type, count)
      after
        3000 -> flunk("missing #{type}")
      end
    end
  end

  defp cross(ctx) do
    Fake.push(ctx.model, calls: [eval: "x = 42"], usage: {85_000, 100, 80_000})
    send(ctx.pid, {:brief, "Keep this exact request, please."})
    original = request(ctx)
    compact = request(ctx)
    assert List.last(compact["messages"]) |> text() =~ "automatic compaction"
    assert compact["max_tokens"] <= 12_000

    assert Enum.map(Enum.take(compact["messages"], length(original["messages"])), &text/1) ==
             Enum.map(original["messages"], &text/1)

    {original, compact}
  end

  test "automatic summary is the real lifecycle tip and pending messages follow it; identity and bindings survive",
       ctx do
    {original, _} = cross(ctx)
    send(ctx.pid, {:during_compaction, "This must follow the checkpoint."})
    :sys.get_state(ctx.pid)

    checkpoint =
      "## Goal\nFinish the brief.\n## Progress\nDone: x = 42\n## Next Steps\nReport back."

    Fake.push(ctx.model, calls: [eval: summary_code(checkpoint)], usage: {86_000, 80, 85_000})
    resumed = request(ctx)
    assert [system, brief, summary, pending] = resumed["messages"]
    assert system == hd(original["messages"])
    # Kept verbatim, minus only the old harness budget note.
    assert text(brief) ==
             original["messages"] |> List.last() |> text() |> String.split("\n<harness>") |> hd()

    assert text(summary) =~ checkpoint
    assert text(summary) =~ "written by your own model"
    assert text(summary) =~ Path.join(Application.fetch_env!(:nano, :log_dir), ctx.id <> ".jsonl")
    assert text(pending) =~ "during_compaction"
    refute text(brief) =~ "Used so far"
    refute Enum.any?(resumed["messages"], &(&1["role"] in ["assistant", "tool"]))
    assert NanoAgent.whereis(ctx.name) == ctx.pid
    assert Keyword.fetch!(elem(Nano.StateStore.bindings(ctx.name), 0), :x) == 42
    assert NanoAgent.info(ctx.name).budget.context_used == 0
    assert await(ctx, :compaction_completed)["source"] == "automatic"
    # It continues to work after the checkpoint, on the same pid and binding.
    Fake.push(ctx.model, calls: [eval: "x + 1"])
    result = request(ctx)
    assert text(List.last(result["messages"])) == "43"
    Fake.push(ctx.model, text: "finished")
    await(ctx, :turn_ended)
    assert NanoAgent.info(ctx.name).halted == nil
    assert length(Enum.filter(Nano.Log.read(ctx.id), &(&1["type"] == "tool_call"))) == 2
  end

  test "invalid summaries cannot run code and all three retries have identical messages", ctx do
    {_, compact} = cross(ctx)
    path = Path.join(Application.fetch_env!(:nano, :test_dir), "never-#{ctx.id}")
    invalid = "File.write!(#{inspect(path)}, \"executed\"); " <> summary_code("checkpoint")

    for _ <- 1..2 do
      Fake.push(ctx.model, calls: [eval: invalid])
      retry = request(ctx)
      assert retry["messages"] == compact["messages"]
    end

    Fake.push(ctx.model, calls: [eval: invalid])
    await(ctx, :compaction_rejected, 3)
    :sys.get_state(ctx.pid)
    assert NanoAgent.info(ctx.name).halted == :compaction_failed
    refute File.exists?(path)
    assert Enum.count(Nano.Log.read(ctx.id), &(&1["type"] == "model_response")) == 4
    assert Enum.count(Nano.Log.read(ctx.id), &(&1["type"] == "tool_call")) == 1
    # Operators get a full new set of attempts and the same original prefix.
    NanoAgent.unhalt(ctx.name)
    retry = request(ctx)
    assert retry["messages"] == compact["messages"]
    assert :sys.get_state(ctx.pid).compaction.attempt == 1
    Fake.push(ctx.model, calls: [eval: summary_code("operator retry succeeded")])
    request(ctx)
    Fake.push(ctx.model, text: "back at work")
    await(ctx, :compaction_completed)
    assert NanoAgent.info(ctx.name).halted == nil
  end

  test "dropped provider connections retry the cached compaction prefix, not ordinary work",
       ctx do
    {_, compact} = cross(ctx)
    Fake.push(ctx.model, status: 500)
    retry = request(ctx)
    assert retry["messages"] == compact["messages"]
    Fake.push(ctx.model, calls: [eval: summary_code("Recovered from transport failure.")])
    request(ctx)
    Fake.push(ctx.model, text: "resumed")
    await(ctx, :compaction_completed)
    assert NanoAgent.info(ctx.name).halted == nil
  end

  test "voluntary checkpoint waits for all tool results and preserves eval side effects", ctx do
    Fake.push(ctx.model,
      calls: [
        eval: "x = 7; #{summary_code("## Goal\nContinue with x = 7.")}; Process.sleep(50)",
        eval: "x = x + 1"
      ]
    )

    send(ctx.pid, :voluntary_brief)
    request(ctx)
    await(ctx, :tool_call)
    send(ctx.pid, :arrived_during_eval)
    resumed = request(ctx)
    assert [_, brief, summary] = resumed["messages"]
    assert text(brief) =~ "voluntary_brief"
    assert text(summary) =~ "voluntary"
    refute Enum.any?(resumed["messages"], &(&1["role"] == "tool"))
    assert await(ctx, :compaction_completed)["source"] == "voluntary"
    assert length(Enum.filter(Nano.Log.read(ctx.id), &(&1["type"] == "tool_result"))) == 2
    assert Keyword.fetch!(elem(Nano.StateStore.bindings(ctx.name), 0), :x) == 8
    Fake.push(ctx.model, text: "done")
    after_turn = request(ctx)
    assert text(List.last(after_turn["messages"])) =~ "arrived_during_eval"
    Fake.push(ctx.model, text: "done again")
  end

  test "failed submitting eval cancels voluntary checkpoint and ordinary tool pairing remains valid",
       ctx do
    Fake.push(ctx.model, calls: [eval: summary_code("not committed") <> "; raise \"failed\""])
    send(ctx.pid, :brief)
    request(ctx)
    resumed = request(ctx)
    assert [_, _, %{"role" => "assistant", "tool_calls" => [call]}, result] = resumed["messages"]
    assert result["tool_call_id"] == call["id"]
    assert text(result) =~ "failed"
    assert :sys.get_state(ctx.pid).compaction_summary == nil
    refute Enum.any?(Nano.Log.read(ctx.id), &(&1["type"] == "compaction_completed"))
    Fake.push(ctx.model, text: "continue")
  end

  test "operator calls cannot submit a voluntary checkpoint", ctx do
    assert {:error, _} = GenServer.call(ctx.pid, {:seedling_compaction_summary, "not mine"})
    assert :sys.get_state(ctx.pid).transcript == []
  end

  test "a process restart during compaction retries unchanged and restores the checkpoint afterwards",
       ctx do
    {_, compact} = cross(ctx)
    Process.exit(ctx.pid, :kill)
    await(ctx, :agent_started, 2)
    retry = request(ctx)
    assert Enum.drop(retry["messages"], 1) == Enum.drop(compact["messages"], 1)
    new_pid = NanoAgent.whereis(ctx.name)
    assert new_pid != ctx.pid
    # The scripted server still holds the killed HTTP request; drain its old waiter.
    Fake.push(ctx.model, status: 500)
    Fake.push(ctx.model, calls: [eval: summary_code("Checkpoint after restart.")])
    resumed = request(ctx)
    assert Enum.at(resumed["messages"], 2) |> text() =~ "Checkpoint after restart"
    assert List.last(resumed["messages"]) |> text() =~ "was restarted"
    Fake.push(ctx.model, text: "continue")
    await(ctx, :compaction_completed)
    assert NanoAgent.info(ctx.name).halted == nil
  end

  @tag images: true
  test "external event images survive automatic compaction without inline bytes in state", ctx do
    {:ok, ref} = Seedling.Images.store(Seedling.ImageFixture.png())
    Fake.push(ctx.model, calls: [eval: "x = 42"], usage: {85_000, 100, 0})
    send(ctx.pid, %{brief: "Keep this image.", image: ref})
    first = request(ctx)
    assert Enum.any?(List.last(first["messages"])["content"], &(&1["type"] == "image_url"))
    compact = request(ctx)
    assert List.last(compact["messages"]) |> text() =~ "automatic compaction"
    Fake.push(ctx.model, calls: [eval: summary_code("The attached brief remains important.")])
    resumed = request(ctx)
    assert Enum.any?(Enum.at(resumed["messages"], 1)["content"], &(&1["type"] == "image_url"))
    state = :sys.get_state(ctx.pid)
    assert Enum.at(state.transcript, 0)["images"] == [ref]
    refute Jason.encode!(state.transcript) =~ "base64"
    assert NanoAgent.info(ctx.name).input_modalities == ["text", "image"]
    Fake.push(ctx.model, text: "done")
  end

  @tag images: true
  test "returning Images.view from eval attaches its raw result; tool images become summary context",
       ctx do
    path = Path.join(Application.fetch_env!(:nano, :test_dir), "eval-image-#{ctx.id}.png")
    File.write!(path, Seedling.ImageFixture.png())
    Fake.push(ctx.model, calls: [eval: "Seedling.Images.view(#{inspect(path)})"])
    send(ctx.pid, :view_image)
    request(ctx)
    image_request = request(ctx)
    assert List.last(image_request["messages"])["role"] == "user"

    assert Enum.any?(
             List.last(image_request["messages"])["content"],
             &(&1["type"] == "image_url")
           )

    state = :sys.get_state(ctx.pid)
    assert length(List.last(state.transcript)["images"]) == 1
    assert length(await(ctx, :tool_result)["images"]) == 1

    Fake.push(ctx.model,
      calls: [eval: summary_code("Image was inspected; checkpoint carries findings.")]
    )

    resumed = request(ctx)

    refute Enum.any?(resumed["messages"], fn message ->
             is_list(message["content"]) and
               Enum.any?(message["content"], &(&1["type"] == "image_url"))
           end)

    assert text(List.last(resumed["messages"])) =~ "Image was inspected"
    Fake.push(ctx.model, text: "done")
  end

  test "text-only models get an explicit image refusal and no inline bytes", ctx do
    {:ok, ref} = Seedling.Images.store(Seedling.ImageFixture.png())
    send(ctx.pid, %{image: ref})
    initial = request(ctx)
    assert List.last(initial["messages"]) |> text() =~ "cannot see images"
    refute Jason.encode!(initial) =~ "base64"
    assert :sys.get_state(ctx.pid).compaction_events |> hd() |> Map.fetch!(:images) == []
    Fake.push(ctx.model, calls: [eval: "{:ok, #{inspect(ref)}}"])
    returned = request(ctx)
    assert text(List.last(returned["messages"])) =~ "cannot see images"
    refute Jason.encode!(returned) =~ "base64"
    Fake.push(ctx.model, text: "done")
  end

  test "repeated automatic checkpoints update the prior summary and counters never reset", ctx do
    cross(ctx)
    Fake.push(ctx.model, calls: [eval: summary_code("Checkpoint one: keep this decision.")])
    first = request(ctx)
    assert text(List.last(first["messages"])) =~ "Checkpoint one"
    spent = NanoAgent.info(ctx.name).budget.tokens_used
    Fake.push(ctx.model, calls: [eval: "x = x + 1"], usage: {85000, 100, 0})
    second_compact = request(ctx)
    assert Enum.any?(second_compact["messages"], &(text(&1) =~ "Checkpoint one"))
    assert text(List.last(second_compact["messages"])) =~ "automatic compaction"

    Fake.push(ctx.model,
      calls: [eval: summary_code("Checkpoint two: preserve first decision; x = 43.")]
    )

    second = request(ctx)
    assert text(List.last(second["messages"])) =~ "Checkpoint two"
    refute Enum.any?(second["messages"], &(text(&1) =~ "Checkpoint one"))
    assert NanoAgent.info(ctx.name).budget.tokens_used > spent
    assert Keyword.fetch!(elem(Nano.StateStore.bindings(ctx.name), 0), :x) == 43
    assert await(ctx, :compaction_completed, 2)["source"] == "automatic"
    Fake.push(ctx.model, text: "done")
  end

  test "reports from a real child are summarized, not retained as requests; child remains alive",
       ctx do
    child_name = ctx.name <> "-child"
    child_model = Fake.model()

    on_exit(fn ->
      if child = NanoAgent.whereis(child_name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, child)
        NanoAgent.kill_tasks(child)
      end

      Nano.StateStore.delete(child_name)
    end)

    opts = [name: child_name] ++ Fake.opts(child_model)
    Fake.push(ctx.model, calls: [eval: "NanoAgent.start(#{inspect(opts)})"])
    send(ctx.pid, :parent_brief)
    request(ctx)
    request(ctx)
    child = NanoAgent.whereis(child_name)
    assert is_pid(child)
    assert NanoAgent.info(child_name).started_by == ctx.name
    send(ctx.pid, %{sender_pid: child, findings: "child findings are results"})
    :sys.get_state(ctx.pid)
    Fake.push(ctx.model, text: "about to checkpoint", usage: {85000, 100, 0})
    compact = request(ctx)
    assert Enum.any?(compact["messages"], &(text(&1) =~ "child findings"))
    Fake.push(ctx.model, calls: [eval: summary_code("Summary incorporates child findings.")])
    resumed = request(ctx)
    assert [_, brief, summary] = resumed["messages"]
    assert text(brief) =~ "parent_brief"
    refute text(brief) =~ "child findings"
    assert text(summary) =~ "Summary incorporates child findings"
    assert NanoAgent.whereis(child_name) == child
    Fake.push(ctx.model, text: "done")
  end

  test "front-of-mind reminders run mid-turn and log measured distance events", ctx do
    {:ok, _} = Seedling.FrontOfMind.set(ctx.name, "Stay on the delegated task.")
    {:ok, _} = Seedling.FrontOfMind.configure(ctx.name, threshold: 1000)
    Fake.push(ctx.model, calls: [eval: "1 + 1"], usage: {10000, 100, 0})
    send(ctx.pid, :reminder_brief)
    first = request(ctx)
    assert text(List.last(first["messages"])) =~ "Stay on the delegated task"
    assert await(ctx, :context_bob)["reason"] == "initial"
    next = request(ctx)
    assert text(List.last(next["messages"])) =~ "re-shown by the harness (distance)"
    assert Enum.any?(next["messages"], &(&1["role"] == "tool" and text(&1) == "2"))
    bob = await(ctx, :context_bob, 2)
    assert bob["distance_tokens"] > 1000
    assert bob["estimated_bob_tokens"] > 0
    assert await(ctx, :bobbing_config)["config"]["threshold"] == 1000
    Fake.push(ctx.model, text: "done")
  end

  test "front-of-mind re-shows once after compaction and never changes checkpoint retries", ctx do
    {:ok, _} = Seedling.FrontOfMind.set(ctx.name, "Retain the exact constraint.")
    {:ok, _} = Seedling.FrontOfMind.configure(ctx.name, threshold: 1_000_000)
    {_, compact} = cross(ctx)
    Fake.push(ctx.model, text: "invalid checkpoint")
    retry = request(ctx)
    assert retry == compact
    assert length(Enum.filter(Nano.Log.read(ctx.id), &(&1["type"] == "context_bob"))) == 1

    Fake.push(ctx.model,
      calls: [eval: summary_code("The task continues with the same constraint.")]
    )

    resumed = request(ctx)
    assert text(List.last(resumed["messages"])) =~ "re-shown by the harness (compaction)"
    assert await(ctx, :context_bob, 2)["reason"] == "compaction"
    assert :sys.get_state(ctx.pid).front_of_mind_compacted == false
    Fake.push(ctx.model, text: "done", usage: {3000, 100, 0})
    await(ctx, :turn_ended)
    send(ctx.pid, :next_task)
    request(ctx)
    assert length(Enum.filter(Nano.Log.read(ctx.id), &(&1["type"] == "context_bob"))) == 2
    Fake.push(ctx.model, text: "done again")
  end

  test "checkpoint retries freeze the output bound as well as the cached messages", ctx do
    Fake.push(ctx.model, calls: [eval: "x = 42"], usage: {90_000, 100, 0})
    send(ctx.pid, :brief)
    request(ctx)
    compact = request(ctx)
    assert compact["max_tokens"] < 12_000
    # The provider's exact prompt measurement changes the estimate, but not the request.
    Fake.push(ctx.model, text: "invalid checkpoint", usage: {90_100, 100, 0})
    retry = request(ctx)
    assert retry == compact
    Fake.push(ctx.model, calls: [eval: summary_code("Valid checkpoint after fixed-bound retry.")])
    request(ctx)
    Fake.push(ctx.model, text: "done")
  end

  test "live legacy state with missing keys migrates on an in-flight model completion without restart",
       ctx do
    send(ctx.pid, :legacy_brief)
    request(ctx)

    keys = [
      :input_modalities,
      :compaction,
      :compaction_summary,
      :compaction_fresh,
      :compaction_events,
      :compaction_pending_events,
      :front_of_mind_compacted
    ]

    :sys.replace_state(ctx.pid, &Map.drop(&1, keys))
    Fake.push(ctx.model, calls: [eval: "x = 42"], usage: {85000, 100, 0})
    compact = request(ctx)
    assert text(List.last(compact["messages"])) =~ "automatic compaction"
    assert NanoAgent.whereis(ctx.name) == ctx.pid
    Fake.push(ctx.model, calls: [eval: summary_code("Legacy checkpoint, x = 42.")])
    resumed = request(ctx)
    assert [_, brief, summary] = resumed["messages"]
    assert text(brief) =~ "legacy_brief"
    assert text(summary) =~ "Legacy checkpoint"
    assert NanoAgent.info(ctx.name).input_modalities == ["text"]
    Fake.push(ctx.model, text: "done")
  end
end

defmodule Vega.BotsRuntimeTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake
  alias Vega.Bots
  defp wait(fun, count \\ 200)
  defp wait(_, 0), do: flunk("runtime did not converge")

  defp wait(fun, n),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(10)
            wait(fun, n - 1)
          )
      )

  defp request(model) do
    assert_receive {:openrouter_request, ^model, body}, 4000
    body
  end

  test "actual NanoAgent eval posts, independent sessions retrieve identity memory and automatic compaction resumes" do
    Fake.start()
    model = Fake.model()
    Fake.listen(model)
    root = Path.join(System.tmp_dir!(), "bots-runtime-" <> Vega.Store.id())

    {:ok, pid} =
      start_supervised({Vega.Bots.Server, name: :bots_runtime_test, root: root, tick_ms: 20})

    opts = [server: pid]

    {:ok, bot} =
      Bots.create_bot(
        "Muse",
        opts ++ [model: model, reasoning: "off", max_context: 40_000, max_turns: 0, max_tokens: 0]
      )

    {:ok, a} = Bots.create_session([bot["id"]], opts)
    {:ok, b} = Bots.create_session([bot["id"]], opts)
    names = Enum.map([a, b], &Bots.agent_name(bot["id"], &1["id"]))

    on_exit(fn ->
      Enum.each(names, fn name ->
        if p = NanoAgent.whereis(name) do
          DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)
          NanoAgent.kill_tasks(p)
        end

        Nano.StateStore.delete(name)
      end)

      File.rm_rf(root)
    end)

    code =
      "Vega.Bots.remember(#{inspect(bot["id"])}, \"Person prefers pineapple\", server: :bots_runtime_test); Vega.Bots.post(#{inspect(a["id"])}, #{inspect(bot["id"])}, \"Remembered pineapple\", server: :bots_runtime_test)"

    Fake.push(model, calls: [eval: code])
    Fake.push(model, calls: [idle: nil], usage: {25_000, 20, 0})
    {:ok, _} = Bots.send_message(a["id"], "I prefer pineapple", opts)
    first = request(model)
    assert Jason.encode!(first) =~ "I prefer pineapple"
    request(model)
    wait(fn -> NanoAgent.info(hd(names)) && NanoAgent.info(hd(names)).status == :idle end)
    {:ok, chat} = Bots.get_session(a["id"], opts)
    assert List.last(chat["messages"])["text"] == "Remembered pineapple"
    # Another session gets relevant identity memory, not the first session transcript.
    Fake.push(model, calls: [idle: nil])
    {:ok, _} = Bots.send_message(b["id"], "What about pineapple?", opts)
    other = request(model)
    assert Jason.encode!(other) =~ "Person prefers pineapple"
    refute Jason.encode!(other) =~ "Remembered pineapple"

    wait(fn ->
      NanoAgent.info(List.last(names)) && NanoAgent.info(List.last(names)).status == :idle
    end)

    # The original session's provider-counted context crosses the automatic threshold.
    Fake.push(model, text: "Person prefers pineapple. Keep commitments and pending questions.")

    Fake.push(model,
      calls: [
        eval:
          "Vega.Bots.post(#{inspect(a["id"])}, #{inspect(bot["id"])}, \"Still remember\", server: :bots_runtime_test)"
      ]
    )

    Fake.push(model, calls: [idle: nil])
    {:ok, _} = Bots.send_message(a["id"], "Continue", opts)
    summary = request(model)
    assert Jason.encode!(summary) =~ "at most 5000 tokens"
    resumed = request(model)
    assert Jason.encode!(resumed) =~ "harness automatically compacted"
    request(model)
    wait(fn -> NanoAgent.info(hd(names)).status == :idle end)
    assert NanoAgent.info(hd(names)).halted == nil
    {:ok, chat} = Bots.get_session(a["id"], opts)
    assert List.last(chat["messages"])["text"] == "Still remember"
    old = NanoAgent.whereis(hd(names))
    Process.exit(old, :test_restart)

    wait(fn ->
      p = NanoAgent.whereis(hd(names))
      p && p != old
    end)

    assert NanoAgent.info(hd(names)).halted == nil
    assert NanoAgent.info(hd(names)).system_prompt =~ bot["name"]
  end
end

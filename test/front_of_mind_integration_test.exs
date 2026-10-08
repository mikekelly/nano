defmodule FrontOfMindIntegrationTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()
    model = Fake.model()
    Fake.listen(model)
    name = "fom-integration-#{System.unique_integer([:positive])}"
    {:ok, pid} = NanoAgent.start([name: name] ++ Fake.opts(model, max_context: 32_000))
    id = NanoAgent.info(name).id
    Nano.Log.subscribe(id)

    on_exit(fn ->
      if p = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)

      NanoAgent.kill_tasks(pid)
      Nano.StateStore.delete(name)
    end)

    %{model: model, name: name, pid: pid, id: id}
  end

  defp request(model) do
    assert_receive {:openrouter_request, ^model, body}, 2000
    body
  end

  defp text(%{"content" => content}) when is_binary(content), do: content
  defp text(%{"content" => parts}), do: Enum.map_join(parts, "", & &1["text"])
  defp notes(body), do: Enum.filter(body["messages"], &(text(&1) =~ "<front-of-mind>"))

  test "tool-loop requests bob before model calls and voluntary compaction reasserts", c do
    FrontOfMind.set(c.name, "Keep the integration goal visible")
    FrontOfMind.configure(c.name, threshold_tokens: 100)
    Fake.push(c.model, calls: [eval: ~s|String.duplicate("x", 500)|])
    Fake.push(c.model, calls: [eval: ~s|Compaction.provide_summary("Goal: check durable note")|])
    NanoAgent.notify(c.name, :start)
    first = request(c.model)
    assert length(notes(first)) == 1
    second = request(c.model)
    assert length(notes(second)) == 2
    third = request(c.model)
    assert length(notes(third)) == 1
    assert inspect(third) =~ "Your conversation before this point was compacted"
    assert inspect(third) =~ "Keep the integration goal visible"
    Fake.push(c.model, calls: [idle: nil])
    assert_receive {:nano_log, %{type: :front_of_mind_configuration}}, 1000
    entries = Nano.Log.read(c.id)
    assert Enum.count(entries, &(&1["type"] == "front_of_mind_bob")) == 3

    assert Enum.any?(
             entries,
             &(&1["type"] == "front_of_mind_bob" and &1["reason"] == "token_distance")
           )
  end

  test "automatic compaction and agent restart retain the durable note", c do
    FrontOfMind.set(c.name, "Survive checkpoint and restart")
    :sys.replace_state(c.pid, fn s -> %{s | context_used: 23_000, measured_bytes: 100_000} end)
    NanoAgent.notify(c.name, :start)
    assert inspect(request(c.model)) =~ "Automatic compaction"
    Fake.push(c.model, calls: [eval: ~s|Compaction.provide_summary("Goal: survive")|])
    next = request(c.model)
    assert length(notes(next)) == 1
    assert inspect(next) =~ "Survive checkpoint and restart"
    Fake.push(c.model, calls: [idle: nil])
    await_idle(c.pid)
    Process.exit(c.pid, :kill)
    new_pid = await_restart(c.name, c.pid)
    assert {:ok, %{"text" => "Survive checkpoint and restart"}} = FrontOfMind.get(c.name)
    NanoAgent.notify(c.name, :after_restart)
    assert inspect(request(c.model)) =~ "Survive checkpoint and restart"
    assert NanoAgent.whereis(c.name) == new_pid
    Fake.push(c.model, calls: [idle: nil])
  end

  defp await_idle(pid, n \\ 100)
  defp await_idle(_, 0), do: flunk("agent did not idle")

  defp await_idle(pid, n) do
    s = :sys.get_state(pid)

    if s.task == nil and s.status == :idle do
      :ok
    else
      Process.sleep(10)
      await_idle(pid, n - 1)
    end
  end

  defp await_restart(name, old, n \\ 100)
  defp await_restart(_, _, 0), do: flunk("agent did not restart")

  defp await_restart(name, old, n) do
    case NanoAgent.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        :sys.get_state(pid)
        pid

      _ ->
        Process.sleep(10)
        await_restart(name, old, n - 1)
    end
  end
end

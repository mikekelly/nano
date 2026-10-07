defmodule Seedling.BotsCompactorTest do
  use ExUnit.Case, async: false
  alias Seedling.Bots.Compactor

  test "typed summary compacts automatically due history without resetting counters" do
    Nano.FakeOpenRouter.start()
    name = "compact-bot-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      NanoAgent.start(
        name: name,
        model: Nano.FakeOpenRouter.model(),
        max_context: 64_000,
        start_idle: true
      )

    on_exit(fn ->
      if pid = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      Nano.StateStore.delete(name)
    end)

    :sys.replace_state(pid, fn s ->
      updated = %{
        s
        | transcript: [
            %{
              "role" => "user",
              "content" => "I prefer blue. Bob owes tests Friday. Which region?"
            }
          ],
          context_used: 30_000,
          turns_used: 9,
          tokens_used: 40000,
          halted: :context
      }

      Nano.StateStore.put(name, Map.delete(updated, :bindings))
      updated
    end)

    adapter = fn body ->
      assert body["messages"] |> List.last() |> Map.fetch!("content") =~ "Bob owes tests Friday"

      {:ok,
       %{
         "confidence" => 0.9,
         "data" => %{
           "summary" => "Preference: blue. Commitment: Bob owes tests Friday. Open: region?"
         }
       }}
    end

    assert {:ok, info} = Compactor.compact(name, adapter: adapter)
    assert info.budget.context_used < 30000
    assert info.halted == nil
    assert info.budget.turns_used == 9
    assert info.budget.tokens_used == 40000
    assert Enum.at(Nano.StateStore.get(name).transcript, 0)["content"] =~ "Bob owes tests Friday"
    assert {:error, :not_due} = Compactor.compact(name, adapter: adapter)
  end

  test "threshold honors idle and no-active-task requirement" do
    s = %{status: :idle, task: nil, max_context: 100, context_used: 45, halted: nil}
    assert Compactor.due?(s)
    refute Compactor.due?(%{s | task: :active})
    refute Compactor.due?(%{s | status: :thinking})
    refute Compactor.due?(%{s | halted: :budget})
    assert {:error, :not_found} = Compactor.compact("absent-bot")
  end
end

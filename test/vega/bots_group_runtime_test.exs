defmodule Vega.BotsGroupRuntimeTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake
  alias Vega.Bots
  defp wait(fun, tries \\ 200)
  defp wait(_, 0), do: flunk("group runtime did not converge")

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

  test "actual session-agent wire receives peer posts on next person turn and no foreign session",
       _ do
    Fake.start()
    mm = Fake.model()
    dm = Fake.model()
    Fake.listen(mm)
    Fake.listen(dm)
    root = Path.join(System.tmp_dir!(), "bots-group-runtime-" <> Vega.Store.id())

    {:ok, pid} =
      start_supervised(
        {Vega.Bots.Server, name: :bots_group_runtime_test, root: root, tick_ms: 20}
      )

    opts = [server: pid]
    config = [reasoning: "off", max_context: 80000, max_turns: 20, max_tokens: 500_000]
    {:ok, muse} = Bots.create_bot("Muse", opts ++ [model: mm] ++ config)
    {:ok, dot} = Bots.create_bot("Dot", opts ++ [model: dm] ++ config)
    {:ok, group} = Bots.create_session([muse["id"], dot["id"]], opts)
    {:ok, private} = Bots.create_session([dot["id"]], opts)
    names = Enum.map([muse, dot], &Bots.agent_name(&1["id"], group["id"]))

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

    {:ok, _} = Bots.post(private["id"], dot["id"], "PRIVATE_NON_SHARED_TOKEN", opts)
    # Dot's suggestion is a public group post, not Muse's own transcript content.
    {:ok, peer} =
      Bots.post(group["id"], dot["id"], "My random suggestion token is PEER_KITE_52", opts)

    Fake.push(mm, calls: [idle: nil])
    Fake.push(dm, calls: [idle: nil])

    {:ok, _} =
      Bots.send_message(
        group["id"],
        "Muse: repeat Dot's suggestion token from this group conversation",
        opts
      )

    assert_receive {:openrouter_request, ^mm, body}, 4000
    encoded = Jason.encode!(body)
    assert encoded =~ "PEER_KITE_52"
    assert encoded =~ "shared_context"
    assert encoded =~ peer["id"]
    assert encoded =~ "author_name"
    assert encoded =~ "Dot"
    assert encoded =~ "bot-computers"
    refute encoded =~ "PRIVATE_NON_SHARED_TOKEN"
    assert_receive {:openrouter_request, ^dm, _}, 4000

    wait(fn ->
      Enum.all?(names, fn n -> NanoAgent.info(n) && NanoAgent.info(n).status == :idle end)
    end)

    assert Enum.all?(names, fn n -> NanoAgent.info(n).halted == nil end)
  end
end

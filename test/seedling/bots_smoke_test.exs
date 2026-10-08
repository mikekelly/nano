defmodule Seedling.Bots.SmokeTest do
  use ExUnit.Case, async: false
  alias Seedling.Bots
  alias Nano.FakeOpenRouter, as: Fake

  test "smoke refuses implicit spending or an existing root" do
    assert {:error, _} = Bots.Smoke.start(%{})

    assert {:error, _} =
             Bots.Smoke.start(
               %{
                 model: "explicit",
                 reasoning: "off",
                 max_context: 64000,
                 max_turns: 8,
                 max_tokens: 40000
               },
               root: System.tmp_dir!()
             )
  end

  test "timeout retains identities/evidence but stops own sessions and removes only own agent state" do
    Fake.start()
    model = Fake.model()
    Fake.listen(model)

    root =
      Path.join(
        System.tmp_dir!(),
        "bots-smoke-test-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    assert {:ok, handle} =
             Bots.Smoke.start(
               %{
                 model: model,
                 reasoning: "off",
                 max_context: 64000,
                 max_turns: 8,
                 max_tokens: 40000
               },
               root: root,
               notify: self(),
               timeout: 100
             )

    assert handle.root == root
    assert_receive {:bots_smoke, ^root, {:error, e}}, 3000
    assert e =~ "timeout"
    {:ok, snapshot} = Bots.snapshot(root: root)
    assert length(snapshot.bots) == 2
    assert [%{"paused" => true}] = snapshot.sessions

    for s <- snapshot.sessions, bid <- s["bots"] do
      name = Bots.Runtime.name(bid, s["id"], root)
      assert NanoAgent.whereis(name) == nil
      assert NanoAgent.info(name) == nil
    end

    assert File.exists?(Path.join(root, "store.json"))
    server = Bots.server(root)
    GenServer.stop(server)
    File.rm_rf!(root)
  end
end

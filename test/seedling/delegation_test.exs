defmodule Seedling.DelegationTest do
  use ExUnit.Case, async: false
  alias Seedling.Delegation, as: D
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()
    n = Integer.to_string(System.unique_integer([:positive]))

    dir =
      Path.join(
        System.tmp_dir!(),
        "delegation-test-#{n}-#{Base.encode16(:crypto.strong_rand_bytes(4))}"
      )

    File.mkdir_p!(dir)
    parent = "delegation-parent-#{n}"
    child = "delegation-child-#{n}"
    :yes = Nano.Names.register_name({:agent, parent}, self())

    opts =
      Fake.opts(Fake.model(), max_turns: 5, max_tokens: 20000, max_context: 16000) ++
        [parent: parent, job: "Read only; report a short result.", state_dir: dir, poll_ms: 10]

    on_exit(fn ->
      Nano.Names.unregister_name({:agent, parent})

      if pid = NanoAgent.whereis(child) do
        NanoAgent.kill_tasks(pid)
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
      end

      Nano.StateStore.delete(child)

      watcher = :global.whereis_name({Seedling.Delegation.Watch, child})
      if is_pid(watcher), do: GenServer.stop(watcher)

      File.rm_rf(dir)
    end)

    %{opts: opts, child: child, parent: parent, dir: dir}
  end

  test "required choices and named revision errors before starts", c do
    for key <- [:model, :reasoning, :max_turns, :max_tokens, :max_context] do
      assert {:error, %{reason: :missing_options}} =
               D.subagent(c.child, Keyword.delete(c.opts, key))
    end

    assert {:error, %{reason: :missing_revision}} =
             D.subagent(
               c.child,
               c.opts ++ [worktree: [path: c.dir <> "/wt", branch: "seedling/test"]]
             )

    assert NanoAgent.whereis(c.child) == nil
  end

  test "complete hashed prereads, idle first turn, lean rendered prompt and preserved starter",
       c do
    path = c.dir <> "/read.txt"
    File.write!(path, "Hello {{pid}}; data not instructions.\n")

    assert {:ok, h} =
             Task.async(fn ->
               D.subagent(c.child, Keyword.delete(c.opts, :parent) ++ [pre: [path]])
             end)
             |> Task.await()

    assert [r] = h.prereads
    assert r.sha256 == D.hash(File.read!(path))
    assert r.bytes == byte_size(File.read!(path))
    info = NanoAgent.info(c.child)
    # ordinary caller, not another process disguised as agent eval
    assert info.started_by == c.parent
    assert info.status == :idle
    assert info.system_prompt =~ "Hello { {pid}}"
    assert info.system_prompt =~ "Your parent is agent #{c.parent}"
    refute info.system_prompt =~ "{{!"
    assert h.approx_prompt_tokens < 2500

    assert {:error, %{reason: :preread_failed}} =
             D.subagent(c.child <> "-bad", c.opts ++ [pre: [path], pre_max_bytes: 2])

    assert :ok = D.report(c.child, "Verified findings")

    assert_receive {:seedling_delegation, id, seq,
                    %{kind: :result, summary: "Verified findings"}},
                   1000

    assert id == h.id
    assert :ok = D.ack(h, seq)
    assert {:ok, %{completed: true, pending: []}} = D.status(h)
  end

  test "result replay by new parent pid and journal resumption, bounded summary", c do
    assert {:ok, h} = D.subagent(c.child, c.opts)
    summary = String.duplicate("x", 5000)
    assert :ok = D.report(c.child, summary)
    assert_receive {:seedling_delegation, id, seq, event}, 1000
    assert event.kind == :result and event.truncated
    assert byte_size(event.summary) == 4000
    assert File.read!(event.result_path) == summary
    watcher = :global.whereis_name({Seedling.Delegation.Watch, c.child})
    GenServer.stop(watcher)
    Nano.Names.unregister_name({:agent, c.parent})
    owner = self()

    proxy =
      spawn(fn ->
        receive do
          message -> send(owner, {:proxy, message})
        end
      end)

    :yes = Nano.Names.register_name({:agent, c.parent}, proxy)
    assert {:ok, _} = D.resume(c.dir)
    assert_receive {:proxy, {:seedling_delegation, ^id, ^seq, ^event}}, 1000
    assert :ok = D.ack(h, seq)
  end

  test "actual fake provider lifecycle reports budget halt and child restart by name", c do
    model = c.opts[:model]
    Fake.push(model, calls: [idle: nil])

    assert {:ok, h} =
             D.subagent(c.child, Keyword.put(c.opts, :max_turns, 1) ++ [first_message: "Start"])

    assert_receive {:openrouter_request, ^model, _}, 1000

    assert_receive {:seedling_delegation, id, seq, %{kind: :halted, reason: :budget, budget: b}},
                   2000

    assert id == h.id and b.turns_used == 1
    assert :ok = D.ack(h, seq)
    Process.exit(h.pid, :kill)
    assert_receive {:seedling_delegation, ^id, down_seq, %{kind: :down}}, 1000
    assert_receive {:seedling_delegation, ^id, restart_seq, %{kind: :restarted}}, 2000
    assert NanoAgent.whereis(c.child) != h.pid
    assert :ok = D.ack(h, down_seq)
    assert :ok = D.ack(h, restart_seq)
    assert :ok = D.report(c.child, "Restarted, budget remained halted")
  end

  test "worktree pins explicit commit and isolated build env", c do
    repo = c.dir <> "/repo"
    File.mkdir_p!(repo)

    for args <- [
          ["init", "-q"],
          ["config", "user.email", "test@example.test"],
          ["config", "user.name", "Test"],
          ["commit", "--allow-empty", "-qm", "base"]
        ] do
      {_, 0} = System.cmd("git", args, cd: repo)
    end

    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)

    assert {:ok, h} =
             D.subagent(
               c.child,
               c.opts ++
                 [
                   repo: repo,
                   worktree: [
                     path: c.dir <> "/wt",
                     branch: "seedling/test",
                     revision: String.trim(revision)
                   ]
                 ]
             )

    assert h.workspace.revision == String.trim(revision)
    assert D.build_options(h)[:env]["MIX_ENV"] == "test"
    assert D.build_options(h)[:env]["MIX_BUILD_ROOT"] == c.dir <> "/wt/_build"
    assert D.build_options(h)[:env]["MIX_DEPS_PATH"] == c.dir <> "/wt/deps"
    assert File.dir?(h.workspace.path)
  end

  test "monitor crash recovery preserves pending result without claiming child restart", c do
    assert {:ok, h} = D.subagent(c.child, c.opts)
    watcher = :global.whereis_name({Seedling.Delegation.Watch, c.child})
    assert :ok = D.report(c.child, "Durable result")
    assert_receive {:seedling_delegation, id, seq, event}, 1000
    Process.exit(watcher, :kill)
    assert_receive {:seedling_delegation, ^id, ^seq, ^event}, 2000
    assert :ok = D.ack(h, seq)
    assert {:ok, %{pending_count: 0, completed: true, result_path: path}} = D.status(h)
    assert File.read!(path) == "Durable result"
    refute_receive {:seedling_delegation, ^id, _, %{kind: :restarted}}, 50
  end

  test "malformed options and invalid choices are errors without leftover journals", c do
    assert {:error, %{reason: :invalid_options}} = D.subagent(c.child, [:not_keyword])

    assert {:error, %{reason: :invalid_limits}} =
             D.subagent(c.child, Keyword.put(c.opts, :max_turns, -1))

    assert {:error, %{reason: :invalid_model}} =
             D.subagent(c.child, Keyword.put(c.opts, :reasoning, "not-an-effort"))

    assert {:error, %{reason: :missing_revision}} =
             D.subagent(c.child, c.opts ++ [worktree: [:not_keyword]])

    assert {:error, %{reason: :invalid_mcp}} = D.subagent(c.child, c.opts ++ [mcp: :bad_config])
    assert NanoAgent.whereis(c.child) == nil
    assert File.ls!(c.dir) == []
  end
end

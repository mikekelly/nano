defmodule Seedling.DelegationTest do
  use ExUnit.Case, async: false
  alias Seedling.Delegation, as: D
  alias Nano.FakeOpenRouter, as: Fake

  test "bounded hashed prereading and composed common rules" do
    path =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "pre-#{System.unique_integer([:positive])}"
      )

    File.write!(path, "one\ntwo\nthree")
    assert {:ok, [pre]} = D.preread([path], pre_lines: 1)
    assert pre.text == "one"
    assert pre.next_offset == 2
    assert byte_size(pre.hash) == 64

    assert {:ok, prompt} =
             D.compose(
               "child",
               [parent: self(), prompt: "job", facts_file: "priv/system_prompt.txt"],
               nil,
               [pre]
             )

    assert prompt =~ "SHA256="
    assert prompt =~ "MIX_ENV=test"
    assert prompt =~ "Report with Seedling.Delegation.report"
    assert {:error, {:preread, _, _}} = D.preread([path <> "missing"])
  end

  test "real Nano child reports via eval, monitor detects halt and restart" do
    Fake.start()
    model = Fake.model()
    name = "delegation-#{System.unique_integer([:positive])}"
    Fake.listen(model)

    opts =
      Fake.opts(model, max_context: 20000, max_turns: 1) ++
        [parent: self(), prompt: "report", poll_ms: 10]

    assert {:ok, handle} = D.subagent(name, opts)

    on_exit(fn ->
      if pid = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      if Process.alive?(handle.monitor), do: GenServer.stop(handle.monitor)
      Nano.StateStore.delete(name)
    end)

    assert NanoAgent.info(name).status == :idle
    Fake.push(model, text: "done")
    assert :ok = D.tell(name, :run)
    assert_receive {:openrouter_request, ^model, _}, 2000
    assert_receive {:delegation, ^name, :halted, %{reason: :budget}}, 2000
    Process.exit(handle.pid, :kill)
    assert_receive {:delegation, ^name, :down, _}, 2000
    assert_receive {:delegation, ^name, :restarted, _}, 2000

    assert {:error, :result_too_large_keep_under_16000_bytes} =
             D.report(name, String.duplicate("x", 17000))

    assert :ok = D.report(name, %{summary: "done"})

    assert_receive {:delegation, ^name, :result,
                    %{result: %{summary: "done"}, info: %{budget: _}}}
  end

  test "monitor persistence restores a queued result after supervisor restart" do
    D.watch("persist-#{System.unique_integer([:positive])}", "absent-parent", 10)
    name = "persist-report-#{System.unique_integer([:positive])}"
    assert {:ok, monitor} = D.watch(name, "absent-parent", 10)
    assert :ok = D.report(name, %{summary: "persisted"})
    path = Seedling.Delegation.Supervisor.file(name)
    assert File.exists?(path)
    Supervisor.stop(Seedling.Delegation.Supervisor)
    :persistent_term.erase({Seedling.Delegation.Supervisor, :boot_ready})
    {:ok, boot_sup} = Seedling.Delegation.Supervisor.start_link(restore: false)
    Process.unlink(boot_sup)
    Process.sleep(30)
    assert :global.whereis_name({Seedling.Delegation.Monitor, name}) == :undefined
    Seedling.Delegation.Supervisor.restore()
    Process.sleep(30)
    restored = :global.whereis_name({Seedling.Delegation.Monitor, name})
    assert is_pid(restored)
    assert restored != monitor
    state = :sys.get_state(restored)
    assert state.done
    assert [{:delegation, ^name, :result, %{result: %{summary: "persisted"}}}] = state.pending
    # Attach a now-available parent to exercise delivery without starting a model.
    parent = self()
    :sys.replace_state(restored, &%{&1 | parent: parent})
    ref = Process.monitor(restored)
    assert_receive {:delegation, ^name, :result, _}, 1000
    assert_receive {:DOWN, ^ref, :process, ^restored, :normal}, 1000
    refute File.exists?(path)
  end

  test "MCP configured server is initialized and routed before child's first turn" do
    dir =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "mcp-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    fixture = Path.join(dir, "server.py")

    File.write!(fixture, """
    import sys,json
    for line in sys.stdin:
      m=json.loads(line)
      if 'id' not in m: continue
      r={'protocolVersion':'2025-11-25','capabilities':{},'serverInfo':{'name':'test','version':'1'}} if m.get('method')=='initialize' else {}
      print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':r}),flush=True)
    """)

    config = Path.join(dir, "mcp.json")

    File.write!(
      config,
      Jason.encode!(%{
        "mcpServers" => %{"fixture" => %{"command" => "python3", "args" => [fixture]}}
      })
    )

    {:ok, sup} = Seedling.MCP.Supervisor.start_link(config: config, state_dir: dir)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)
    Fake.start()
    model = Fake.model()
    name = "mcp-child-#{System.unique_integer([:positive])}"
    Fake.listen(model)

    opts =
      Fake.opts(model, max_context: 20000) ++
        [
          parent: self(),
          prompt: "idle",
          mcp: ["fixture"],
          mcp_supervisor: sup,
          mcp_config: config
        ]

    assert {:ok, handle} = D.subagent(name, opts)

    on_exit(fn ->
      if pid = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      if Process.alive?(handle.monitor), do: GenServer.stop(handle.monitor)
      Nano.StateStore.delete(name)
    end)

    assert handle.mcp == ["fixture"]
    c = Seedling.MCP.Supervisor.connections(sup)["fixture"]
    assert Seedling.MCP.status(c).ready
    assert NanoAgent.info(name).system_prompt =~ "MCP servers: [\"fixture\"]"
    assert NanoAgent.info(name).status == :idle

    assert {:error, {:mcp, "absent", _}} =
             D.setup_mcp(name, mcp: ["absent"], mcp_supervisor: sup, mcp_config: config)

    assert :ok = D.report(name, %{summary: "MCP ready"})
    assert_receive {:delegation, ^name, :result, _}
  end

  test "worktree

 at a specified revision retains isolated files" do
    base =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "git-#{System.unique_integer([:positive])}"
      )

    repo = Path.join(base, "repo")
    File.mkdir_p!(repo)
    System.cmd("git", ["init", repo])

    System.cmd(
      "git",
      [
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@test",
        "commit",
        "--allow-empty",
        "-m",
        "initial"
      ],
      cd: repo
    )

    assert {:ok, tree} =
             D.worktree(repo: repo, worktree: Path.join(base, "child"), revision: "HEAD")

    File.write!(Path.join(tree, "owned"), "child")
    refute File.exists?(Path.join(repo, "owned"))
    assert {:error, {:worktree, _, _}} = D.worktree(repo: repo, worktree: tree)
  end
end

defmodule Seedling.DelegationTest do
  use ExUnit.Case, async: false
  alias Seedling.Delegation, as: D
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()
    name = "delegate-#{System.unique_integer([:positive])}"
    model = Fake.model()
    Fake.listen(model)

    on_exit(fn ->
      if pid = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(name)
    end)

    %{name: name, model: model}
  end

  test "idle composed prompt and child result are compact", c do
    {:ok, h} = D.subagent(c.name, model: c.model, prompt: "tiny job", notify: self())
    refute_receive {:openrouter_request, _, _}, 100
    assert NanoAgent.info(c.name).system_prompt =~ "tiny job"
    assert NanoAgent.info(c.name).system_prompt =~ "You are process"

    Fake.push(c.model,
      calls: [
        eval:
          "Seedling.Delegation.report_job(#{inspect(to_string(:erlang.pid_to_list(h.reply_to)))}, :done)"
      ]
    )

    Fake.push(c.model, text: "done")
    send(h.pid, :begin)
    assert {:ok, :done} = D.await(h, 2000)
  end

  test "first message and exhausted budget report failure", c do
    Fake.push(c.model, text: "done")
    {:ok, h} = D.subagent(c.name, model: c.model, message: "go", max_turns: 1, notify: self())
    assert_receive {:openrouter_request, _, body}, 2000
    assert inspect(body) =~ "go"
    assert {:error, {:halted, :budget}} = D.await(h, 2000)
  end

  test "child death is delivered", c do
    {:ok, h} = D.subagent(c.name, model: c.model, notify: self())
    DynamicSupervisor.terminate_child(Nano.AgentSupervisor, h.pid)
    assert {:error, {:exit, reason}} = D.await(h, 2000)
    assert reason in [:shutdown, :noproc]
  end

  test "pre-reading bounded content but full hash" do
    path = Path.join(System.tmp_dir!(), "pre-#{System.unique_integer([:positive])}")
    data = String.duplicate("α", 10000)
    File.write!(path, data)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, [p]} = D.preread([path], pre_file_bytes: 11)
    assert byte_size(p.text) == 10
    assert p.truncated
    assert p.sha256 == Base.encode16(:crypto.hash(:sha256, data), case: :lower)
    assert {:error, {:preread, _, :enoent}} = D.preread([path <> "missing"])
    assert {:error, :invalid_preread_limits} = D.preread([path], pre_max_bytes: 0)
  end

  test "git worktree at given revision", c do
    root = Path.join(System.tmp_dir!(), "tree-#{System.unique_integer([:positive])}")
    repo = root <> "-repo"
    File.mkdir_p!(repo)
    System.cmd("git", ["init", repo])

    System.cmd("git", [
      "-C",
      repo,
      "-c",
      "user.name=Test",
      "-c",
      "user.email=t@t",
      "commit",
      "--allow-empty",
      "-m",
      "initial"
    ])

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(repo)
    end)

    {:ok, h} = D.subagent(c.name, model: c.model, worktree: [repo: repo, path: root])
    assert h.worktree == root
    assert File.exists?(Path.join(root, ".git"))
  end

  test "started_by follows owning eval agent and model options pass through", c do
    parent_name = "parent-#{System.unique_integer([:positive])}"
    {:ok, pid} = NanoAgent.start(name: parent_name, model: c.model)

    on_exit(fn ->
      if p = NanoAgent.whereis(parent_name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, p)

      Nano.StateStore.delete(parent_name)
    end)

    Process.put(:"$callers", [pid])
    {:ok, h} = D.subagent(c.name, model: c.model, reasoning: "off", max_context: 12000)
    Process.delete(:"$callers")
    info = NanoAgent.info(h.name)
    assert info.started_by == parent_name
    assert info.budget.max_context == 12000
    assert info.model == c.model
  end

  test "invalid startup and nonregular preread fail without child", c do
    assert {:error, :invalid_name} = D.subagent("bad name", model: c.model)
    assert {:error, {:preread, _, :not_regular_file}} = D.preread([System.tmp_dir!()])
    assert NanoAgent.whereis(c.name) == nil
  end

  test "aggregate preread cap and changed hash" do
    p = Path.join(System.tmp_dir!(), "aggregate-#{System.unique_integer([:positive])}")
    File.write!(p, "1234567890")
    on_exit(fn -> File.rm(p) end)
    {:ok, [a, b]} = D.preread([p, p], pre_max_bytes: 13)
    assert byte_size(a.text) + byte_size(b.text) == 13
    assert b.truncated
    File.write!(p, "changed")
    {:ok, [updated]} = D.preread([p])
    refute updated.sha256 == a.sha256
  end

  test "MCP fake server ready before first turn", c do
    server = "mcp-delegate-#{System.unique_integer([:positive])}"

    code =
      "import sys,json\nfor line in sys.stdin:\n m=json.loads(line)\n if 'id' in m:\n  print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':{'supportedVersions':['2026-07-28'],'capabilities':{}}}),flush=True)"

    config = %{"command" => "python3", "args" => ["-u", "-c", code]}
    on_exit(fn -> Seedling.MCP.disconnect(server) end)
    {:ok, h} = D.subagent(c.name, model: c.model, mcp: [{server, config}])
    assert h.mcp == [server]
    assert NanoAgent.info(c.name).system_prompt =~ server
    assert {:ok, %{"status" => "ready"}} = Seedling.MCP.info(server)
  end

  test "forged reports ignored and duplicate terminal reports suppressed", c do
    {:ok, h} = D.subagent(c.name, model: c.model, notify: self())
    D.report(h.reply_to, h.ref, :forged)
    assert {:error, :timeout} = D.await(h, 50)
    send(h.reply_to, {:delegation_report, h.ref, h.pid, :valid})
    assert {:ok, :valid} = D.await(h, 1000)
    send(h.reply_to, {:delegation_report, h.ref, h.pid, :duplicate})
    assert {:error, :timeout} = D.await(h, 50)
  end
end

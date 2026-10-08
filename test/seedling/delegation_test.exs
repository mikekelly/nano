defmodule Seedling.DelegationTest do
  use ExUnit.Case, async: false
  alias Seedling.Delegation, as: D
  alias Nano.FakeOpenRouter, as: Fake
  @root Path.expand("../..", __DIR__)

  setup do
    Fake.start()
    model = Fake.model()
    name = "delegation-#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), name)
    File.mkdir_p!(dir)

    on_exit(fn ->
      if pid = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(name)
      File.rm_rf!(dir)
    end)

    %{name: name, model: model, dir: dir, opts: Fake.opts(model) ++ [root: @root, parent: self()]}
  end

  test "partials and hashed bounded pre-reading with change detection", c do
    path = Path.join(c.dir, "pre.txt")
    File.write!(path, "one\ntwo\nthree")

    assert {:ok, prompt, [mark]} =
             D.compose(c.name,
               root: @root,
               parent: "planner",
               flavour: :reviewer,
               prompt: "Find defects",
               pre: [{path, offset: 2, limit: 1}]
             )

    assert prompt =~ "two"
    assert prompt =~ "Land shared foundations"
    assert prompt =~ "You are a reviewer"
    assert prompt =~ ~s(Seedling.Delegation.report("#{c.name}")
    assert mark.offset == 2
    assert {:ok, false} = D.changed?(mark)
    File.write!(path, "changed")
    assert {:ok, true} = D.changed?(mark)
    assert {:error, {:pre_read_too_large, ^path, 10, _}} = D.preread([path], 10)
    assert {:error, :invalid_flavour} = D.compose(c.name, root: @root, flavour: "../secret")
  end

  test "required model and budgets have no silent defaults", c do
    assert {:error, {:missing, keys}} = D.subagent(c.name, root: @root)
    assert :model in keys
    assert :max_context in keys
    assert {:error, _} = D.subagent(c.name, Keyword.put(c.opts, :max_context, 100))
  end

  test "child starts idle, receives initial message, reports once and restores result", c do
    Fake.push(c.model, text: "idle")
    assert {:ok, child} = D.subagent(c.name, c.opts ++ [prompt: "job", message: "begin"])
    assert child.parent == self()
    assert_receive {:openrouter_request, _, body}, 2000
    assert inspect(body) =~ "begin"
    assert :ok = D.report(c.name, "tested; commit abc")
    assert_receive %{type: :delegation, child: name, status: :ok, summary: "tested; commit abc"}
    assert name == c.name
    assert {:error, :already_reported} = D.report(c.name, "duplicate")
    assert D.result(c.name).summary == "tested; commit abc"
    pid = Process.whereis(D.Manager)
    Process.exit(pid, :kill)
    wait(fn -> Process.whereis(D.Manager) not in [nil, pid] end)
    assert D.result(c.name).summary == "tested; commit abc"
  end

  test "budget halt and process death reach parent without polling turns", c do
    Fake.push(c.model, text: "done")
    opts = Keyword.merge(c.opts, max_turns: 1, message: "start")
    assert {:ok, child} = D.subagent(c.name, opts)
    assert_receive %{type: :delegation, status: :halted, summary: summary}, 3000
    assert summary =~ "budget"
    Process.exit(child.pid, :kill)
    assert_receive %{type: :delegation, status: :exited}, 3000
    assert_receive %{type: :delegation, status: :restarted}, 3000
  end

  test "worktree names an explicit revision and isolated build path", c do
    repo = Path.join(c.dir, "repo")
    File.mkdir_p!(repo)
    System.cmd("git", ["init", "-q"], cd: repo)
    System.cmd("git", ["config", "user.email", "test@example.invalid"], cd: repo)
    System.cmd("git", ["config", "user.name", "test"], cd: repo)
    File.write!(Path.join(repo, "file"), "original")
    System.cmd("git", ["add", "."], cd: repo)
    System.cmd("git", ["commit", "-qm", "initial"], cd: repo)
    assert {:error, _} = D.worktree([path: Path.join(c.dir, "bad")], repo)
    path = Path.join(c.dir, "copy")
    assert {:ok, w} = D.worktree([path: path, revision: "HEAD", branch: "child"], repo)
    assert w.mix_env == "test"
    assert w.mix_build_root =~ path
    File.write!(Path.join(path, "file"), "child")
    assert File.read!(Path.join(repo, "file")) == "original"

    assert {:error, {:worktree_exists, ^path}} =
             D.worktree([path: path, revision: "HEAD", branch: "another"], repo)
  end

  test "reserved harness placeholders cannot invalidate preread hashes", c do
    path = Path.join(c.dir, "template.txt")
    File.write!(path, "safe\n{{pid}}")
    assert {:error, {:harness_template_marker_in_pre, ^path, _}} = D.preread([path])
    assert {:ok, _, [_]} = D.preread([{path, limit: 1}])
    assert {:ok, prompt, []} = D.compose(c.name, root: @root, flavours: [:builder, :reviewer])
    assert prompt =~ "You are a builder"
    assert prompt =~ "You are a reviewer"
  end

  test "parent absent at reporting time receives durable queued result by name", c do
    parent = c.name <> "-parent"
    parent_opts = Fake.opts(Fake.model())
    opts = Keyword.put(c.opts, :parent, parent)
    assert {:ok, _} = D.subagent(c.name, opts)
    assert :ok = D.report(c.name, "parent can return later")
    expected = D.result(c.name).report_id
    pid = Process.whereis(D.Manager)
    Process.exit(pid, :kill)
    wait(fn -> Process.whereis(D.Manager) not in [nil, pid] end)
    assert {:ok, parent_pid} = NanoAgent.start([name: parent] ++ parent_opts)

    on_exit(fn ->
      if pid = NanoAgent.whereis(parent) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(parent)
    end)

    send(Process.whereis(D.Manager), :check)

    wait(fn ->
      Enum.any?(Nano.Log.read(NanoAgent.info(parent).id), fn e ->
        e["type"] == "event_received" and String.contains?(e["message"], expected)
      end)
    end)

    assert Process.alive?(parent_pid)
  end

  test "actual agent eval preserves starter and inferred stable parent", c do
    parent = c.name <> "-parent"
    model = Fake.model()
    opts = Keyword.delete(c.opts, :parent)
    script = "Seedling.Delegation.subagent(#{inspect(c.name)}, #{inspect(opts)})"
    Fake.push(model, calls: [eval: script, idle: nil])
    assert {:ok, _} = NanoAgent.start([name: parent] ++ Fake.opts(model))

    on_exit(fn ->
      if pid = NanoAgent.whereis(parent) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(parent)
    end)

    NanoAgent.notify(parent, :begin)
    wait(fn -> NanoAgent.info(c.name) != nil end)
    assert NanoAgent.info(c.name).started_by == parent
    assert NanoAgent.info(c.name).system_prompt =~ ~s(Your parent is "#{parent}")
    assert NanoAgent.info(c.name).status == :idle
    assert NanoAgent.info(c.name).budget.turns_used == 0
  end

  test "a stopped child is reported even when its DOWN was lost on watcher restart", c do
    assert {:ok, child} = D.subagent(c.name, c.opts)
    watcher = Process.whereis(D.Manager)
    :sys.suspend(watcher)
    DynamicSupervisor.terminate_child(Nano.AgentSupervisor, child.pid)
    Process.exit(watcher, :kill)
    assert_receive %{type: :delegation, status: :exited, summary: summary}, 3000
    assert summary =~ "no live process"
  end

  test "constructor death terminates half-setup child and reports a durable error", c do
    assert {:ok, child} = D.subagent(c.name, c.opts)

    constructor =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    D.SetupGuard.start(constructor, c.name, child.id)
    Process.exit(constructor, :kill)
    assert_receive %{type: :delegation, status: :error, summary: summary}, 2000
    assert summary =~ "constructor exited during setup"
    wait(fn -> NanoAgent.whereis(c.name) == nil end)
    assert D.result(c.name).status == :error
  end

  test "setup guard releases on success and does not kill a replacement job", c do
    assert {:ok, child} = D.subagent(c.name, c.opts)
    assert :ok = D.SetupGuard.run(c.name, child.id, [], [], fn -> :ok end)
    assert Process.alive?(child.pid)
    DynamicSupervisor.terminate_child(Nano.AgentSupervisor, child.pid)
    assert {:ok, replacement} = D.subagent(c.name, c.opts)
    assert NanoAgent.info(c.name).id != child.id
    D.SetupGuard.fail(c.name, child.id, [], [], "old setup failed")
    assert Process.alive?(replacement.pid)
    assert D.result(c.name) == nil
  end

  defp wait(fun, attempts \\ 100)

  defp wait(fun, n) when n > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          wait(fun, n - 1)
        )
  end

  defp wait(_, 0), do: flunk("condition did not arrive")
end

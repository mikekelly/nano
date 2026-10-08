defmodule DelegationTest.MCPAdapter do
  def attach(name, servers) do
    %{owner: owner, attach: reply} = Agent.get(__MODULE__, & &1)
    send(owner, {:mcp_attach, name, servers, NanoAgent.info(name).suspended})
    NanoAgent.notify(name, {:mcp, :early_push})
    Agent.update(__MODULE__, &Map.put(&1, :name, name))
    reply
  end

  def await(server) do
    %{owner: owner, await: reply, name: name} = Agent.get(__MODULE__, & &1)
    send(owner, {:mcp_await, server, NanoAgent.info(name).budget.turns_used})
    reply
  end

  def detach(server, opts) do
    owner = Agent.get(__MODULE__, & &1.owner)
    send(owner, {:mcp_detach, server, opts[:agent]})
    :ok
  end
end

defmodule DelegationTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    base =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "delegation-#{System.unique_integer([:positive])}"
      )

    repo = Path.join(base, "repo")
    File.mkdir_p!(repo)
    File.cp_r!(Path.expand("../prompts", __DIR__), Path.join(repo, "prompts"))
    git!(repo, ["init", "-q"])
    git!(repo, ["add", "."])

    git!(repo, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.test",
      "commit",
      "-qm",
      "fixture"
    ])

    revision = git!(repo, ["rev-parse", "HEAD"])

    for {key, value} <- [
          delegation_repo: repo,
          delegation_worktree_root: Path.join(base, "worktrees")
        ] do
      old = Application.fetch_env(:nano, key)
      Application.put_env(:nano, key, value)

      on_exit(fn ->
        case old do
          {:ok, previous} -> Application.put_env(:nano, key, previous)
          :error -> Application.delete_env(:nano, key)
        end
      end)
    end

    if Process.whereis(Delegation.Watcher) == nil, do: start_supervised!(Delegation.Watcher)
    Fake.start()
    model = Fake.model()
    parent = "delegation-parent-#{System.unique_integer([:positive])}"
    child = "delegation-child-#{System.unique_integer([:positive])}"
    {:ok, parent_pid} = NanoAgent.start([name: parent] ++ Fake.opts(model))
    Process.put(:"$callers", [parent_pid])

    on_exit(fn ->
      for name <- [parent, child] do
        if pid = NanoAgent.whereis(name) do
          DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
          NanoAgent.kill_tasks(pid)
        end

        Nano.StateStore.delete(name)
        if Process.whereis(Delegation.Watcher), do: Delegation.Watcher.untrack(name)
      end

      File.rm_rf!(base)
    end)

    %{
      base: base,
      repo: repo,
      parent: parent,
      parent_pid: parent_pid,
      child: child,
      model: model,
      opts: Fake.opts(model) ++ [revision: revision, task: "Implement the owned task"],
      revision: revision
    }
  end

  defp git!(repo, args) do
    {text, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(text)
  end

  test "rejects invalid names, options, duplicates and partial traversal without effects", ctx do
    for name <- [
          nil,
          12,
          "",
          ".",
          "..",
          "../oops",
          "-option",
          "a..b",
          "a.lock",
          "a.",
          String.duplicate("a", 129)
        ] do
      assert {:error, :invalid_name} = Delegation.subagent(name, ctx.opts)
    end

    for opts <- [nil, %{}, [:bad], [{1, 2}]] do
      assert {:error, :expected_keyword_options} = Delegation.subagent(ctx.child, opts)
    end

    assert {:error, :duplicate_options} =
             Delegation.validate(ctx.child, ctx.opts ++ [task: "again"])

    assert {:error, {:unknown_option, :typo}} =
             Delegation.validate(ctx.child, ctx.opts ++ [typo: true])

    assert {:error, {:missing_option, :revision}} =
             Delegation.validate(ctx.child, Keyword.delete(ctx.opts, :revision))

    for {key, invalid} <- [
          revision: 1,
          task: " ",
          model: false,
          reasoning: [],
          max_turns: -1,
          max_tokens: 1.5,
          max_context: 0,
          worktree: nil,
          pre: [1],
          parts: ["../escape"],
          mcp: %{}
        ] do
      assert {:error, {:invalid_option, ^key}} =
               Delegation.subagent(ctx.child, Keyword.put(ctx.opts, key, invalid))
    end

    refute File.exists?(Path.join(ctx.base, "worktrees"))
    assert {:error, :invalid_parts} = Delegation.compose(["../escape"], "task")
  end

  test "composition strips template comments but preserves job text and fits parts", ctx do
    job = "Preserve {{! job literal }}"
    assert {:ok, prompt} = Delegation.compose(["principles", "orientation", "builder"], job)
    assert prompt =~ "You are process {{pid}}"
    assert prompt =~ "protect context"
    assert prompt =~ job
    refute prompt =~ "{{! Builder"
    assert {:ok, narrow} = Delegation.compose([], "Classify this")
    refute narrow =~ "Run tests"
    assert {:error, :enoent} = Delegation.compose(["absent"], "task")
    refute File.exists?(Path.join(ctx.base, "worktrees"))
  end

  test "starts idle with hash-marked pre-reading, explicit revision, retained worktree and attribution",
       ctx do
    path = Path.join(ctx.base, "reading.txt")
    text = "read this {{! literally }}"
    File.write!(path, text)
    assert {:ok, result} = Delegation.subagent(ctx.child, ctx.opts ++ [message: nil, pre: [path]])
    assert result.revision == ctx.revision
    assert File.dir?(result.directory)
    assert git!(result.directory, ["rev-parse", "HEAD"]) == ctx.revision
    assert git!(result.directory, ["branch", "--show-current"]) == "seedling/deneb-#{ctx.child}"
    info = NanoAgent.info(ctx.child)
    assert info.started_by == ctx.parent
    assert info.budget.turns_used == 0
    assert info.status == :idle
    assert info.system_prompt =~ ctx.parent
    assert info.system_prompt =~ Base.encode16(:crypto.hash(:sha256, text), case: :lower)
    assert info.system_prompt =~ text
    assert {:error, :name_in_use} = Delegation.subagent(ctx.child, ctx.opts)
  end

  test "default first message is task, while false is a real custom message", ctx do
    Fake.listen(ctx.model)
    assert {:ok, _} = Delegation.subagent(ctx.child, ctx.opts ++ [worktree: false])
    assert_receive {:openrouter_request, _, body}, 2_000
    assert inspect(body["messages"]) =~ "Implement the owned task"
    assert inspect(body["messages"]) =~ "sender_name"
  end

  test "explicit false message is not replaced by task", ctx do
    Fake.listen(ctx.model)

    assert {:ok, _} =
             Delegation.subagent(ctx.child, ctx.opts ++ [worktree: false, message: false])

    assert_receive {:openrouter_request, _, body}, 2_000
    assert inspect(List.last(body["messages"])) =~ "message: false"
  end

  test "failed provider validation rolls back newly created branch and worktree", ctx do
    opts = Keyword.put(ctx.opts, :reasoning, "not-an-effort")
    assert {:error, _} = Delegation.subagent(ctx.child, opts)
    refute File.exists?(Path.join([ctx.base, "worktrees", ctx.child]))
    assert git!(ctx.repo, ["branch", "--list", "seedling/deneb-#{ctx.child}"]) == ""
    assert NanoAgent.whereis(ctx.child) == nil
  end

  test "failed git checkout removes its newly created branch", ctx do
    File.write!(Path.join(ctx.base, "worktrees"), "not a directory")
    assert {:error, _} = Delegation.subagent(ctx.child, ctx.opts)
    assert git!(ctx.repo, ["branch", "--list", "seedling/deneb-#{ctx.child}"]) == ""
    assert File.read!(Path.join(ctx.base, "worktrees")) == "not a directory"
  end

  test "a failing post-checkout hook rolls back its registered worktree and branch", ctx do
    hook = Path.join(ctx.repo, ".git/hooks/post-checkout")
    File.write!(hook, "#!/bin/sh\nexit 1\n")
    File.chmod!(hook, 0o755)
    assert {:error, _} = Delegation.subagent(ctx.child, ctx.opts)
    refute File.exists?(Path.join([ctx.base, "worktrees", ctx.child]))
    assert git!(ctx.repo, ["branch", "--list", "seedling/deneb-#{ctx.child}"]) == ""
  end

  test "watch persistence failure cleans the already-started idle child and all resources", ctx do
    watch_root = :sys.get_state(Delegation.Watcher).root
    block = Path.join(watch_root, ctx.child <> ".json")
    File.mkdir_p!(block)
    on_exit(fn -> File.rm_rf!(block) end)
    assert {:error, _} = Delegation.subagent(ctx.child, ctx.opts ++ [message: nil])
    assert NanoAgent.whereis(ctx.child) == nil
    assert NanoAgent.info(ctx.child) == nil
    refute File.exists?(Path.join([ctx.base, "worktrees", ctx.child]))
    assert git!(ctx.repo, ["branch", "--list", "seedling/deneb-#{ctx.child}"]) == ""
  end

  test "pre-existing paths and branches are never removed", ctx do
    directory = Path.join([ctx.base, "worktrees", ctx.child])
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "keep"), "owned elsewhere")
    assert {:error, :worktree_path_exists} = Delegation.subagent(ctx.child, ctx.opts)
    assert File.read!(Path.join(directory, "keep")) == "owned elsewhere"
    File.rm_rf!(directory)
    git!(ctx.repo, ["branch", "seedling/deneb-#{ctx.child}"])
    assert {:error, {:git, _, _}} = Delegation.subagent(ctx.child, ctx.opts)
    assert git!(ctx.repo, ["branch", "--list", "seedling/deneb-#{ctx.child}"]) != ""
  end

  test "missing partials, invalid revision, oversized and invalid pre-reading fail before worktree creation",
       ctx do
    assert {:error, :enoent} = Delegation.subagent(ctx.child, ctx.opts ++ [parts: ["absent"]])

    assert {:error, {:git, _, _}} =
             Delegation.subagent(ctx.child, Keyword.put(ctx.opts, :revision, "--help"))

    path = Path.join(ctx.base, "large")
    File.write!(path, String.duplicate("x", 80_000))

    assert {:error, :prereading_over_80000_bytes} =
             Delegation.subagent(ctx.child, ctx.opts ++ [pre: [path]])

    File.write!(path, <<255>>)

    assert {:error, {:invalid_prereading_encoding, ^path}} =
             Delegation.subagent(ctx.child, ctx.opts ++ [pre: [path]])

    assert {:error, {:invalid_prereading_file, _}} =
             Delegation.subagent(ctx.child, ctx.opts ++ [pre: [ctx.base]])

    refute File.exists?(Path.join(ctx.base, "worktrees"))
  end

  defp mcp_adapter(overrides \\ %{}) do
    owner = self()
    state = Map.merge(%{owner: owner, attach: :ok, await: {:ok, %{ready: true}}}, overrides)
    pid = start_supervised!({Agent, fn -> state end}, id: :mcp_adapter)
    Process.register(pid, DelegationTest.MCPAdapter)
    old = Application.fetch_env(:nano, :delegation_mcp_module)
    Application.put_env(:nano, :delegation_mcp_module, DelegationTest.MCPAdapter)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:nano, :delegation_mcp_module, value)
        :error -> Application.delete_env(:nano, :delegation_mcp_module)
      end
    end)
  end

  test "MCP attach and readiness precede the first turn even with early push events", ctx do
    mcp_adapter()
    Fake.listen(ctx.model)
    child = ctx.child

    assert {:ok, _} =
             Delegation.subagent(child, ctx.opts ++ [mcp: ["one", "two"], worktree: false])

    assert_receive {:mcp_attach, ^child, ["one", "two"], true}
    assert_receive {:mcp_await, "one", 0}
    assert_receive {:mcp_await, "two", 0}
    assert_receive {:openrouter_request, _, body}, 2_000
    assert inspect(body["messages"]) =~ "early_push"
    refute NanoAgent.info(child).suspended
  end

  test "MCP readiness failure detaches all servers and removes child, worktree and branch", ctx do
    mcp_adapter(%{await: {:error, :connect_timeout}})
    child = ctx.child

    assert {:error, :connect_timeout} =
             Delegation.subagent(child, ctx.opts ++ [mcp: ["one", "two"]])

    assert_receive {:mcp_attach, ^child, _, true}
    assert_receive {:mcp_await, "one", 0}
    assert_receive {:mcp_detach, "one", ^child}
    assert_receive {:mcp_detach, "two", ^child}
    assert NanoAgent.info(child) == nil
    refute File.exists?(Path.join([ctx.base, "worktrees", child]))
    assert git!(ctx.repo, ["branch", "--list", "seedling/deneb-#{child}"]) == ""
  end

  test "MCP attach errors also clean partially attached servers", ctx do
    mcp_adapter(%{attach: {:error, :unknown_server}})
    child = ctx.child

    assert {:error, :unknown_server} =
             Delegation.subagent(child, ctx.opts ++ [mcp: ["one", "missing"], worktree: false])

    assert_receive {:mcp_detach, "one", ^child}
    assert_receive {:mcp_detach, "missing", ^child}
    assert NanoAgent.info(child) == nil
    refute_receive {:mcp_await, _, _}
  end

  test "reports carry named reply identity and require a live parent", ctx do
    assert {:ok, result} =
             Delegation.subagent(ctx.child, ctx.opts ++ [message: nil, worktree: false])

    Process.put(:"$callers", [result.pid])
    Fake.listen(ctx.model)
    assert :ok = Delegation.report(ctx.parent, %{commit: "abc"})
    assert_receive {:openrouter_request, _, body}, 2_000
    assert inspect(List.last(body["messages"])) =~ ":delegation"
    assert inspect(List.last(body["messages"])) =~ ctx.child
    assert {:error, :parent_unavailable} = Delegation.report("missing-parent", :result)
    Process.delete(:"$callers")
    assert {:error, :not_in_agent_eval} = Delegation.subagent("another", ctx.opts)
  end
end

defmodule DelegationWatcherTest.Agent do
  def info(name), do: Agent.get(__MODULE__, &Map.get(&1.info, name))
  def whereis(name), do: Agent.get(__MODULE__, &Map.get(&1.parents, name))
  def notify(name, message), do: send(whereis(name), message)
end

defmodule DelegationWatcherTest do
  use ExUnit.Case, async: false
  alias Delegation.Watcher
  alias DelegationWatcherTest.Agent, as: FakeAgent

  setup do
    root =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "watches-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    # The fake is local to this test VM, never the running node.
    pid = start_supervised!({Agent, fn -> %{info: %{}, parents: %{}} end}, id: :fake_data)
    Process.register(pid, FakeAgent)

    record = %{
      name: "child",
      parent: "parent",
      directory: "/retained",
      revision: "abc",
      pid: inspect(self())
    }

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, record: record}
  end

  defp watcher(root) do
    start_supervised!(
      {Watcher, name: nil, root: root, agent_module: FakeAgent, poll_ms: 60_000, boot_grace_ms: 0}
    )
  end

  defp info(value), do: Agent.update(FakeAgent, &put_in(&1.info["child"], value))
  defp parent(pid), do: Agent.update(FakeAgent, &put_in(&1.parents["parent"], pid))
  defp alive(pid, count \\ 0), do: %{pid: pid, halted: nil, restart_count: count}

  test "halt, down and restart transitions are persisted, delivered once and reload cleanly",
       ctx do
    parent(self())
    info(alive(self()))
    watcher = watcher(ctx.root)
    assert :ok = Watcher.track(ctx.record, watcher)
    assert :ok = Watcher.poll(watcher)
    refute_receive {:delegation, _, _, _}
    info(%{pid: self(), halted: :budget})
    Watcher.poll(watcher)

    assert_receive {:delegation, "child", :halted,
                    %{status: "halted:budget", directory: "/retained"}}

    Watcher.poll(watcher)
    refute_receive {:delegation, _, _, _}
    info(nil)
    Watcher.poll(watcher)
    assert_receive {:delegation, "child", :down, %{status: "down"}}
    info(alive(self(), 1))
    Watcher.poll(watcher)
    assert_receive {:delegation, "child", :restarted, _}
    stop_supervised!(Watcher)
    watcher = watcher(ctx.root)
    Watcher.poll(watcher)
    refute_receive {:delegation, _, _, _}
    assert :ok = Watcher.untrack("child", watcher)
    refute File.exists?(Path.join(ctx.root, "child.json"))
  end

  test "pending notifications survive restart while parent is absent", ctx do
    info(alive(self()))
    watcher = watcher(ctx.root)
    Watcher.track(ctx.record, watcher)
    info(nil)
    Watcher.poll(watcher)
    stored = ctx.root |> Path.join("child.json") |> File.read!() |> Jason.decode!()
    assert [%{"type" => "down"}] = stored["pending"]
    stop_supervised!(Watcher)
    watcher = watcher(ctx.root)
    parent(self())
    Watcher.poll(watcher)
    assert_receive {:delegation, "child", :down, _}
    Watcher.poll(watcher)
    refute_receive {:delegation, _, _, _}
  end

  test "initial halt is reported, malformed records skipped and paths validated", ctx do
    File.write!(Path.join(ctx.root, "broken.json"), "{")
    File.write!(Path.join(ctx.root, "wrong.json"), Jason.encode!(ctx.record))
    File.write!(Path.join(ctx.root, "array.json"), "[]")
    parent(self())
    info(%{pid: self(), halted: :context})
    watcher = watcher(ctx.root)

    assert {:error, :invalid_watch_record} =
             Watcher.track(%{ctx.record | name: "../bad"}, watcher)

    assert {:error, :invalid_name} = Watcher.untrack("../bad", watcher)
    assert :ok = Watcher.track(ctx.record, watcher)
    Watcher.poll(watcher)
    assert_receive {:delegation, "child", :halted, %{status: "halted:context"}}
  end

  test "boot grace defers absent-child notifications until revival has a chance", ctx do
    parent(self())

    watcher =
      start_supervised!(
        {Watcher,
         name: nil,
         root: ctx.root,
         agent_module: FakeAgent,
         poll_ms: 60_000,
         boot_grace_ms: 60_000}
      )

    Watcher.track(ctx.record, watcher)
    Watcher.poll(watcher)
    refute_receive {:delegation, _, _, _}
    # Monotonic time may be negative; set the deadline explicitly to the past.
    :sys.replace_state(watcher, &%{&1 | down_after: System.monotonic_time(:millisecond) - 1})
    Watcher.poll(watcher)
    assert_receive {:delegation, "child", :down, _}
  end

  test "a supervisor adopts a lazy watcher once and legacy state upgrades", ctx do
    name = {:global, {__MODULE__, make_ref()}}
    {:ok, pid} = GenServer.start(Watcher, [root: ctx.root, lazy: true], name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert {:ok, ^pid} = Watcher.start_link(name: name)
    assert self() in elem(Process.info(pid, :links), 1)
    assert {:error, {:already_started, ^pid}} = Watcher.start_link(name: name)
    Process.unlink(pid)
    # The foundation watcher had just root/records; upgrade preserves its records.
    :sys.replace_state(pid, &Map.take(&1, [:root, :records]))
    assert :ok = Watcher.poll(pid)
    assert :sys.get_state(pid).lazy
    assert {:ok, ^pid} = Watcher.start_link(name: name)
    Process.unlink(pid)
  end

  test "legacy alive statuses migrate silently but changed pid or counter still reports restart",
       ctx do
    parent(self())
    info(alive(self(), 4))
    legacy = Map.put(ctx.record, :status, "alive:#{inspect(self())}")
    File.write!(Path.join(ctx.root, "child.json"), Jason.encode!(legacy))
    watcher = watcher(ctx.root)
    Watcher.poll(watcher)
    refute_receive {:delegation, _, :restarted, _}
    stored = ctx.root |> Path.join("child.json") |> File.read!() |> Jason.decode!()
    assert stored["status"] == "alive:#{inspect(self())}:4"
    info(alive(self(), 5))
    Watcher.poll(watcher)
    assert_receive {:delegation, "child", :restarted, _}
    # Also cover an old in-memory watcher whose pid changed before hot reload.
    :sys.replace_state(watcher, fn s ->
      put_in(s.records["child"]["status"], "alive:#PID<0.999999999.0>")
    end)

    Watcher.poll(watcher)
    assert_receive {:delegation, "child", :restarted, _}
  end

  test "disk errors are returned, not crashes, and failed transitions retry", ctx do
    parent(self())
    info(alive(self()))
    watcher = watcher(ctx.root)
    Watcher.track(ctx.record, watcher)
    File.rm_rf!(ctx.root)
    File.write!(ctx.root, "not a directory")
    assert {:error, _} = Watcher.track(%{ctx.record | name: "other"}, watcher)
    info(nil)
    assert :ok = Watcher.poll(watcher)
    refute_receive {:delegation, _, _, _}
    assert Process.alive?(watcher)
    File.rm!(ctx.root)
    File.mkdir_p!(ctx.root)
    Watcher.poll(watcher)
    assert_receive {:delegation, "child", :down, _}
  end
end

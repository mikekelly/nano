defmodule DelegationTest do
  use ExUnit.Case, async: false

  test "validate before checkout rejects paths and incomplete budgets" do
    opts = [
      revision: "HEAD",
      task: "inspect",
      model: "test",
      reasoning: "low",
      max_turns: 10,
      max_tokens: 0,
      max_context: 100_000
    ]

    assert :ok = Delegation.validate("safe-name", opts, "parent")
    assert {:error, _} = Delegation.validate("../unsafe", opts, "parent")
    assert {:error, _} = Delegation.validate("safe", Keyword.delete(opts, :revision), "parent")

    assert {:error, _} =
             Delegation.validate("safe", Keyword.put(opts, :max_context, 1000), "parent")

    assert {:error, _} = Delegation.validate("safe", opts, nil)
  end

  test "preread has per-file and aggregate bounds without echoing oversized contents" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "delegation-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "file")
    File.write!(path, "hello")
    assert {:ok, text} = Delegation.preread([path])
    assert text =~ "sha256="
    assert text =~ "hello"
    File.write!(path, String.duplicate("a", 24000))
    assert {:error, _} = Delegation.preread(List.duplicate(path, 4))
    File.write!(path, String.duplicate("a", 24001))
    assert {:error, message} = Delegation.preread([path])
    assert byte_size(message) < 1000
    assert {:error, _} = Delegation.preread(List.duplicate(path, 17))
  end

  test "durable monitoring reports deaths and follows a restarted child by name" do
    suffix = System.unique_integer([:positive, :monotonic])
    name = "monitor-child-#{suffix}"
    parent = "monitor-parent-#{suffix}"
    assert :yes = Nano.Names.register_name({:agent, parent}, self())
    child = spawn(fn -> Process.sleep(:infinity) end)
    assert :yes = Nano.Names.register_name({:agent, name}, child)

    on_exit(fn ->
      if pid = :global.whereis_name({Delegation, name}) do
        if is_pid(pid), do: Process.exit(pid, :kill)
      end

      if pid = NanoAgent.whereis(name), do: Process.exit(pid, :kill)
      Nano.Names.unregister_name({:agent, parent})
    end)

    assert :ok = Delegation.monitor(name, parent)
    # Give the watcher time to monitor; restore is idempotent.
    Process.sleep(100)
    assert :ok in Delegation.restore()
    Process.exit(child, :kill)
    assert_receive {:delegation, ^name, :down, :killed}, 2000
    replacement = spawn(fn -> Process.sleep(:infinity) end)
    assert :yes = Nano.Names.register_name({:agent, name}, replacement)
    assert_receive {:delegation, ^name, :restarted, ^replacement}, 2500
    Process.exit(replacement, :kill)
    assert_receive {:delegation, ^name, :down, :killed}, 2000
  end

  test "thin MCP startup gates events/task, returns stable supervised handles, and restores options" do
    {name, parent, opts} = mcp_fixture(100)
    task = %{"message" => "first task", "parent_name" => parent}
    caller = self()
    spawn(fn -> send(caller, {:setup, Delegation.setup_mcp(name, parent, opts, task)}) end)
    refute_receive %{mcp: _}, 50
    refute_receive %{"message" => "first task"}, 0
    assert_receive %{"message" => "first task"}, 2000
    assert_receive {:setup, {:ok, %{"fake" => handle}}}, 2000
    assert SeedMCP.status(handle).phase == :ready
    assert Delegation.mcp_clients(name) == %{"fake" => handle}
    old = GenServer.whereis(handle)
    Process.exit(old, :kill)
    assert_receive %{mcp: "fake", event: :connected}, 2000
    assert GenServer.whereis(handle) != old
    assert {:ok, _} = SeedMCP.tools(handle)
    refute_receive %{"message" => "first task"}, 50
    SeedMCP.Runtime.stop_for(name)
    Nano.Names.unregister_name({:agent, name})
    assert {name, {:ok, %{"fake" => handle}}} in Delegation.restore_mcp()
    :yes = Nano.Names.register_name({:agent, name}, self())
    assert Enum.any?(Delegation.restore(), &match?({:ok, _}, &1))
    refute_receive %{"message" => "first task"}, 50
  end

  test "whole MCP bootstrap has a timeout and does not deliver the original task on failure" do
    {name, parent, opts} = mcp_fixture(1000)
    caller = self()

    spawn(fn ->
      send(
        caller,
        {:setup,
         Delegation.setup_mcp(name, parent, Keyword.put(opts, :mcp_timeout, 30), %{
           "message" => "must wait"
         })}
      )
    end)

    assert_receive {:setup, {:error, :mcp_ready_timeout}}, 1000
    assert_receive {:delegation, ^name, :mcp_failed, {:error, :mcp_ready_timeout}}
    refute_receive %{"message" => "must wait"}, 100
    assert Delegation.mcp_clients(name) == %{}
  end

  test "a delegated agent's actual first provider request contains its task, not MCP bootstrap noise" do
    {name, parent, mcp_opts} = mcp_fixture(100)
    Nano.Names.unregister_name({:agent, name})
    Nano.FakeOpenRouter.start()
    model = Nano.FakeOpenRouter.model()
    Nano.FakeOpenRouter.push(model, text: "done")

    opts =
      [
        revision: "HEAD",
        task: "Original delegated task",
        parent: parent,
        model: model,
        reasoning: "off",
        max_context: 100_000,
        max_turns: 10,
        max_tokens: 100_000
      ] ++ mcp_opts

    on_exit(fn ->
      if pid = NanoAgent.whereis(name),
        do: DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)

      Nano.StateStore.delete(name)
    end)

    assert {:ok, %{pid: pid, mcp: %{"fake" => handle}}} = Delegation.subagent(name, opts)
    assert_receive {:openrouter_request, ^model, body}, 2000
    user = List.last(body["messages"])
    [part | _] = user["content"]
    assert part["text"] =~ "Original delegated task"
    refute part["text"] =~ "server/discover"
    assert NanoAgent.whereis(name) == pid
    assert SeedMCP.status(handle).phase == :ready
  end

  defp mcp_fixture(delay) do
    suffix = System.unique_integer([:positive, :monotonic])
    name = "mcp-child-#{suffix}"
    parent = "mcp-parent-#{suffix}"
    dir = Path.join(System.tmp_dir!(), "delegation-mcp-#{suffix}")
    File.mkdir_p!(dir)
    :yes = Nano.Names.register_name({:agent, name}, self())
    :yes = Nano.Names.register_name({:agent, parent}, self())
    script = Path.join(dir, "fake.py")

    File.write!(script, """
    import sys,json,time
    for line in sys.stdin:
      m=json.loads(line)
      if 'id' not in m: continue
      if m['method']=='server/discover':
        time.sleep(#{delay / 1000})
        r={'supportedVersions':['2026-07-28'],'capabilities':{}}
      else: r={'tools':[]}
      try: print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':r}),flush=True)
      except BrokenPipeError: sys.exit(0)
    """)

    config = Path.join(dir, "config.json")

    File.write!(
      config,
      Jason.encode!(%{
        mcpServers: %{fake: %{command: System.find_executable("python3"), args: [script]}}
      })
    )

    opts = [mcp: ["fake"], mcp_config: config, mcp_state_dir: dir, mcp_timeout: 2000]

    on_exit(fn ->
      SeedMCP.Runtime.stop_for(name)

      case :global.whereis_name({Delegation, name}) do
        pid when is_pid(pid) -> Process.exit(pid, :kill)
        _ -> :ok
      end

      Nano.Names.unregister_name({:agent, name})
      Nano.Names.unregister_name({:agent, parent})
      key = Base.encode16(:crypto.hash(:sha256, name), case: :lower)
      intent_dir = Path.join(Application.fetch_env!(:nano, :test_dir), "delegation")
      for ext <- [".json", ".queue", ".queue.tmp"], do: File.rm(Path.join(intent_dir, key <> ext))
      File.rm_rf!(dir)
    end)

    {name, parent, opts}
  end
end

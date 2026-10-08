defmodule Seedling.DelegationMCPTest do
  use ExUnit.Case, async: false
  alias Seedling.Delegation, as: D
  alias Seedling.MCP
  alias Nano.FakeOpenRouter, as: Fake
  @root Path.expand("../..", __DIR__)

  setup do
    Fake.start()
    model = Fake.model()
    Fake.push(model, text: "ready")
    name = "delegation-mcp-#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), name)
    File.mkdir_p!(dir)
    # Copy the fixture into this run's private directory; its owner remains unchanged.
    script = File.read!(Path.join(__DIR__, "mcp_fixture.py"))

    script =
      String.replace(
        script,
        "    if method == 'server/discover':\n",
        "    if method == 'server/discover':\n        gate = os.environ.get('DELEGATION_HANDSHAKE_GATE')\n        deadline = time.monotonic() + 10\n        while gate and not os.path.exists(gate):\n            if time.monotonic() > deadline: os._exit(0)\n            time.sleep(0.01)\n"
      )

    fixture = Path.join(dir, "fixture.py")
    File.write!(fixture, script)
    instance = name

    servers =
      Enum.into([{"first", ""}, {"slow", Path.join(dir, "slow.release")}], %{}, fn {server, delay} ->
        wire_dir = Path.join(dir, server)
        File.mkdir_p!(wire_dir)

        {server,
         %{
           "transport" => "stdio",
           "command" => "python3",
           "args" => ["-u", fixture, "stdio", "modern", wire_dir],
           "env" => %{"DELEGATION_HANDSHAKE_GATE" => delay},
           "probe_timeout_ms" => 5000
         }}
      end)

    config = Path.join(dir, "servers.json")
    File.write!(config, Jason.encode!(%{servers: servers}))

    start_supervised!(
      {Seedling.MCP.Supervisor,
       [instance: instance, state_dir: Path.join(dir, "state"), config_path: config]}
    )

    on_exit(fn ->
      if pid = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(name)
      File.write(Path.join(dir, "slow.release"), "release")
      Process.sleep(50)
      File.rm_rf!(dir)
    end)

    opts =
      Fake.opts(model) ++
        [
          root: @root,
          parent: self(),
          mcp: ["first", "slow"],
          mcp_options: [instance: instance],
          message: "All servers available now"
        ]

    %{name: name, dir: dir, instance: instance, model: model, opts: opts}
  end

  test "first model call waits for ALL requested MCP servers, then sees setup events", c do
    parent = self()
    constructor = spawn(fn -> send(parent, {:constructed, D.subagent(c.name, c.opts)}) end)
    on_exit(fn -> if Process.alive?(constructor), do: Process.exit(constructor, :kill) end)
    wait(fn -> match?({:ok, %{status: :ready}}, MCP.status("first", instance: c.instance)) end)
    wait(fn -> File.exists?(Path.join([c.dir, "slow", "wire.jsonl"])) end)
    assert {:ok, %{status: status}} = MCP.status("slow", instance: c.instance)
    assert status != :ready
    refute_receive {:openrouter_request, _, _}, 100
    File.write!(Path.join(c.dir, "slow.release"), "release")
    assert_receive {:constructed, {:ok, child}}, 3000
    assert child.name == c.name
    assert_receive {:openrouter_request, _, _}, 3000
    assert {:ok, %{status: :ready}} = MCP.status("slow", instance: c.instance)
    assert {:ok, %{status: :ready}} = MCP.status("first", instance: c.instance)
  end

  test "constructor death while one server is ready yields error, no partial child turn", c do
    constructor = spawn(fn -> D.subagent(c.name, c.opts) end)
    wait(fn -> File.exists?(Path.join([c.dir, "slow", "wire.jsonl"])) end)
    refute_receive {:openrouter_request, _, _}, 100
    Process.exit(constructor, :kill)
    assert_receive %{type: :delegation, status: :error, summary: summary}, 3000
    assert summary =~ "constructor exited during setup"
    wait(fn -> NanoAgent.whereis(c.name) == nil end)
    wait(fn -> MCP.status("first", instance: c.instance) == {:error, :not_connected} end)
    refute_receive {:openrouter_request, _, _}, 100
  end

  test "failure after first server is ready terminates child without releasing partial events",
       c do
    assert {:error, {:child_setup, {:unknown_server, "missing"}}} =
             D.subagent(c.name, Keyword.put(c.opts, :mcp, ["first", "missing"]))

    assert_receive %{type: :delegation, status: :error}, 2000
    wait(fn -> NanoAgent.whereis(c.name) == nil end)
    assert MCP.status("first", instance: c.instance) == {:error, :not_connected}
    refute_receive {:openrouter_request, _, _}, 100
  end

  defp wait(fun, n \\ 100)

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

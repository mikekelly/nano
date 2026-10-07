defmodule Nano.MCPDelegationTest.Adapter do
  def start(opts) do
    owner = self()
    name = opts[:name]

    pid =
      spawn(fn ->
        Registry.register(Nano.Registry, {:agent, name}, %{halted: nil})
        send(owner, {:child_started, self(), opts})
        loop(owner, name)
      end)

    receive do
      {:child_started, ^pid, _} = message ->
        send(self(), message)
        {:ok, pid}
    after
      1_000 -> {:error, :start_timeout}
    end
  end

  defp loop(owner, name) do
    receive do
      :stop ->
        :ok

      event ->
        send(owner, {:child_event, name, event})
        loop(owner, name)
    end
  end

  def whereis(name), do: NanoAgent.whereis(name)

  def info(name) do
    case Registry.lookup(Nano.Registry, {:agent, name}) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  def notify(name, message), do: send(whereis(name), message)
end

defmodule Nano.MCPDelegationTest do
  use ExUnit.Case, async: false
  @moduletag skip: not Code.ensure_loaded?(Nano.Delegation)

  test "real delegation/MCP prepares child-only schemas, watchers and subscriptions" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "nova-mcp-delegation-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    script = Path.join(dir, "server.py")

    File.write!(script, ~S"""
    import sys,json,signal
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    def out(m): print(json.dumps(m), flush=True)
    for line in sys.stdin:
      m=json.loads(line); id=m.get('id'); method=m.get('method')
      if id is None: continue
      if method=='initialize': result={'protocolVersion':'2025-11-25','capabilities':{'tools':{},'resources':{'subscribe':True}},'serverInfo':{'name':'delegation-fixture','version':'1'}}
      elif method=='tools/list': result={'tools':[{'name':'child_echo','description':'full schema for child context only','inputSchema':{'type':'object','properties':{'text':{'type':'string'}}}}]}
      elif method=='tools/call': result={'content':[{'type':'text','text':'done'}]}
      else: result={}
      out({'jsonrpc':'2.0','id':id,'result':result})
      if method=='tools/call':
        out({'jsonrpc':'2.0','method':'notifications/tools/list_changed'})
        out({'jsonrpc':'2.0','method':'notifications/resources/updated','params':{'uri':'test://child'}})
    """)

    name = "child-" <> Path.basename(dir)
    server = "server-" <> Path.basename(dir)
    parent = "parent-" <> Path.basename(dir)
    Registry.register(Nano.Registry, {:agent, parent}, %{halted: nil})

    opts = [
      parent: parent,
      model: "fixture/model",
      reasoning: "off",
      max_context: 32_000,
      max_tokens: 100_000,
      max_turns: 10,
      storage_dir: Path.join(dir, "delegation"),
      facts: "Fixture harness",
      adapter: Nano.MCPDelegationTest.Adapter,
      poll_ms: 10,
      mcp: [
        {server,
         [
           config: %{"command" => "python3", "args" => [script]},
           state_dir: Path.join(dir, "mcp"),
           subscribe: ["test://child"]
         ]}
      ]
    ]

    assert {:ok, handle} = apply(Nano.Delegation, :subagent, [name, opts])

    on_exit(fn ->
      send(handle.watcher, :complete)
      send(handle.pid, :stop)
      Nano.MCP.disconnect(server)
    end)

    assert_receive {:child_started, _, start_opts}
    assert start_opts[:system_prompt] =~ "child_echo"
    assert start_opts[:system_prompt] =~ "full schema for child context only"
    assert start_opts[:system_prompt] =~ "properties"
    assert [%{name: ^server} = metadata] = handle.mcp
    refute Map.has_key?(metadata, :tools)
    refute inspect(handle) =~ "full schema for child context only"
    refute_received {:mcp, ^server, "client/connected", _}

    assert {:ok, %{"content" => [_]}} =
             Nano.MCP.call_tool(server, "child_echo", %{"text" => "hello"})

    assert_receive {:child_event, ^name, {:mcp, ^server, "notifications/tools/list_changed", _}}

    assert_receive {:child_event, ^name,
                    {:mcp, ^server, "notifications/resources/updated", %{"uri" => "test://child"}}}

    refute_received {:mcp, ^server, "notifications/tools/list_changed", _}
    refute_received {:mcp, ^server, "notifications/resources/updated", _}
    [path] = Path.wildcard(Path.join(dir, "mcp/*.json"))
    assert %{"test://child" => [^name]} = path |> File.read!() |> Jason.decode!()
  end
end
